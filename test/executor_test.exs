defmodule Selecto.ExecutorTest do
  use ExUnit.Case

  alias Selecto.Executor
  alias Selecto.Performance.Hooks

  def handle_span_event(event, measurements, metadata, parent) when is_pid(parent) do
    send(parent, {:executor_span_event, event, measurements, metadata})
  end

  defmodule Adapter do
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: ~s("#{identifier}")

    def execute(:single, _query, _params, _opts), do: {:ok, %{rows: [[1]], columns: ["id"]}}
    def execute(:empty, _query, _params, _opts), do: {:ok, %{rows: [], columns: ["id"]}}

    def execute(:multiple, _query, _params, _opts),
      do: {:ok, %{rows: [[1], [2]], columns: ["id"]}}

    def execute(:error, _query, _params, _opts), do: {:error, "adapter failed"}

    def execute(:raise, _query, _params, _opts) do
      raise "adapter raised"
    end

    def execute(:exit, _query, _params, _opts) do
      exit(:adapter_exit)
    end

    def execute(:sleep, _query, _params, _opts) do
      Process.sleep(50)
      {:ok, %{rows: [[1]], columns: ["id"]}}
    end

    def stream(:single_stream, _query, _params, _opts) do
      {:ok, Stream.map([[1], [2]], & &1), ["id"]}
    end

    def stream(:stream_error, _query, _params, _opts), do: {:error, "stream failed"}

    def stream(:stream_raise, _query, _params, _opts) do
      {:ok, Stream.map([[1]], fn _row -> raise "secret-stream-canary" end), ["id"]}
    end

    def supports?(:stream), do: true
    def supports?(:projection_sum), do: true
    def supports?(_feature), do: false
  end

  defmodule NoStreamCapabilityAdapter do
    def placeholder(_index), do: "?"

    def execute(:single_stream, _query, _params, _opts),
      do: {:ok, %{rows: [[1]], columns: ["id"]}}

    def stream(:single_stream, _query, _params, _opts),
      do: {:ok, Stream.map([[1]], & &1), ["id"]}

    def supports?(_feature), do: false
  end

  defmodule DeclaredStreamMissingAdapter do
    def placeholder(_index), do: "?"

    def execute(:single_stream, _query, _params, _opts),
      do: {:ok, %{rows: [[1]], columns: ["id"]}}

    def supports?(:stream), do: true
    def supports?(_feature), do: false
  end

  defmodule FakeRepo do
    def __adapter__, do: :fake
  end

  defp domain do
    %{
      name: "Executor test",
      source: %{
        source_table: "users",
        primary_key: :id,
        fields: [:id, :name],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp selecto_for(connection, adapter \\ Adapter) do
    Selecto.configure(domain(), nil)
    |> Selecto.select(["id"])
    |> Map.put(:adapter, adapter)
    |> Map.put(:connection, connection)
  end

  defp postgrex_stream_selecto(connection) do
    Selecto.configure(domain(), connection)
    |> Selecto.select(["id"])
    |> Map.put(:adapter, SelectoDBPostgreSQL.Adapter)
    |> Map.put(:connection, connection)
  end

  test "execute_with_adapter normalizes successful results" do
    assert {:ok, {[[1]], ["id"], ["id"]}} =
             Executor.execute_with_adapter(Adapter, :single, "select 1", [], ["id"])
  end

  defmodule GovernedAdapter do
    def execute_query(connection, query, params, opts) do
      send(self(), {:governed_query, connection, query, params, opts})
      {:ok, %{rows: [[1]], columns: ["id"]}}
    end

    def execute(_, _, _, _), do: raise("trusted execution port selected")
  end

  test "execute_with_adapter prefers the governed read query port when implemented" do
    assert {:ok, {[[1]], ["id"], ["id"]}} =
             Executor.execute_with_adapter(GovernedAdapter, :connection, "select ?", [1], ["id"],
               timeout: 500
             )

    assert_received {:governed_query, :connection, "select ?", [1], [timeout: 500]}
  end

  test "execute_with_adapter wraps adapter errors" do
    assert {:error, %Selecto.Error{type: :query_error}} =
             Executor.execute_with_adapter(Adapter, :error, "select 1", [], ["id"])
  end

  test "execute_with_adapter handles raised exceptions" do
    assert {:error, %Selecto.Error{type: :connection_error}} =
             Executor.execute_with_adapter(Adapter, :raise, "select 1", [], ["id"])
  end

  test "execute_with_adapter handles exits" do
    assert {:error, %Selecto.Error{type: :connection_error}} =
             Executor.execute_with_adapter(Adapter, :exit, "select 1", [], ["id"])
  end

  test "execute_with_adapter rejects invalid connection types" do
    assert {:error, %Selecto.Error{type: :connection_error}} =
             Executor.execute_with_adapter(
               SelectoDBPostgreSQL.Adapter,
               123,
               "select 1",
               [],
               ["id"]
             )
  end

  test "execute_with_connection_pool returns normalized pooled result" do
    pool_ref = %{adapter: Adapter, connection: :single}

    assert {:ok, {[[1]], ["id"], ["id"]}} =
             Executor.execute_with_connection_pool(pool_ref, "select 1", [], ["id"])
  end

  test "execute_with_connection_pool wraps pooled execution errors" do
    pool_ref = %{adapter: Adapter, connection: :error}

    assert {:error, %Selecto.Error{type: :query_error}} =
             Executor.execute_with_connection_pool(pool_ref, "select 1", [], ["id"])
  end

  test "execute_stream uses adapter stream/4 when available" do
    assert {:ok, stream} =
             Executor.execute_stream(selecto_for(:single_stream), analyze_complexity: false)

    rows = Enum.to_list(stream)

    assert [{[1], ["id"], aliases_1}, {[2], ["id"], aliases_2}] = rows
    assert is_list(aliases_1)
    assert is_binary(hd(aliases_1))
    assert aliases_1 == aliases_2
  end

  test "stream telemetry distinguishes exhaustion from consumer cancellation" do
    handler_id = "selecto-stream-lifecycle-#{System.unique_integer([:positive])}"

    events = [
      [:selecto, :telemetry, :stream, :start],
      [:selecto, :telemetry, :stream, :stop],
      [:selecto, :telemetry, :stream, :exception]
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_span_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, complete_stream} =
             Executor.execute_stream(selecto_for(:single_stream), analyze_complexity: false)

    assert length(Enum.to_list(complete_stream)) == 2

    assert_receive {:executor_span_event, [:selecto, :telemetry, :stream, :start], _, _}

    assert_receive {:executor_span_event, [:selecto, :telemetry, :stream, :stop], %{row_count: 2},
                    %{stream_result: :completed, outcome: :ok}}

    assert {:ok, cancelled_stream} =
             Executor.execute_stream(selecto_for(:single_stream), analyze_complexity: false)

    assert length(Enum.take(cancelled_stream, 1)) == 1

    assert_receive {:executor_span_event, [:selecto, :telemetry, :stream, :start], _, _}

    assert_receive {:executor_span_event, [:selecto, :telemetry, :stream, :stop], %{row_count: 1},
                    %{stream_result: :cancelled, outcome: :cancelled}}
  end

  test "stream telemetry sanitizes enumeration exceptions" do
    handler_id = "selecto-stream-exception-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:selecto, :telemetry, :stream, :exception],
        &__MODULE__.handle_span_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, stream} =
             Executor.execute_stream(selecto_for(:stream_raise), analyze_complexity: false)

    assert_raise RuntimeError, "secret-stream-canary", fn -> Enum.to_list(stream) end

    assert_receive {:executor_span_event, [:selecto, :telemetry, :stream, :exception],
                    %{row_count: 0}, metadata}

    assert metadata.outcome == :error
    assert metadata.status == RuntimeError
    refute inspect(metadata) =~ "secret-stream-canary"
  end

  test "execute_stream wraps adapter stream errors" do
    assert {:error, %Selecto.Error{type: :query_error}} =
             Executor.execute_stream(selecto_for(:stream_error), analyze_complexity: false)
  end

  test "execute_stream returns validation error when adapter lacks stream support for connection" do
    assert {:error, %Selecto.Error{type: :validation_error}} =
             Executor.execute_stream(selecto_for(:single), analyze_complexity: false)
  end

  test "execute_stream enforces adapter supports(:stream) contract" do
    assert {:error, %Selecto.Error{type: :validation_error, details: details}} =
             Executor.execute_stream(
               selecto_for(:single_stream, NoStreamCapabilityAdapter),
               analyze_complexity: false
             )

    assert details[:unsupported_feature] == :stream
    assert details[:adapter_contract] == :supports_stream
  end

  test "execute_stream validates stream callback when support is declared" do
    assert {:error, %Selecto.Error{type: :validation_error, details: details}} =
             Executor.execute_stream(
               selecto_for(:single_stream, DeclaredStreamMissingAdapter),
               analyze_complexity: false
             )

    assert details[:adapter_contract] == :stream_callback
  end

  test "execute_stream returns explicit contract error for pooled postgres" do
    assert {:error, %Selecto.Error{type: :validation_error, details: details}} =
             Executor.execute_stream(postgrex_stream_selecto({:pool, %{}}),
               analyze_complexity: false
             )

    assert details[:stream_context] == :pool
  end

  test "execute_stream supports pooled postgres when pool connection is available" do
    assert {:ok, stream} =
             Executor.execute_stream(
               postgrex_stream_selecto({:pool, %{pool: :fake_pool}}),
               analyze_complexity: false,
               stream_producer: fn send_chunk ->
                 send_chunk.([[7], [8]], ["id"])
                 {:ok, :done}
               end
             )

    assert [{[7], ["id"], aliases_1}, {[8], ["id"], aliases_2}] = Enum.to_list(stream)
    assert aliases_1 == aliases_2
  end

  test "execute_stream leaves repository-shaped handles to the configured adapter" do
    assert {:ok, stream} =
             Executor.execute_stream(postgrex_stream_selecto(FakeRepo),
               analyze_complexity: false
             )

    assert Enum.count(stream) == 2
  end

  test "execute_stream receive_timeout errors when producer stalls" do
    assert {:ok, stream} =
             Executor.execute_stream(
               postgrex_stream_selecto(:fake_conn),
               analyze_complexity: false,
               receive_timeout: 5,
               queue_timeout: 1,
               stream_producer: fn _send_chunk ->
                 Process.sleep(30)
                 {:ok, :done}
               end
             )

    assert_raise RuntimeError, ~r/Timed out waiting for streamed rows/, fn ->
      Enum.to_list(stream)
    end
  end

  test "execute_stream consumes custom postgrex producer chunks" do
    assert {:ok, stream} =
             Executor.execute_stream(
               postgrex_stream_selecto(:fake_conn),
               analyze_complexity: false,
               stream_producer: fn send_chunk ->
                 send_chunk.([[10], [20]], ["id"])
                 {:ok, :done}
               end
             )

    assert [{[10], ["id"], aliases_1}, {[20], ["id"], aliases_2}] = Enum.to_list(stream)
    assert aliases_1 == aliases_2
    assert is_binary(hd(aliases_1))
  end

  test "execute returns timeout error for long-running adapter" do
    result = Executor.execute(selecto_for(:sleep), analyze_complexity: false, timeout: 1)
    assert {:error, %Selecto.Error{type: :timeout_error}} = result
  end

  test "execute stops when complexity analysis rejects the query" do
    assert {:error, %Selecto.Error{type: :validation_error}} =
             Executor.execute(selecto_for(:single), max_complexity: 0)
  end

  test "execute routes through performance hook orchestration" do
    Hooks.unregister(:before_query_build)
    parent = self()

    Hooks.register(:before_query_build, fn context ->
      send(parent, {:before_query_build, context.query_id})
      context
    end)

    assert {:ok, {[[1]], ["id"], _aliases}} =
             Executor.execute(selecto_for(:single), analyze_complexity: false)

    assert_received {:before_query_build, query_id}
    assert is_binary(query_id)

    Hooks.unregister(:before_query_build)
  end

  test "execute emits telemetry span lifecycle for successful query" do
    handler_id = "selecto-executor-span-success-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:selecto, :query, :execution, :start],
          [:selecto, :query, :execution, :stop],
          [:selecto, :query, :execution, :exception]
        ],
        &__MODULE__.handle_span_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, {[[1]], ["id"], _aliases}} =
             Executor.execute(selecto_for(:single), analyze_complexity: false)

    events = drain_span_events()

    assert Enum.any?(events, fn
             {:executor_span_event, [:selecto, :query, :execution, :start], _measurements,
              metadata} ->
               is_binary(metadata.query_id) and not Map.has_key?(metadata, :query)

             _ ->
               false
           end)

    assert Enum.any?(events, fn
             {:executor_span_event, [:selecto, :query, :execution, :stop], measurements, metadata} ->
               is_integer(measurements.duration) and measurements.duration >= 0 and
                 metadata.status == :ok and metadata.row_count == 1

             _ ->
               false
           end)

    refute Enum.any?(events, fn
             {:executor_span_event, [:selecto, :query, :execution, :exception], _, _} -> true
             _ -> false
           end)
  end

  test "execute emits one correlated safe canonical lifecycle and child phases" do
    handler_id = "selecto-canonical-span-#{System.unique_integer([:positive])}"

    events =
      for phase <- [:operation, :compile, :adapter], terminal <- [:start, :stop] do
        [:selecto, :telemetry, phase, terminal]
      end

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_span_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, {[[1]], ["id"], _aliases}} =
             Executor.execute(selecto_for(:single), analyze_complexity: false)

    captured = drain_span_events()

    operation_stop =
      Enum.find_value(captured, fn
        {:executor_span_event, [:selecto, :telemetry, :operation, :stop], _, metadata} ->
          metadata

        _event ->
          nil
      end)

    assert %{operation_id: operation_id, outcome: :ok, row_count: 1} = operation_stop

    for phase <- [:compile, :adapter] do
      assert Enum.any?(captured, fn
               {:executor_span_event, [:selecto, :telemetry, ^phase, :stop], _, metadata} ->
                 metadata.operation_id == operation_id

               _event ->
                 false
             end)
    end

    refute inspect(captured) =~ "SELECT"
  end

  test "execute emits telemetry span stop metadata for query errors" do
    handler_id = "selecto-executor-span-error-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:selecto, :query, :execution, :start],
          [:selecto, :query, :execution, :stop],
          [:selecto, :query, :execution, :exception]
        ],
        &__MODULE__.handle_span_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, %Selecto.Error{type: :query_error}} =
             Executor.execute(selecto_for(:error), analyze_complexity: false)

    events = drain_span_events()

    assert Enum.any?(events, fn
             {:executor_span_event, [:selecto, :query, :execution, :stop], _measurements,
              metadata} ->
               metadata.status == :error and metadata.error_type == :query_error

             _ ->
               false
           end)

    refute Enum.any?(events, fn
             {:executor_span_event, [:selecto, :query, :execution, :exception], _, _} -> true
             _ -> false
           end)
  end

  test "execute_one returns row, no_results, and multiple_results variants" do
    assert {:ok, {[1], aliases}} =
             Executor.execute_one(selecto_for(:single), analyze_complexity: false)

    assert is_list(aliases)
    assert length(aliases) == 1
    assert is_binary(hd(aliases))

    assert {:error, %Selecto.Error{type: :no_results}} =
             Executor.execute_one(selecto_for(:empty), analyze_complexity: false)

    assert {:error, %Selecto.Error{type: :multiple_results}} =
             Executor.execute_one(selecto_for(:multiple), analyze_complexity: false)
  end

  test "execute_with_metadata returns sql and execution_time" do
    assert {:ok, _result, metadata} = Executor.execute_with_metadata(selecto_for(:single))
    assert is_binary(metadata.sql)
    assert is_list(metadata.params)
    assert is_integer(metadata.execution_time)
  end

  test "execute_count_with_metadata wraps the unpaginated query and reports timing" do
    assert {:ok, 1, metadata} =
             Executor.execute_count_with_metadata(selecto_for(:single),
               analyze_complexity: false
             )

    assert metadata.sql =~ "SELECT COUNT(*) AS selecto_total_count FROM ("
    assert metadata.sql =~ ") AS selecto_count_source"
    assert is_list(metadata.params)
    assert is_integer(metadata.execution_time)
  end

  test "count and projection sum drop an unpaginated ORDER BY from their derived table" do
    ordered = Selecto.order_by(selecto_for(:single), "id")

    assert {:ok, 1, count} =
             Executor.execute_count_with_metadata(ordered, analyze_complexity: false)

    refute count.sql =~ ~r/order by/i

    assert {:ok, 1, sum} =
             Selecto.execute_projection_sum_with_metadata(ordered, "id",
               analyze_complexity: false
             )

    refute sum.sql =~ ~r/order by/i

    paged = ordered |> Selecto.limit(1) |> Selecto.offset(0)

    assert {:ok, 1, paged_count} =
             Executor.execute_count_with_metadata(paged, analyze_complexity: false)

    assert paged_count.sql =~ ~r/order by/i
  end

  test "projection sum folds a governed query in the database without returning root rows" do
    assert {:ok, 1, metadata} =
             Selecto.execute_projection_sum_with_metadata(selecto_for(:single), "id",
               analyze_complexity: false
             )

    assert metadata.sql =~ "SUM(selecto_projection_source.\"selecto_projection_1\")"
    assert metadata.sql =~ ~r/FROM \(\s*select\b/i
    assert metadata.sql =~ ") AS selecto_projection_source"
    assert is_list(metadata.params)
    assert is_integer(metadata.execution_time)

    assert {:error, %Selecto.Error{}} =
             Selecto.execute_projection_sum_with_metadata(selecto_for(:single), "id);DROP")

    assert {:error, %Selecto.Error{}} =
             Selecto.execute_projection_sum_with_metadata(selecto_for(:single), "missing")

    assert {:error, %Selecto.Error{}} =
             Selecto.execute_projection_sum_with_metadata(
               selecto_for(:single, NoStreamCapabilityAdapter),
               "id"
             )
  end

  test "validate_connection delegates pid lifecycle checks to the adapter" do
    pid = spawn(fn -> Process.sleep(:infinity) end)

    selecto = %Selecto{adapter: SelectoDBPostgreSQL.Adapter, connection: pid}
    assert :ok == Executor.validate_connection(selecto)
    Process.exit(pid, :kill)
    Process.sleep(10)

    assert {:error, "Postgrex connection process is not alive"} ==
             Executor.validate_connection(selecto)
  end

  test "connection_info describes repo, pid, and unknown connections" do
    repo_info =
      Executor.connection_info(%Selecto{
        adapter: SelectoDBPostgreSQL.Adapter,
        connection: SomeRepo
      })

    assert %{type: :ecto_repo, repo: SomeRepo, status: :connected} = repo_info

    pid = spawn(fn -> Process.sleep(:infinity) end)

    pid_info =
      Executor.connection_info(%Selecto{adapter: SelectoDBPostgreSQL.Adapter, connection: pid})

    assert %{type: :postgrex, pid: ^pid, status: :connected} = pid_info
    Process.exit(pid, :kill)

    unknown =
      Executor.connection_info(%Selecto{adapter: SelectoDBPostgreSQL.Adapter, connection: 123})

    assert %{type: :unknown, status: :invalid, value: 123} = unknown
  end

  describe "execution guards" do
    test "metadata, count and projection sum execution apply the task timeout" do
      opts = [analyze_complexity: false, timeout: 1]

      for run <- [
            &Executor.execute_with_metadata(&1, opts),
            &Executor.execute_count_with_metadata(&1, opts),
            &Executor.execute_projection_sum_with_metadata(&1, "id", opts)
          ] do
        assert {:error, %Selecto.Error{type: :timeout_error}} = run.(selecto_for(:sleep))
      end
    end

    test "metadata, count, projection sum and stream execution apply the complexity check" do
      opts = [max_complexity: 0]

      for {connection, run} <- [
            single: &Executor.execute_with_metadata(&1, opts),
            single: &Executor.execute_count_with_metadata(&1, opts),
            single: &Executor.execute_projection_sum_with_metadata(&1, "id", opts),
            single_stream: &Executor.execute_stream(&1, opts)
          ] do
        assert {:error,
                %Selecto.Error{
                  type: :validation_error,
                  message: "Query too complex to execute safely"
                }} = run.(selecto_for(connection))
      end
    end
  end

  describe "driver error disclosure" do
    defmodule LeakyDriverAdapter do
      def placeholder(_index), do: "?"
      def quote_identifier(identifier), do: ~s("#{identifier}")
      def supports?(:stream), do: true
      def supports?(_feature), do: false

      def execute(:raise_encode, _query, _params, _opts),
        do: raise(DBConnection.EncodeError, "Postgrex expected an integer, got \"canary-param\"")

      def execute(:exit, query, params, _opts),
        do: exit({:timeout, {Postgrex, :call, [query, params]}})

      def execute([password: _] = connection, _query, _params, _opts),
        do: {:error, {:invalid_connection, connection}}

      def execute(_connection, query, _params, _opts), do: {:error, unique_violation(query)}
      def stream(_connection, query, _params, _opts), do: {:error, unique_violation(query)}

      def unique_violation(query) do
        %Postgrex.Error{
          postgres: %{
            code: :unique_violation,
            pg_code: "23505",
            severity: "ERROR",
            message: ~s(duplicate key value violates unique constraint "users_email_key"),
            detail: "Key (email)=(canary@example.com) already exists.",
            constraint: "users_email_key",
            table: "users"
          },
          query: query
        }
      end
    end

    # Normalizes as SelectoDBPostgreSQL.Adapter does: the driver message
    # (with its query and detail) plus constraint and column names.
    defmodule NormalizingDriverAdapter do
      defdelegate placeholder(index), to: LeakyDriverAdapter
      defdelegate quote_identifier(identifier), to: LeakyDriverAdapter
      defdelegate supports?(feature), to: LeakyDriverAdapter
      defdelegate execute(connection, query, params, opts), to: LeakyDriverAdapter
      defdelegate stream(connection, query, params, opts), to: LeakyDriverAdapter

      def normalize_error(%Postgrex.Error{} = error) do
        Selecto.Error.query_error(Exception.message(error), nil, [], %{
          category: :unique_violation,
          constraint: error.postgres.constraint,
          column: "email",
          recoverable?: true
        })
      end

      def normalize_error(reason), do: Selecto.Error.from_reason(reason)
    end

    defp leaky_selecto(adapter, connection \\ :leaky) do
      selecto_for(connection, adapter) |> Selecto.filter({"name", "canary-param"})
    end

    defp entry_points do
      opts = [analyze_complexity: false]

      [
        execute: &Executor.execute(&1, opts),
        execute_with_metadata: &Executor.execute_with_metadata(&1, opts),
        execute_count_with_metadata: &Executor.execute_count_with_metadata(&1, opts),
        execute_stream: &Executor.execute_stream(&1, opts)
      ]
    end

    defp assert_undisclosed(%Selecto.Error{} = error) do
      rendered = inspect(error, limit: :infinity, printable_limit: :infinity)

      for secret <- ["canary", "users_email_key", "email", "selecto_root", "users", "select"] do
        refute rendered =~ secret, "#{secret} disclosed by #{rendered}"
      end

      assert error.query == nil
      assert error.params in [nil, []]
    end

    test "database errors reach callers without SQL, parameters or server detail" do
      for adapter <- [LeakyDriverAdapter, NormalizingDriverAdapter],
          {_entry, run} <- entry_points() do
        assert {:error, %Selecto.Error{type: :query_error} = error} = run.(leaky_selecto(adapter))
        assert_undisclosed(error)
        assert error.details.category == :unique_violation
        assert error.details.sqlstate == "23505"
      end
    end

    test "raised driver errors, exits and connection options are not disclosed" do
      for connection <- [:raise_encode, :exit, [password: "canary-password"]],
          {_entry, run} <- entry_points() do
        case run.(leaky_selecto(LeakyDriverAdapter, connection)) do
          {:error, %Selecto.Error{} = error} -> assert_undisclosed(error)
          {:ok, _stream} -> :ok
        end
      end

      for reason <- [
            %Postgrex.Error{
              postgres: %{code: :undefined_table, pg_code: "42P01"},
              query: "select"
            },
            {:invalid_connection, [password: "canary-password"]},
            {:invalid_connection_options, [password: "canary-password"]},
            {:exit, {:timeout, {Postgrex, :call, ["select", ["canary-param"]]}}},
            %{message: "canary", statement: "select"}
          ] do
        assert_undisclosed(Selecto.Error.from_reason(reason))
      end
    end
  end

  defp drain_span_events(acc \\ []) do
    receive do
      {:executor_span_event, _event, _measurements, _metadata} = payload ->
        drain_span_events([payload | acc])
    after
      25 ->
        Enum.reverse(acc)
    end
  end
end
