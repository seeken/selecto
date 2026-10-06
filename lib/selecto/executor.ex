defmodule Selecto.Executor do
  @moduledoc """
  Query execution engine for Selecto.

  Handles execution of generated SQL queries through configured adapter or repo
  contexts, with proper error handling and connection management.
  """

  require Logger

  @query_execution_event [:selecto, :query, :execution]

  @doc """
  Execute a query and return results with standardized error handling.

  ## Parameters

  - `selecto` - The Selecto struct containing connection and query info
  - `opts` - Execution options (currently unused but reserved for future use)

  ## Returns

  - `{:ok, {rows, columns, aliases}}` - Successful execution with results
  - `{:error, %Selecto.Error{}}` - Execution failure with detailed error

  ## Examples

      case Selecto.Executor.execute(selecto) do
        {:ok, {rows, columns, aliases}} ->
          # Process successful results
          handle_results(rows, columns, aliases)
        {:error, error} ->
          # Handle database error
          Logger.error("Query failed: \#{inspect(error)}")
      end
  """
  @spec execute(Selecto.Types.t(), Selecto.Types.execute_options()) ::
          Selecto.Types.safe_execute_result()
  def execute(selecto, opts \\ []) do
    Selecto.Telemetry.operation(:execute, selecto, fn -> do_execute(selecto, opts) end)
  end

  defp do_execute(%Selecto{provider: provider} = selecto, opts) when not is_nil(provider) do
    Selecto.Configuration.Provider.invoke(selecto, :execute, [opts])
  end

  defp do_execute(selecto, opts) do
    start_time = System.monotonic_time(:millisecond)
    query_id = query_id()

    with :ok <- Selecto.Tenant.validate_scope(selecto, opts) do
      execute_safe(selecto, opts, query_id, start_time)
    else
      {:error, %Selecto.Error{} = error} ->
        {:error, error}
    end
  end

  defp query_id do
    case Selecto.Telemetry.Context.current_operation() do
      %{operation_id: operation_id} -> operation_id
      _ -> :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    end
  end

  # The complexity check and task timeout of execute/2, for the other
  # execution entry points (metadata, count and projection sum).
  defp guarded(selecto, opts, work) do
    start_time = System.monotonic_time(:millisecond)
    query_id = query_id()

    with :ok <- check_query_complexity(selecto, opts, query_id) do
      with_timeout_protection(
        opts,
        query_id,
        start_time,
        Selecto.Performance.Hooks.snapshot_hooks(),
        work
      )
    end
  end

  defp execute_safe(selecto, opts, query_id, start_time) do
    hook_options = hook_options(opts)
    hook_snapshot = Selecto.Performance.Hooks.snapshot_hooks()

    with {:ok, compiled} <- compile_and_check(selecto, opts, query_id, hook_options) do
      hook_options =
        if compiled, do: Keyword.put(hook_options, :compiled, compiled), else: hook_options

      work = fn deadline ->
        execute_with_hooks(selecto, hook_options, query_id, start_time, deadline)
      end

      result =
        if run_in_caller?(selecto, opts, hook_snapshot) do
          with_adapter_timeout(opts, query_id, start_time, work)
        else
          with_timeout_protection(opts, query_id, start_time, hook_snapshot, fn ->
            work.(nil)
          end)
        end

      # Apply output format transformation if specified
      case result do
        {:ok, {rows, columns, aliases}} ->
          format = Keyword.get(opts, :format, :raw)
          format_options = Keyword.get(opts, :format_options, [])

          case Selecto.Telemetry.span([:transform], %{}, fn ->
                 Selecto.Output.Formats.transform(
                   {rows, columns, aliases},
                   format,
                   format_options
                 )
               end) do
            {:ok, transformed_result} ->
              {:ok, transformed_result}

            {:error, transform_error} ->
              {:error,
               Selecto.Error.transformation_error("Output format transformation failed", %{
                 format: format,
                 options: format_options,
                 error: transform_error
               })}
          end

        error_result ->
          error_result
      end
    end
  end

  # The complexity check needs the joins the query resolves, which compiling
  # the query resolves anyway. So the query is compiled once, here, and the
  # check reads the compile's joins; execution reuses the compiled SQL rather
  # than compiling again. Without the check (`analyze_complexity: false`)
  # nothing is compiled here and execution compiles as before.
  defp compile_and_check(selecto, opts, query_id, hook_options) do
    if opts[:analyze_complexity] == false do
      {:ok, nil}
    else
      case compile(selecto, Keyword.fetch!(hook_options, :gen_sql_opts)) do
        {:ok, compiled, nil} ->
          # Set operations do not resolve joins while compiling.
          with :ok <- analyze_query_complexity(selecto, opts, query_id, compiled.sql) do
            {:ok, compiled}
          end

        {:ok, compiled, joins_in_order} ->
          analysis =
            Selecto.Performance.ComplexityAnalyzer.analyze_resolved(
              selecto,
              joins_in_order,
              opts
            )

          with :ok <- complexity_outcome(analysis, query_id, compiled.sql) do
            {:ok, compiled}
          end

        {:raised, exception, stacktrace} ->
          # A query the check rejects is rejected even when it cannot compile,
          # as when the check ran before compiling; otherwise the compile
          # error is raised as before.
          with :ok <- analyze_query_complexity(selecto, opts, query_id, nil) do
            reraise exception, stacktrace
          end
      end
    end
  end

  defp compile(selecto, gen_sql_opts) do
    started_at = System.monotonic_time(:millisecond)

    {sql, aliases, params, joins_in_order} =
      Selecto.Telemetry.span([:compile], %{}, fn ->
        Selecto.gen_sql_with_joins(selecto, gen_sql_opts)
      end)

    compiled = %{
      sql: sql,
      aliases: aliases,
      params: params,
      started_at: started_at,
      built_at: System.monotonic_time(:millisecond)
    }

    {:ok, compiled, joins_in_order}
  rescue
    exception -> {:raised, exception, __STACKTRACE__}
  end

  defp check_query_complexity(selecto, opts, query_id) do
    if opts[:analyze_complexity] == false do
      :ok
    else
      analyze_query_complexity(selecto, opts, query_id, nil)
    end
  end

  defp analyze_query_complexity(selecto, opts, query_id, sql) do
    selecto
    |> Selecto.Performance.ComplexityAnalyzer.analyze(opts)
    |> complexity_outcome(query_id, sql)
  end

  # `sql` names the query shape when it is known, so that a warning is
  # logged once per shape (see Selecto.Performance.ComplexityWarnings).
  defp complexity_outcome(analysis_result, query_id, sql) do
    case analysis_result do
      {:ok, analysis} ->
        Enum.each(analysis.warnings, fn warning ->
          if Selecto.Performance.ComplexityWarnings.log?(sql, warning) do
            Logger.warning("[Selecto] Query complexity: #{warning}")
          end
        end)

        :telemetry.execute(
          [:selecto, :query, :complexity_analyzed],
          %{complexity_score: analysis.score},
          %{query_id: query_id, warning_count: length(analysis.warnings)}
        )

        :ok

      {:error, :too_complex, analysis} ->
        Logger.error("[Selecto] Query rejected due to high complexity",
          score: analysis.score,
          issues: analysis.blocking_issues
        )

        :telemetry.execute(
          [:selecto, :query, :complexity_rejected],
          %{complexity_score: analysis.score},
          %{
            query_id: query_id,
            issue_count: length(analysis.blocking_issues)
          }
        )

        {:error,
         Selecto.Error.validation_error("Query too complex to execute safely", %{
           complexity_score: analysis.score,
           max_score: analysis.details.max_score,
           issues: analysis.blocking_issues,
           recommendations: analysis.recommendations,
           details: analysis.details
         })}
    end
  end

  # Default 30 seconds, at most 5 minutes.
  @default_timeout 30_000
  @max_timeout 300_000

  defp effective_timeout(opts), do: min(opts[:timeout] || @default_timeout, @max_timeout)

  # Run the execution work with timeout protection: in a supervised task that
  # is abandoned (shut down) when the timeout elapses.
  defp with_timeout_protection(opts, query_id, start_time, hook_snapshot, work) do
    timeout = effective_timeout(opts)
    restore_hooks? = not Selecto.Performance.Hooks.empty_snapshot?(hook_snapshot)

    # Wrap execution in Task.async for timeout enforcement
    task =
      Selecto.TaskSupervisor.async(fn ->
        if restore_hooks? do
          Selecto.Performance.Hooks.restore_hooks(hook_snapshot)

          try do
            work.()
          after
            Selecto.Performance.Hooks.restore_hooks(%{})
          end
        else
          work.()
        end
      end)

    # Wait for task with timeout
    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        exited_result(reason, query_id, start_time)

      nil ->
        # Task was killed due to timeout
        timeout_result(timeout, query_id, start_time)
    end
  end

  # Run the execution work in the calling process when the adapter enforces
  # the timeout itself (`supports?(:execute_timeout)`), so the result is not
  # copied out of a task. The outcome matches with_timeout_protection/5: work
  # that does not finish within the timeout yields the same timeout error
  # however it ends, an exit or throw the same connection error, and an
  # exception is raised again.
  defp with_adapter_timeout(opts, query_id, start_time, work) do
    timeout = effective_timeout(opts)
    started_at = System.monotonic_time(:millisecond)

    outcome =
      if timeout == 0 do
        :not_started
      else
        try do
          {:done, work.(started_at + timeout)}
        catch
          :exit, reason -> {:exited, reason}
          :throw, value -> {:exited, {{:nocatch, value}, __STACKTRACE__}}
          :error, reason -> {:raised, reason, __STACKTRACE__}
        end
      end

    if outcome == :not_started or System.monotonic_time(:millisecond) - started_at > timeout do
      timeout_result(timeout, query_id, start_time)
    else
      case outcome do
        {:done, result} -> result
        {:exited, reason} -> exited_result(reason, query_id, start_time)
        {:raised, reason, stacktrace} -> :erlang.raise(:error, reason, stacktrace)
      end
    end
  end

  defp run_in_caller?(selecto, opts, hook_snapshot) do
    !opts[:cache] and Selecto.Performance.Hooks.empty_snapshot?(hook_snapshot) and
      adapter_enforces_timeout?(runtime_adapter(selecto))
  end

  defp adapter_enforces_timeout?(adapter) do
    Selecto.AdapterSupport.callback_available?(adapter, :supports?, 1) and
      adapter.supports?(:execute_timeout) == true
  rescue
    _ -> false
  end

  defp exited_result({%_{} = error, stacktrace}, _query_id, _start_time)
       when is_list(stacktrace) do
    reraise error, stacktrace
  end

  defp exited_result(reason, query_id, start_time) do
    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:selecto, :query, :error],
      %{count: 1},
      %{query_id: query_id, error_type: infer_error_type(reason), duration: duration}
    )

    {:error,
     Selecto.Error.connection_error(
       "Database execution process exited",
       Selecto.Error.exit_details(reason)
     )}
  end

  defp timeout_result(timeout, query_id, start_time) do
    duration = System.monotonic_time(:millisecond) - start_time

    Logger.error("[Selecto] Query timeout after #{timeout}ms")

    # Emit timeout telemetry
    :telemetry.execute(
      [:selecto, :query, :timeout],
      %{duration: duration, timeout: timeout},
      %{query_id: query_id}
    )

    {:error,
     Selecto.Error.timeout_error(
       "Query exceeded timeout of #{timeout}ms",
       %{timeout: timeout, duration: duration}
     )}
  end

  @doc """
  Execute a query and return results with metadata including SQL, params, and execution time.

  ## Parameters

  - `selecto` - The Selecto struct containing connection and query info
  - `opts` - Execution options

  ## Returns

  - `{:ok, result, metadata}` - Successful execution with results and metadata
  - `{:error, error}` - Execution failure with detailed error

  The metadata map includes:
  - `:sql` - The generated SQL query string
  - `:params` - The query parameters
  - `:execution_time` - Query execution time in milliseconds

  As in `execute/2`, the query passes the complexity check
  (`analyze_complexity: false` skips it) and runs under the `:timeout`
  option (default 30 seconds, at most 5 minutes). The count and projection
  sum variants apply the same guards.

  ## Examples

      case Selecto.Executor.execute_with_metadata(selecto) do
        {:ok, {rows, columns, aliases}, _meta} ->
          # Process successful results with metadata
          handle_results(rows, columns, aliases)
        {:error, error} ->
          # Handle database error
          Logger.error("Query failed: \#{inspect(error)}")
      end
  """
  @spec execute_with_metadata(Selecto.Types.t(), Selecto.Types.execute_options()) ::
          {:ok, Selecto.Types.execute_result(), map()} | {:error, Selecto.Error.t()}
  def execute_with_metadata(selecto, opts \\ [])

  def execute_with_metadata(%Selecto{provider: provider} = selecto, opts)
      when not is_nil(provider),
      do: Selecto.Configuration.Provider.invoke(selecto, :execute_with_metadata, [opts])

  def execute_with_metadata(selecto, opts) do
    Selecto.Telemetry.operation(:execute_with_metadata, selecto, fn ->
      do_execute_with_metadata(selecto, opts)
    end)
  end

  defp do_execute_with_metadata(selecto, opts) do
    with :ok <- Selecto.Tenant.validate_scope(selecto, opts) do
      guarded(selecto, opts, fn -> execute_with_metadata_work(selecto, opts) end)
    else
      {:error, %Selecto.Error{} = error} ->
        {:error, error}
    end
  end

  defp execute_with_metadata_work(selecto, opts) do
    start_time = System.monotonic_time(:millisecond)

    try do
      {query, aliases, params} = Selecto.gen_sql(selecto, opts)

      # Track the SQL and params for metadata
      sql_metadata = %{
        sql: query,
        params: params
      }

      # Handle different execution contexts: adapters, repos, or direct connections
      result =
        execute_for_context(selecto, query, params, aliases)

      # Calculate execution time
      duration = System.monotonic_time(:millisecond) - start_time

      # Apply output format transformation if specified and add metadata
      case result do
        {:ok, {rows, columns, aliases}} ->
          format = Keyword.get(opts, :format, :raw)
          format_options = Keyword.get(opts, :format_options, [])

          transformed_result =
            case Selecto.Telemetry.span([:transform], %{}, fn ->
                   Selecto.Output.Formats.transform(
                     {rows, columns, aliases},
                     format,
                     format_options
                   )
                 end) do
              {:ok, transformed} -> transformed
              {:error, _transform_error} -> {rows, columns, aliases}
            end

          metadata = Map.put(sql_metadata, :execution_time, duration)
          {:ok, transformed_result, metadata}

        error_result ->
          error_result
      end
    rescue
      error ->
        error_result = {:error, Selecto.Error.from_reason(error)}
        error_result
    catch
      :exit, reason ->
        error_result =
          {:error,
           Selecto.Error.connection_error(
             "Database connection failed",
             Selecto.Error.exit_details(reason)
           )}

        error_result
    end
  end

  @doc """
  Execute an exact count of the rows produced by an unpaginated Selecto query.

  The compiled query is wrapped as a derived table so Detail, Aggregate, and
  grouped queries all share the same count semantics. The returned metadata
  contains the wrapped SQL, bound parameters, and execution time.
  """
  @spec execute_count_with_metadata(Selecto.Types.t(), Selecto.Types.execute_options()) ::
          {:ok, non_neg_integer(), map()} | {:error, Selecto.Error.t()}
  def execute_count_with_metadata(selecto, opts \\ [])

  def execute_count_with_metadata(%Selecto{provider: provider} = selecto, opts)
      when not is_nil(provider),
      do: Selecto.Configuration.Provider.invoke(selecto, :execute_count_with_metadata, [opts])

  def execute_count_with_metadata(selecto, opts) do
    Selecto.Telemetry.operation(:count, selecto, fn ->
      do_execute_count_with_metadata(selecto, opts)
    end)
  end

  @doc """
  Execute one database-side sum over a named numeric projection of a governed
  Selecto query. The input query retains its own filters and pagination. This
  is intended for totals over per-root correlated contributions; no root rows
  are returned to the caller. Adapters must advertise `:projection_sum`.
  """
  @spec execute_projection_sum_with_metadata(
          Selecto.Types.t(),
          binary(),
          Selecto.Types.execute_options()
        ) :: {:ok, term(), map()} | {:error, Selecto.Error.t()}
  def execute_projection_sum_with_metadata(selecto, column, opts \\ [])

  def execute_projection_sum_with_metadata(%Selecto{provider: provider} = selecto, column, opts)
      when not is_nil(provider),
      do:
        Selecto.Configuration.Provider.invoke(selecto, :execute_projection_sum_with_metadata, [
          column,
          opts
        ])

  def execute_projection_sum_with_metadata(selecto, column, opts) do
    Selecto.Telemetry.operation(:projection_sum, selecto, fn ->
      do_execute_projection_sum_with_metadata(selecto, column, opts)
    end)
  end

  defp do_execute_projection_sum_with_metadata(selecto, column, opts) do
    adapter = runtime_adapter(selecto)

    cond do
      not is_binary(column) or not String.match?(column, ~r/\A[A-Za-z][A-Za-z0-9_]*\z/) ->
        {:error, Selecto.Error.query_error("Projection sum column is invalid", "", [], %{})}

      not Selecto.AdapterSupport.callback_available?(adapter, :supports?, 1) or
        not adapter.supports?(:projection_sum) or
          not Selecto.AdapterSupport.callback_available?(adapter, :quote_identifier, 1) ->
        {:error, Selecto.Error.query_error("Projection sum is unavailable", "", [], %{})}

      true ->
        execute_projection_sum_query(selecto, adapter, column, opts)
    end
  end

  defp execute_projection_sum_query(selecto, adapter, column, opts) do
    start_time = System.monotonic_time(:millisecond)

    with :ok <- Selecto.Tenant.validate_scope(selecto, opts) do
      guarded(selecto, opts, fn ->
        try do
          {query, aliases, params} = derived_source_sql(selecto, opts)

          subselect_aliases =
            Enum.map(Map.get(selecto.set, :subselected, []), fn config ->
              Map.get(config, :alias)
            end)

          source_column =
            case Enum.find_index(aliases, &(is_binary(&1) and &1 == column)) do
              nil ->
                if Enum.any?(subselect_aliases, &(is_binary(&1) and &1 == column)),
                  do: column

              index ->
                Selecto.Builder.Sql.projection_alias(index + 1)
            end

          if source_column do
            quoted_column = adapter.quote_identifier(source_column)

            sum_query =
              "SELECT COALESCE(SUM(selecto_projection_source.#{quoted_column}), 0) " <>
                "AS selecto_projection_sum FROM (" <>
                String.trim_trailing(query, ";") <> ") AS selecto_projection_source"

            result = execute_for_context(selecto, sum_query, params, ["selecto_projection_sum"])
            duration = System.monotonic_time(:millisecond) - start_time
            metadata = %{sql: sum_query, params: params, execution_time: duration}

            case result do
              {:ok, {[[value]], _columns, _aliases}} when not is_nil(value) ->
                {:ok, value, metadata}

              {:ok, _other} ->
                {:error, Selecto.Error.query_error("Projection sum returned an invalid result")}

              error ->
                error
            end
          else
            {:error, Selecto.Error.query_error("Projection sum column is not selected")}
          end
        rescue
          error -> {:error, Selecto.Error.from_reason(error)}
        catch
          :exit, reason ->
            {:error,
             Selecto.Error.connection_error(
               "Database projection sum execution failed",
               Selecto.Error.exit_details(reason)
             )}
        end
      end)
    end
  end

  # Compile the governed query for use as a COUNT or SUM derived table. Every
  # selected column gets a unique positional alias because MySQL, MariaDB and
  # SQL Server reject derived tables whose columns share a name (for example
  # `name` and `category.name`) or have no name. Aliases never change rows.
  defp derived_source_sql(selecto, opts) do
    Selecto.gen_sql(
      unordered_source(selecto),
      Keyword.put(opts, :unique_projection_aliases, true)
    )
  end

  # A derived table used only for COUNT or SUM does not need its ORDER BY,
  # and SQL Server rejects ORDER BY in a derived table without TOP/OFFSET.
  # Keep the ordering when LIMIT/OFFSET select which rows are aggregated.
  defp unordered_source(%{set: set} = selecto) when is_map(set) do
    if is_nil(Map.get(set, :limit)) and is_nil(Map.get(set, :offset)) and
         Map.has_key?(set, :order_by) do
      put_in(selecto.set.order_by, [])
    else
      selecto
    end
  end

  defp unordered_source(selecto), do: selecto

  defp do_execute_count_with_metadata(selecto, opts) do
    start_time = System.monotonic_time(:millisecond)

    with :ok <- Selecto.Tenant.validate_scope(selecto, opts) do
      guarded(selecto, opts, fn ->
        try do
          {query, _aliases, params} = derived_source_sql(selecto, opts)

          count_query =
            "SELECT COUNT(*) AS selecto_total_count FROM (" <>
              String.trim_trailing(query, ";") <> ") AS selecto_count_source"

          result = execute_for_context(selecto, count_query, params, ["selecto_total_count"])
          duration = System.monotonic_time(:millisecond) - start_time
          metadata = %{sql: count_query, params: params, execution_time: duration}

          case result do
            {:ok, {[[count]], _columns, _aliases}} when is_integer(count) and count >= 0 ->
              {:ok, count, metadata}

            {:ok, _other} ->
              {:error, Selecto.Error.query_error("Count query returned an invalid result")}

            error ->
              error
          end
        rescue
          error -> {:error, Selecto.Error.from_reason(error)}
        catch
          :exit, reason ->
            {:error,
             Selecto.Error.connection_error(
               "Database count execution failed",
               Selecto.Error.exit_details(reason)
             )}
        end
      end)
    else
      {:error, %Selecto.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  Execute a query as a stream of `{row, columns, aliases}` tuples.

  Streaming is available only when the configured adapter advertises stream
  support and implements `stream/4`. The query passes the complexity check
  before the stream opens; row delivery is bounded by the adapter's stream
  options, not by `:timeout`.
  """
  @spec execute_stream(Selecto.Types.t(), keyword()) :: Selecto.Types.safe_execute_stream_result()
  def execute_stream(selecto, opts \\ [])

  def execute_stream(%Selecto{provider: provider} = selecto, opts) when not is_nil(provider),
    do: Selecto.Configuration.Provider.invoke(selecto, :execute_stream, [opts])

  def execute_stream(selecto, opts) do
    Selecto.Telemetry.operation(:stream_open, selecto, fn -> do_execute_stream(selecto, opts) end)
  end

  # A stream is checked for complexity before it opens. Its rows are read
  # lazily by the caller, so the task timeout of execute/2 cannot bound it;
  # adapters bound row delivery (for example `:receive_timeout`).
  defp do_execute_stream(selecto, opts) do
    with :ok <- Selecto.Tenant.validate_scope(selecto, opts),
         :ok <- check_query_complexity(selecto, opts, query_id()) do
      try do
        stream_sql_opts =
          Keyword.drop(opts, [
            :max_rows,
            :receive_timeout,
            :queue_timeout,
            :stream_timeout,
            :stream_producer
          ])

        {query, aliases, params} = Selecto.gen_sql(selecto, stream_sql_opts)

        case execute_stream_for_context(selecto, query, params, aliases, opts) do
          {:ok, stream} -> {:ok, Selecto.Telemetry.Stream.wrap(stream)}
          {:error, error} -> {:error, error}
        end
      rescue
        error ->
          {:error, Selecto.Error.from_reason(error)}
      catch
        :exit, reason ->
          {:error,
           Selecto.Error.connection_error(
             "Database stream execution failed",
             Selecto.Error.exit_details(reason)
           )}
      end
    else
      {:error, %Selecto.Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Execute a query expecting exactly one row, returning {:ok, row} or {:error, reason}.

  Useful for queries that should return a single record (e.g., with LIMIT 1 or aggregate functions).
  Returns an error if zero rows or multiple rows are returned.

  ## Examples

      case Selecto.Executor.execute_one(selecto) do
        {:ok, row} ->
          # Handle single row result
          process_single_result(row)
        {:error, :no_results} ->
          # Handle case where no rows were found
        {:error, :multiple_results} ->
          # Handle case where multiple rows were found
        {:error, error} ->
          # Handle database or other errors
      end
  """
  @spec execute_one(Selecto.Types.t(), Selecto.Types.execute_options()) ::
          Selecto.Types.safe_execute_one_result()
  def execute_one(selecto, opts \\ []) do
    Selecto.Telemetry.operation(:execute_one, selecto, fn -> do_execute_one(selecto, opts) end)
  end

  defp do_execute_one(selecto, opts) do
    case do_execute(selecto, opts) do
      {:ok, {[], _columns, _aliases}} ->
        {:error, Selecto.Error.no_results_error()}

      {:ok, {[single_row], _columns, aliases}} ->
        {:ok, {single_row, aliases}}

      {:ok, {_multiple_rows, _columns, _aliases}} ->
        {:error, Selecto.Error.multiple_results_error()}

      {:error, %Selecto.Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Execute query using a database adapter.

  This function delegates to the adapter's execute/4 function, allowing
  for different database types like SQLite, MySQL, etc.

  Adapter and driver failures are returned as `Selecto.Error.from_driver/2`
  errors: they never carry the SQL, parameters, connection, or the
  database's own message and detail.
  """
  def execute_with_adapter(adapter, connection, query, params, aliases, opts \\ []) do
    try do
      case adapter.execute(connection, query, params, opts) do
        {:ok, result} ->
          case Selecto.AdapterSupport.normalize_result(adapter, result) do
            {:ok, normalized} ->
              {:ok, {Map.get(normalized, :rows, []), Map.get(normalized, :columns, []), aliases}}

            {:error, reason} ->
              {:error, driver_error(adapter, reason)}
          end

        {:error, reason} ->
          {:error, driver_error(adapter, reason)}
      end
    rescue
      error ->
        {:error,
         Selecto.Error.connection_error("Adapter execution failed", %{
           adapter: adapter,
           reason: Selecto.Error.reason_kind(error)
         })}
    catch
      :exit, reason ->
        {:error,
         Selecto.Error.connection_error(
           "Adapter connection failed",
           Map.put(Selecto.Error.exit_details(reason), :adapter, adapter)
         )}
    end
  end

  defp driver_error(adapter, reason),
    do: Selecto.Error.from_driver(reason, Selecto.AdapterSupport.normalize_error(adapter, reason))

  @doc """
  Execute query using connection pool.
  """
  def execute_with_connection_pool(pool_ref, query, params, aliases) do
    case Selecto.ConnectionPool.execute(pool_ref, query, params, prepared: true) do
      {:ok, result} ->
        rows = Map.get(result, :rows, [])
        columns = Map.get(result, :columns, [])
        {:ok, {rows, columns, aliases}}

      {:error, reason} ->
        {:error, Selecto.Error.from_driver(reason, Selecto.Error.from_reason(reason))}
    end
  end

  @doc """
  Validate connection before executing query.

  Returns `:ok` if connection is valid, `{:error, reason}` otherwise.
  """
  def validate_connection(selecto) do
    adapter = runtime_adapter(selecto)
    connection = runtime_connection(selecto)

    cond do
      Selecto.AdapterSupport.callback_available?(adapter, :validate_connection, 1) ->
        Kernel.apply(adapter, :validate_connection, [connection])

      true ->
        {:error, "Invalid connection configuration"}
    end
  end

  @doc """
  Get connection statistics for monitoring.

  Returns information about the current connection state.
  """
  def connection_info(selecto) do
    adapter = runtime_adapter(selecto)
    connection = runtime_connection(selecto)

    cond do
      Selecto.AdapterSupport.callback_available?(adapter, :connection_info, 1) ->
        Kernel.apply(adapter, :connection_info, [connection])

      true ->
        %{
          type: :unknown,
          value: connection,
          status: :invalid
        }
    end
  end

  defp runtime_connection(selecto), do: Selecto.Runtime.Context.connection(selecto)
  defp runtime_adapter(selecto), do: Selecto.Runtime.Context.adapter(selecto)

  # `deadline` (monotonic milliseconds) is set when the adapter enforces the
  # timeout itself; it then receives the time remaining as `:timeout`.
  defp execute_with_hooks(selecto, hook_options, query_id, start_time, deadline) do
    Selecto.Performance.Hooks.with_hooks(
      selecto,
      fn _selecto, sql, params, context ->
        aliases = Map.get(context, :aliases, [])

        result =
          :telemetry.span(@query_execution_event, %{query_id: query_id}, fn ->
            result =
              execute_for_context(selecto, sql, params, aliases, deadline_options(deadline))

            duration = System.monotonic_time(:millisecond) - start_time

            stop_metadata =
              telemetry_stop_metadata(result, query_id)
              |> Map.put(:execution_time, duration)

            {result, stop_metadata}
          end)

        result
      end,
      hook_options
    )
  end

  defp deadline_options(nil), do: []

  defp deadline_options(deadline),
    do: [timeout: max(deadline - System.monotonic_time(:millisecond), 1)]

  defp hook_options(opts) do
    [
      cache: Keyword.get(opts, :cache, false),
      cache_ttl: Keyword.get(opts, :cache_ttl),
      cache_namespace: Keyword.get(opts, :cache_namespace),
      include_aliases: true,
      gen_sql_opts:
        Keyword.drop(opts, [
          :timeout,
          :analyze_complexity,
          :format,
          :format_options,
          :cache,
          :cache_ttl,
          :cache_namespace
        ])
    ]
  end

  defp execute_for_context(selecto, query, params, aliases, adapter_opts \\ []) do
    adapter = runtime_adapter(selecto)

    Selecto.Telemetry.span([:adapter], %{adapter: adapter}, fn ->
      execute_with_adapter(
        adapter,
        runtime_connection(selecto),
        query,
        params,
        aliases,
        adapter_opts
      )
    end)
  end

  defp execute_stream_for_context(selecto, query, params, aliases, opts) do
    execute_with_adapter_stream(
      runtime_adapter(selecto),
      runtime_connection(selecto),
      query,
      params,
      aliases,
      opts
    )
  end

  defp execute_with_adapter_stream(adapter, connection, query, params, aliases, opts) do
    cond do
      not adapter_supports_stream?(adapter) ->
        {:error,
         Selecto.Error.validation_error(
           "Streaming requires adapter.supports?(:stream) capability",
           %{
             adapter: adapter,
             stream_context: :adapter,
             adapter_contract: :supports_stream,
             unsupported_feature: :stream
           }
         )}

      not Selecto.AdapterSupport.callback_available?(adapter, :stream, 4) ->
        {:error,
         Selecto.Error.validation_error(
           "Adapter declares stream support but does not implement stream/4",
           %{adapter: adapter, stream_context: :adapter, adapter_contract: :stream_callback}
         )}

      true ->
        try do
          case adapter.stream(connection, query, params, opts) do
            {:ok, stream, columns} ->
              {:ok, Stream.map(stream, &{&1, List.wrap(columns), aliases})}

            {:ok, stream} ->
              {:ok, Stream.map(stream, &{&1, [], aliases})}

            {:error, {:invalid_stream_pool, details}} ->
              {:error,
               Selecto.Error.validation_error(
                 "Streaming requires a valid adapter pool connection reference",
                 details
               )}

            {:error, {:invalid_connection, _connection}} ->
              {:error,
               Selecto.Error.validation_error(
                 "Streaming requires adapter stream support for this connection",
                 %{adapter: adapter}
               )}

            {:error, reason} ->
              {:error, driver_error(adapter, reason)}
          end
        rescue
          FunctionClauseError ->
            {:error,
             Selecto.Error.validation_error(
               "Streaming requires adapter stream support for this connection",
               %{adapter: adapter}
             )}

          UndefinedFunctionError ->
            {:error,
             Selecto.Error.validation_error(
               "Adapter stream callback is unavailable",
               %{adapter: adapter, stream_context: :adapter, adapter_contract: :stream_callback}
             )}
        end
    end
  end

  defp adapter_supports_stream?(adapter) do
    Selecto.AdapterSupport.callback_available?(adapter, :supports?, 1) and
      adapter.supports?(:stream)
  rescue
    _ -> false
  end

  defp result_row_count({:ok, {rows, _columns, _aliases}}) when is_list(rows), do: length(rows)
  defp result_row_count(_), do: 0

  defp telemetry_stop_metadata(result, query_id) do
    %{
      query_id: query_id,
      row_count: result_row_count(result),
      status: telemetry_result_status(result)
    }
    |> maybe_put_error_type(result)
  end

  defp telemetry_result_status({:ok, _result}), do: :ok
  defp telemetry_result_status({:error, _reason}), do: :error
  defp telemetry_result_status(_), do: :unknown

  defp maybe_put_error_type(metadata, {:error, %Selecto.Error{type: type}}),
    do: Map.put(metadata, :error_type, type)

  defp maybe_put_error_type(metadata, {:error, reason}),
    do: Map.put(metadata, :error_type, infer_error_type(reason))

  defp maybe_put_error_type(metadata, _), do: metadata

  defp infer_error_type(reason) when is_exception(reason), do: reason.__struct__
  defp infer_error_type(reason) when is_atom(reason), do: reason
  defp infer_error_type(_reason), do: :unknown
end
