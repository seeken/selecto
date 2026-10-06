defmodule Selecto.ExecuteEntryPointTest do
  @moduledoc """
  `Selecto.execute/2` runs a query in a supervised task that it abandons when
  the timeout elapses, unless the adapter enforces the timeout itself
  (`supports?(:execute_timeout)`), in which case the query runs in the
  calling process. Both paths must return the same results, errors and
  telemetry, and must apply the same tenant and complexity checks first.
  """

  # Changes application env and registers hooks for the test process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Selecto.Performance.ComplexityAnalyzer
  alias Selecto.Performance.Hooks

  # Runs every query in a task (the default for adapters).
  defmodule TaskAdapter do
    def name, do: :entry_point_test
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: ~s("#{identifier}")

    def execute(connection, _query, _params, opts),
      do: Selecto.ExecuteEntryPointTest.respond(connection, opts)

    def supports?(_feature), do: false
  end

  # Enforces the `:timeout` option itself, so queries run in the caller.
  defmodule CallerAdapter do
    def name, do: :entry_point_test
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: ~s("#{identifier}")

    def execute(connection, _query, _params, opts),
      do: Selecto.ExecuteEntryPointTest.respond(connection, opts)

    def supports?(:execute_timeout), do: true
    def supports?(_feature), do: false
  end

  @adapters [TaskAdapter, CallerAdapter]

  @doc false
  def respond(connection, opts) do
    send(connection.test, {:adapter_execute, self(), opts})

    case connection do
      # A driver whose own timer fires on the deadline's millisecond tick and
      # returns its error within that millisecond.
      %{fire_on_deadline_tick: true} ->
        deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :timeout)
        wait_for_tick(deadline)
        {:error, :driver_timeout}

      %{sleep: sleep, honour_timeout: true} ->
        timeout = Keyword.fetch!(opts, :timeout)

        if sleep > timeout do
          Process.sleep(timeout)
          {:error, :driver_timeout}
        else
          Process.sleep(sleep)
          {:ok, %{rows: connection.rows, columns: ["id", "name"]}}
        end

      %{sleep: sleep} ->
        Process.sleep(sleep)
        {:ok, %{rows: connection.rows, columns: ["id", "name"]}}

      _connection ->
        {:ok, %{rows: connection.rows, columns: ["id", "name"]}}
    end
  end

  defp wait_for_tick(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: wait_for_tick(deadline)
  end

  def handle_event(event, measurements, metadata, test),
    do: send(test, {:telemetry_event, event, measurements, metadata})

  setup do
    Hooks.unregister(:before_execution)
    on_exit(fn -> Application.delete_env(:selecto, :complexity_warning_log) end)
    :ok
  end

  defp domain(table) do
    %{
      name: "Execute entry point",
      source: %{
        source_table: table,
        primary_key: :id,
        fields: [:id, :name, :tenant_id, :category_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          tenant_id: %{type: :integer},
          category_id: %{type: :integer}
        },
        associations: %{
          category: %{
            queryable: :categories,
            field: :category,
            owner_key: :category_id,
            related_key: :id
          }
        }
      },
      schemas: %{
        categories: %{
          source_table: "categories",
          primary_key: :id,
          fields: [:id, :name, :parent_id],
          redact_fields: [],
          columns: %{
            id: %{type: :integer},
            name: %{type: :string},
            parent_id: %{type: :integer}
          },
          associations: %{}
        }
      },
      joins: %{category: %{type: :left, name: "category"}}
    }
  end

  # A table name of its own gives each query a SQL shape no other test logs.
  defp unique_table, do: "entry_items_#{System.unique_integer([:positive])}"

  defp query(adapter, connection_overrides \\ %{}, table \\ "entry_items") do
    connection =
      Map.merge(%{test: self(), rows: [[1, "one"], [2, "two"]]}, connection_overrides)

    Selecto.configure(domain(table), nil, validate: false)
    |> Map.put(:adapter, adapter)
    |> Map.put(:connection, connection)
    |> Selecto.select(["id", "name"])
    |> Selecto.filter({"id", {:gt, 0}})
  end

  describe "where the query runs" do
    test "in a task, unless the adapter enforces the timeout itself" do
      assert {:ok, _result} = Selecto.execute(query(TaskAdapter))
      assert_received {:adapter_execute, task_pid, []}
      refute task_pid == self()

      assert {:ok, _result} = Selecto.execute(query(CallerAdapter), timeout: 1_000)
      assert_received {:adapter_execute, caller_pid, opts}
      assert caller_pid == self()
      assert opts[:timeout] in 1..1_000
    end

    test "in a task when performance hooks are registered or the cache is on" do
      Hooks.register(:before_execution, fn context -> context end)
      on_exit(fn -> Hooks.unregister(:before_execution) end)

      assert {:ok, _result} = Selecto.execute(query(CallerAdapter))
      assert_received {:adapter_execute, hooked_pid, []}
      refute hooked_pid == self()

      Hooks.unregister(:before_execution)

      namespace = "entry-point-#{System.unique_integer([:positive])}"

      assert {:ok, _result} =
               Selecto.execute(query(CallerAdapter), cache: true, cache_namespace: namespace)

      assert_received {:adapter_execute, cached_pid, []}
      refute cached_pid == self()
    end
  end

  describe "results" do
    test "are identical on both paths" do
      rows = for id <- 1..500, do: [id, "name #{id}"]

      for opts <- [[], [format: :maps], [analyze_complexity: false], [timeout: 5_000]] do
        [task_result, caller_result] =
          for adapter <- @adapters, do: Selecto.execute(query(adapter, %{rows: rows}), opts)

        assert {:ok, _} = task_result
        assert task_result == caller_result
      end

      [task_one, caller_one] =
        for adapter <- @adapters,
            do: Selecto.execute_one(query(adapter, %{rows: [[7, "seven"]]}))

      assert {:ok, {[7, "seven"], _aliases}} = task_one
      assert task_one == caller_one
    end

    test "the query compiles once, to the SQL gen_sql/2 produces" do
      query = query(TaskAdapter) |> Selecto.select(["category.name"])
      {sql, _aliases, params} = Selecto.gen_sql(query, [])
      test = self()

      handler_id = "entry-point-compile-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:selecto, :telemetry, :compile, :stop],
          &__MODULE__.handle_event/4,
          test
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      for adapter <- @adapters, analyze_complexity <- [true, false] do
        assert {:ok, _result} =
                 Selecto.execute(%{query | adapter: adapter},
                   analyze_complexity: analyze_complexity
                 )

        assert_received {:telemetry_event, [:selecto, :telemetry, :compile, :stop], _, _}
        refute_received {:telemetry_event, [:selecto, :telemetry, :compile, :stop], _, _}
      end

      Hooks.register(:before_execution, fn context ->
        send(test, {:compiled, context.sql, context.params})
        context
      end)

      on_exit(fn -> Hooks.unregister(:before_execution) end)

      for adapter <- @adapters, analyze_complexity <- [true, false] do
        assert {:ok, _result} =
                 Selecto.execute(%{query | adapter: adapter},
                   analyze_complexity: analyze_complexity
                 )

        assert_received {:compiled, ^sql, ^params}
        assert_received {:telemetry_event, [:selecto, :telemetry, :compile, :stop], _, _}
        refute_received {:telemetry_event, [:selecto, :telemetry, :compile, :stop], _, _}
      end
    end
  end

  describe "timeout" do
    test "both paths return the same timeout error, log and telemetry" do
      handler_id = "entry-point-timeout-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:selecto, :query, :timeout],
          &__MODULE__.handle_event/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      for {adapter, connection} <- [
            {TaskAdapter, %{sleep: 500}},
            {CallerAdapter, %{sleep: 500, honour_timeout: true}},
            # An adapter that returns late anyway still yields the timeout.
            {CallerAdapter, %{sleep: 120}}
          ] do
        log =
          capture_log(fn ->
            assert {:error, %Selecto.Error{} = error} =
                     Selecto.execute(query(adapter, connection), timeout: 50)

            assert error.type == :timeout_error
            assert error.message == "Query exceeded timeout of 50ms"
            assert %{timeout: 50, duration: duration} = error.details
            assert map_size(error.details) == 2
            assert duration >= 50
          end)

        assert log =~ "[error] [Selecto] Query timeout after 50ms"

        assert_received {:telemetry_event, [:selecto, :query, :timeout],
                         %{duration: _, timeout: 50} = measurements, %{query_id: query_id}}

        assert map_size(measurements) == 2
        assert is_binary(query_id)
      end
    end

    test "a driver timeout that fires on the deadline's millisecond is the timeout error" do
      for _attempt <- 1..25 do
        capture_log(fn ->
          assert {:error, %Selecto.Error{type: :timeout_error} = error} =
                   Selecto.execute(query(CallerAdapter, %{fire_on_deadline_tick: true}),
                     timeout: 5
                   )

          assert error.message == "Query exceeded timeout of 5ms"
        end)
      end
    end

    test "a query that finishes in time is not affected by the timeout" do
      for {adapter, connection} <- [
            {TaskAdapter, %{sleep: 10}},
            {CallerAdapter, %{sleep: 10, honour_timeout: true}}
          ] do
        assert {:ok, {[[1, "one"], [2, "two"]], ["id", "name"], _aliases}} =
                 Selecto.execute(query(adapter, connection), timeout: 2_000)
      end
    end

    test "the adapter receives the time remaining, capped at five minutes" do
      assert {:ok, _result} = Selecto.execute(query(CallerAdapter))
      assert_received {:adapter_execute, _pid, opts}
      assert opts[:timeout] in 29_000..30_000

      assert {:ok, _result} = Selecto.execute(query(CallerAdapter), timeout: 900_000)
      assert_received {:adapter_execute, _pid, opts}
      assert opts[:timeout] in 299_000..300_000
    end
  end

  describe "checks before execution" do
    test "a tenant scope violation is rejected before the adapter runs" do
      for adapter <- @adapters do
        query =
          adapter
          |> query()
          |> Selecto.Tenant.with_tenant(%{tenant_id: 5, tenant_field: :tenant_id})

        assert {:error, %Selecto.Error{type: :validation_error}} = Selecto.execute(query)
        refute_received {:adapter_execute, _pid, _opts}
      end
    end

    test "a query that cannot compile raises the same error on both paths" do
      for adapter <- @adapters, opts <- [[], [analyze_complexity: false]] do
        query =
          adapter
          |> query()
          |> Map.update!(:set, fn set ->
            Map.update!(set, :filtered, &(&1 ++ [{"no_such_field", 1}]))
          end)

        assert_raise RuntimeError, ~r/no_such_field/, fn -> Selecto.execute(query, opts) end
        refute_received {:adapter_execute, _pid, _opts}
      end
    end

    test "a query the complexity check rejects never reaches the adapter" do
      for adapter <- @adapters do
        assert {:error,
                %Selecto.Error{
                  type: :validation_error,
                  message: "Query too complex to execute safely"
                }} = Selecto.execute(query(adapter), max_complexity: 0)

        refute_received {:adapter_execute, _pid, _opts}
      end
    end

    test "the check on the compiled joins matches the standalone analysis" do
      base = query(TaskAdapter)

      queries = [
        base,
        Selecto.select(base, ["category.name"]),
        Selecto.filter(base, {"category.name", "books"}),
        base |> Selecto.select(["category.name"]) |> Selecto.order_by(["category.id"]),
        Map.update!(base, :set, &Map.put(&1, :filtered, []))
      ]

      for query <- queries, opts <- [[], [max_joins: 0], [max_complexity: 5]] do
        {_sql, _aliases, _params, joins} = Selecto.gen_sql_with_joins(query, [])

        assert ComplexityAnalyzer.analyze_resolved(query, joins, opts) ==
                 ComplexityAnalyzer.analyze(query, opts)
      end
    end
  end

  test "shared tables outlive the processes that use them" do
    for table <- [:selecto_hooks_store, :selecto_complexity_warnings_logged] do
      owner = :ets.info(table, :owner)
      assert is_pid(owner)
      refute owner == self()

      # A short-lived caller does not take the table with it.
      Task.async(fn -> Selecto.execute(query(CallerAdapter)) end) |> Task.await()
      assert :ets.info(table, :owner) == owner
    end
  end

  describe "complexity warnings" do
    test "are logged once per query shape, with the same level and text" do
      table = unique_table()
      large_in = Enum.to_list(1..150)

      for adapter <- @adapters do
        log =
          capture_log(fn ->
            for _call <- 1..3 do
              assert {:ok, _result} =
                       adapter
                       |> query(%{}, table)
                       |> Selecto.filter({"id", {:in, large_in}})
                       |> Selecto.execute()
            end
          end)

        message = "[warning] [Selecto] Query complexity: Large IN clause with 150 values"
        expected = if adapter == TaskAdapter, do: 1, else: 0
        assert length(String.split(log, message)) - 1 == expected
      end

      # Another shape is logged again.
      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   TaskAdapter
                   |> query(%{}, table)
                   |> Selecto.filter({"id", {:in, Enum.to_list(1..151)}})
                   |> Selecto.execute()
        end)

      assert log =~ "Large IN clause with 151 values"
    end

    test "are logged on every call when configured" do
      Application.put_env(:selecto, :complexity_warning_log, :every_call)
      table = unique_table()

      log =
        capture_log(fn ->
          for _call <- 1..3 do
            assert {:ok, _result} =
                     TaskAdapter
                     |> query(%{}, table)
                     |> Map.update!(:set, &Map.put(&1, :filtered, []))
                     |> Selecto.execute()
          end
        end)

      message =
        "[warning] [Selecto] Query complexity: No WHERE clause - potential full table scan"

      assert length(String.split(log, message)) - 1 == 3
    end

    test "the analysis event is emitted on every call" do
      handler_id = "entry-point-complexity-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:selecto, :query, :complexity_analyzed],
          &__MODULE__.handle_event/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      query = query(TaskAdapter) |> Map.update!(:set, &Map.put(&1, :filtered, []))

      capture_log(fn ->
        for _call <- 1..2 do
          assert {:ok, _result} = Selecto.execute(query)

          assert_received {:telemetry_event, [:selecto, :query, :complexity_analyzed],
                           %{complexity_score: _}, %{warning_count: 1, query_id: _}}
        end
      end)
    end
  end

  describe "telemetry" do
    @events (for phase <- [:operation, :compile, :adapter, :transform],
                 terminal <- [:start, :stop, :exception] do
               [:selecto, :telemetry, phase, terminal]
             end) ++
              [
                [:selecto, :query, :execution, :start],
                [:selecto, :query, :execution, :stop],
                [:selecto, :query, :execution, :exception],
                [:selecto, :query, :complexity_analyzed],
                [:selecto, :query, :complexity_rejected],
                [:selecto, :query, :complete],
                [:selecto, :query, :timeout],
                [:selecto, :query, :error]
              ]

    # Event names with their measurement and metadata keys, as emitted by
    # Selecto.execute/2 before it could run queries in the caller.
    @expected [
      {[:selecto, :telemetry, :operation, :start], [:monotonic_time, :system_time],
       [
         :adapter,
         :operation_id,
         :operation_kind,
         :schema_version,
         :telemetry_span_context
       ]},
      {[:selecto, :query, :complexity_analyzed], [:complexity_score],
       [:query_id, :warning_count]},
      {[:selecto, :telemetry, :compile, :start], [:monotonic_time, :system_time],
       [
         :adapter,
         :operation_id,
         :operation_kind,
         :schema_version,
         :telemetry_span_context
       ]},
      {[:selecto, :telemetry, :compile, :stop], [:duration, :monotonic_time],
       [
         :adapter,
         :operation_id,
         :operation_kind,
         :outcome,
         :schema_version,
         :telemetry_span_context
       ]},
      {[:selecto, :query, :execution, :start], [:monotonic_time, :system_time],
       [:query_id, :telemetry_span_context]},
      {[:selecto, :telemetry, :adapter, :start], [:monotonic_time, :system_time],
       [
         :adapter,
         :operation_id,
         :operation_kind,
         :schema_version,
         :telemetry_span_context
       ]},
      {[:selecto, :telemetry, :adapter, :stop], [:duration, :monotonic_time],
       [
         :adapter,
         :operation_id,
         :operation_kind,
         :outcome,
         :row_count,
         :schema_version,
         :telemetry_span_context
       ]},
      {[:selecto, :query, :execution, :stop], [:duration, :monotonic_time],
       [:execution_time, :query_id, :row_count, :status, :telemetry_span_context]},
      {[:selecto, :query, :complete], [:duration, :execution_time], [:cache_hit, :query_id]},
      {[:selecto, :telemetry, :transform, :start], [:monotonic_time, :system_time],
       [
         :adapter,
         :operation_id,
         :operation_kind,
         :schema_version,
         :telemetry_span_context
       ]},
      {[:selecto, :telemetry, :transform, :stop], [:duration, :monotonic_time],
       [
         :adapter,
         :operation_id,
         :operation_kind,
         :outcome,
         :row_count,
         :schema_version,
         :telemetry_span_context
       ]},
      {[:selecto, :telemetry, :operation, :stop], [:duration, :monotonic_time],
       [
         :adapter,
         :operation_id,
         :operation_kind,
         :outcome,
         :row_count,
         :schema_version,
         :telemetry_span_context
       ]}
    ]

    test "both paths emit the same events with the same measurement and metadata keys" do
      handler_id = "entry-point-telemetry-#{System.unique_integer([:positive])}"
      :ok = :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      for adapter <- @adapters do
        assert {:ok, _result} = Selecto.execute(query(adapter))

        emitted =
          for {event, measurements, metadata} <- drain_events() do
            {event, measurements |> Map.keys() |> Enum.sort(),
             metadata |> Map.keys() |> Enum.sort()}
          end

        assert Enum.sort(emitted) == Enum.sort(@expected)
      end
    end

    defp drain_events(acc \\ []) do
      receive do
        {:telemetry_event, event, measurements, metadata} ->
          drain_events([{event, measurements, metadata} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end
end
