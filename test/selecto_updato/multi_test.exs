defmodule SelectoUpdato.MultiTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{Batch, Command, Error, Result}

  def full_write_capabilities do
    %{
      protocol_version: 1,
      insert: true,
      update: true,
      upsert: true,
      delete: true,
      returning: true,
      generated_keys: :returning,
      transactions: true,
      atomic_batch: true,
      write_graph: true
    }
  end

  defmodule BatchAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :batch_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false
    def write_capabilities(_connection), do: SelectoUpdato.MultiTest.full_write_capabilities()
    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}

    def execute_write(_connection, %Batch{} = batch, opts) do
      send(self(), {:atomic_batch, batch, opts})

      {:ok,
       Enum.map(batch.commands, fn %Command{operation: operation} ->
         %Result{operation: operation, affected_rows: 1}
       end)}
    end
  end

  defmodule FailingAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :failing_batch_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false
    def write_capabilities(_connection), do: SelectoUpdato.MultiTest.full_write_capabilities()
    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}

    def execute_write(_connection, %Batch{}, _opts) do
      {:error, Error.new(:adapter_failure, "transaction rolled back")}
    end
  end

  defmodule ShortResultAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :short_result_batch_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false
    def write_capabilities(_connection), do: SelectoUpdato.MultiTest.full_write_capabilities()
    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}

    def execute_write(connection, %Batch{} = batch, _opts) do
      send(self(), {:short_atomic_batch, batch})

      results =
        Enum.map(batch.commands, fn %Command{operation: operation} ->
          %Result{operation: operation, affected_rows: 1}
        end)

      case connection do
        :long -> {:ok, results ++ [%Result{operation: :insert, affected_rows: 1}]}
        _other -> {:ok, Enum.take(results, max(length(results) - 1, 0))}
      end
    end
  end

  defmodule NonListResultAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :non_list_result_batch_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false
    def write_capabilities(_connection), do: SelectoUpdato.MultiTest.full_write_capabilities()
    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}

    def execute_write(_connection, %Batch{} = batch, _opts) do
      send(self(), {:non_list_atomic_batch, batch})
      {:ok, %Result{operation: :batch, affected_rows: length(batch.commands)}}
    end
  end

  # Counts catalog reads (column_catalog/2) and records batches.
  defmodule CatalogAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :catalog_batch_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false
    def write_capabilities(_connection), do: SelectoUpdato.MultiTest.full_write_capabilities()
    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}

    def column_catalog(_connection, table) do
      send(self(), {:catalog_read, table})

      {:ok,
       %{
         "id" => %{type: "integer", deterministic: true},
         "name" => %{type: "text", deterministic: true}
       }}
    end

    def execute_write(_connection, %Batch{} = batch, _opts) do
      {:ok,
       Enum.map(batch.commands, fn %Command{operation: operation} ->
         %Result{operation: operation, affected_rows: 1}
       end)}
    end

    def execute_write(_connection, %Command{operation: operation}, _opts),
      do: {:ok, %Result{operation: operation, affected_rows: 1}}
  end

  test "one transaction reads each table's catalog once; the next transaction reads again" do
    guarded = Map.put(domain(), :required_filters, [{:name, "t1"}])
    selecto = %Selecto{adapter: CatalogAdapter, connection: :recording}

    multi =
      SelectoUpdato.multi()
      |> SelectoUpdato.multi_insert(:first, guarded, %{name: "t1"})
      |> SelectoUpdato.multi_insert(:second, guarded, %{name: "t1"})

    assert {:ok, %{first: _, second: _}} = SelectoUpdato.run(multi, selecto)
    assert_received {:catalog_read, "items"}
    refute_received {:catalog_read, _}

    # A new transaction never reuses the previous catalog (it may be stale
    # after DDL).
    assert {:ok, _} = SelectoUpdato.run(multi, selecto)
    assert_received {:catalog_read, "items"}
    refute_received {:catalog_read, _}

    for _ <- 1..2 do
      assert {:ok, _} =
               guarded
               |> SelectoUpdato.new()
               |> SelectoUpdato.insert(%{name: "t1"})
               |> SelectoUpdato.execute(selecto)

      assert_received {:catalog_read, "items"}
      refute_received {:catalog_read, _}
    end

    # The cache is keyed by table: two tables in one transaction read twice.
    other = put_in(guarded, [:source, :source_table], "other_items")

    two_tables =
      SelectoUpdato.multi()
      |> SelectoUpdato.multi_insert(:first, guarded, %{name: "t1"})
      |> SelectoUpdato.multi_insert(:second, other, %{name: "t1"})
      |> SelectoUpdato.multi_insert(:third, other, %{name: "t1"})

    assert {:ok, _} = SelectoUpdato.run(two_tables, selecto)
    assert_received {:catalog_read, "items"}
    assert_received {:catalog_read, "other_items"}
    refute_received {:catalog_read, _}

    # The verified catalog decides: 'T1' never satisfies name = 't1'.
    assert {:error, %SelectoUpdato.Error{details: %{code: :query_rule_violation}}} =
             SelectoUpdato.run(
               SelectoUpdato.multi() |> SelectoUpdato.multi_insert(:x, guarded, %{name: "T1"}),
               selecto
             )
  end

  test "public multi API delegates one ordered atomic batch and maps results by name" do
    multi =
      SelectoUpdato.multi()
      |> SelectoUpdato.multi_insert(:created, domain(), %{name: "new"})
      |> SelectoUpdato.multi_update(:renamed, domain(),
        filters: [{:id, 7}],
        changes: %{name: "updated"}
      )

    selecto = %Selecto{adapter: BatchAdapter, connection: :recording}

    assert {:ok,
            %{
              created: %Result{operation: :insert, affected_rows: 1},
              renamed: %Result{operation: :update, affected_rows: 1}
            }} = SelectoUpdato.run(multi, selecto, context: %{request_id: "request-1"})

    assert_receive {:atomic_batch, %Batch{atomic?: true, commands: commands}, opts}
    assert Enum.map(commands, & &1.operation) == [:insert, :update]
    assert Keyword.fetch!(opts, :context).request_id == "request-1"
  end

  test "compile failures stop the batch before adapter dispatch" do
    multi =
      SelectoUpdato.multi()
      |> SelectoUpdato.multi_insert(:invalid, domain(), %{
        :name => "new",
        "name" => "ambiguous"
      })

    selecto = %Selecto{adapter: BatchAdapter, connection: :recording}

    assert {:error, %{details: %{code: :duplicate_assignment_identifier}}} =
             SelectoUpdato.run(multi, selecto)

    refute_receive {:atomic_batch, _batch, _opts}
  end

  test "adapter failures propagate without partial name mapping" do
    multi = SelectoUpdato.multi_insert(SelectoUpdato.multi(), :created, domain(), %{name: "new"})
    selecto = %Selecto{adapter: FailingAdapter, connection: :recording}

    assert {:error,
            %SelectoUpdato.Error{type: :adapter_failure, message: "transaction rolled back"}} =
             SelectoUpdato.run(multi, selecto)
  end

  test "duplicate operation names fail before compile or adapter dispatch" do
    multi =
      SelectoUpdato.multi()
      |> SelectoUpdato.multi_insert(:item, domain(), %{name: "one"})
      |> SelectoUpdato.multi_insert(:item, domain(), %{name: "two"})

    selecto = %Selecto{adapter: BatchAdapter, connection: :recording}

    assert {:error,
            %SelectoUpdato.Error{
              type: :invalid_operation,
              details: %{code: :duplicate_batch_operation_name, names: [:item]}
            }} = SelectoUpdato.run(multi, selecto)

    refute_receive {:atomic_batch, _batch, _opts}
  end

  test "adapter result count must match operation names exactly" do
    multi =
      SelectoUpdato.multi()
      |> SelectoUpdato.multi_insert(:created, domain(), %{name: "new"})
      |> SelectoUpdato.multi_update(:renamed, domain(),
        filters: [{:id, 7}],
        changes: %{name: "updated"}
      )

    for {connection, actual_count} <- [short: 1, long: 3] do
      selecto = %Selecto{adapter: ShortResultAdapter, connection: connection}

      assert {:error,
              %SelectoUpdato.Error{
                type: :adapter_failure,
                details: %{
                  code: :batch_result_count_mismatch,
                  expected_result_count: 2,
                  actual_result_count: ^actual_count
                }
              }} = SelectoUpdato.run(multi, selecto)

      assert_receive {:short_atomic_batch, %Batch{atomic?: true}}
    end
  end

  test "a non-list batch result fails as an invalid result cardinality" do
    multi =
      SelectoUpdato.multi()
      |> SelectoUpdato.multi_insert(:created, domain(), %{name: "new"})
      |> SelectoUpdato.multi_update(:renamed, domain(),
        filters: [{:id, 7}],
        changes: %{name: "updated"}
      )

    selecto = %Selecto{adapter: NonListResultAdapter, connection: :recording}

    assert {:error,
            %SelectoUpdato.Error{
              type: :adapter_failure,
              details: %{
                code: :batch_result_count_mismatch,
                expected_result_count: 2,
                actual_result_count: :invalid
              }
            }} = SelectoUpdato.run(multi, selecto)

    assert_receive {:non_list_atomic_batch, %Batch{atomic?: true}}
  end

  defp domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name],
        columns: %{id: %{type: :integer}, name: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true, require_filter: true}
        },
        fields: %{name: %{insertable: true, updatable: true}}
      }
    }
  end
end
