defmodule Selecto.WriteProtocolTest do
  use ExUnit.Case, async: true

  alias Selecto.Write
  alias Selecto.Write.{Batch, Command, Error, Preview, Result}
  alias Selecto.Domain.WriteContract

  defmodule WriteAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :write_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_connection), do: %{insert: true, update: true, atomic_batch: true}

    def preview_write(_connection, command, _opts) do
      {:ok, %Preview{statements: [%{text: "adapter-owned preview", params: [command]}]}}
    end

    def execute_write(_connection, command, _opts) do
      {:ok, %Result{operation: operation(command), affected_rows: 1, rows: [%{id: 1}]}}
    end

    defp operation(%Command{operation: operation}), do: operation
    defp operation(%Batch{commands: [%Command{operation: operation} | _]}), do: operation
  end

  defmodule ReadOnlyAdapter do
    @behaviour Selecto.DB.Adapter

    def name, do: :read_only
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false
  end

  test "dispatches a validated portable command to the configured write adapter" do
    command = command!(:insert)
    selecto = %Selecto{adapter: WriteAdapter, connection: :connection}

    assert {:ok, %Result{operation: :insert, affected_rows: 1}} = Write.execute(selecto, command)

    assert {:ok, %Preview{statements: [%{text: "adapter-owned preview"}]}} =
             Write.preview(selecto, command)

    assert {:ok, %{atomic_batch: true}} = Write.capabilities(selecto)
  end

  test "rejects raw SQL from a portable command" do
    assert {:error, %Error{type: :invalid_command}} =
             Command.new(%{
               operation: :update,
               relation: :items,
               predicate: {:unsafe_sql, "id = 1"}
             })

    assert {:error, %Error{type: :invalid_command}} =
             Command.new(%{
               operation: :upsert,
               relation: :items,
               metadata: %{conflict_target: {:unsafe_sql, "id"}}
             })
  end

  test "requires atomic batches" do
    command = command!(:update)

    assert {:ok, %Batch{atomic?: true}} = Batch.new([command])
    assert {:error, %Error{type: :invalid_command}} = Batch.new([command], atomic?: false)
  end

  test "fails before execution when the configured adapter has no write behavior" do
    selecto = %Selecto{adapter: ReadOnlyAdapter, connection: :connection}

    assert {:error, %Error{type: :write_not_supported}} =
             Write.execute(selecto, command!(:delete))
  end

  test "compiles only an explicit write surface and never treats a read domain as writable" do
    assert {:error, %Error{type: :write_not_declared}} = WriteContract.compile(read_domain())

    assert {:ok, contract} = WriteContract.compile(write_domain())
    assert WriteContract.operation_enabled?(contract, :insert)
    assert WriteContract.operation_enabled?(contract, :update)
    refute WriteContract.operation_enabled?(contract, :delete)
    assert WriteContract.writable?(contract, :insert, :name)
    refute WriteContract.writable?(contract, :update, :tenant_id)
    assert contract.scope.tenant.field == :tenant_id
  end

  test "permits a write domain without tenant policy but compiles tenant policy fail-closed when present" do
    tenantless_domain = update_in(write_domain(), [:writes], &Map.delete(&1, :scope))

    assert {:ok, %{scope: %{}}} = WriteContract.compile(tenantless_domain)

    invalid_tenant_domain = put_in(write_domain(), [:writes, :scope, :tenant, :required], false)

    assert {:error, %Error{type: :invalid_domain}} = WriteContract.compile(invalid_tenant_domain)
  end

  test "rejects unknown write fields before a command reaches an adapter" do
    invalid_domain =
      put_in(write_domain(), [:writes, :fields, :missing_field], %{insertable: true})

    assert {:error, %Error{type: :invalid_domain}} = WriteContract.compile(invalid_domain)
  end

  test "requires foreign-key value sources and referenced targets to be authored explicitly" do
    domain =
      write_domain()
      |> put_in([:source, :fields], [:id, :name, :tenant_id, :account_id])
      |> put_in([:source, :columns, :account_id], %{type: :integer})
      |> put_in([:writes, :fields, :account_id], %{insertable: true})
      |> put_in([:writes, :constraints], %{})
      |> put_in([:writes, :constraints, :foreign_keys], %{})

    invalid = put_in(domain, [:writes, :constraints, :foreign_keys, :account_id], %{})

    assert {:error, %Error{type: :invalid_domain}} = WriteContract.compile(invalid)

    valid =
      put_in(domain, [:writes, :constraints, :foreign_keys, :account_id], %{
        source: {:context, :account_id},
        references: %{relation: "accounts", field: :id},
        required: true
      })

    assert {:ok, contract} = WriteContract.compile(valid)

    assert contract
           |> WriteContract.foreign_keys()
           |> Map.fetch!("account_id")
           |> Map.fetch!(:source) == {:context, :account_id}
  end

  defp command!(operation) do
    {:ok, command} =
      Command.new(%{
        operation: operation,
        relation: :items,
        assignments:
          if(operation == :delete, do: [], else: [%{field: :name, value: {:literal, "item"}}]),
        predicate: {:eq, {:field, :tenant_id}, {:context, :tenant_id}},
        required_capabilities: [operation]
      })

    command
  end

  defp read_domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name, :tenant_id],
        columns: %{id: %{type: :integer}, name: %{type: :string}, tenant_id: %{type: :integer}},
        associations: %{}
      },
      schemas: %{}
    }
  end

  defp write_domain do
    Map.put(read_domain(), :writes, %{
      operations: %{insert: %{enabled: true}, update: %{enabled: true, require_filter: true}},
      fields: %{
        name: %{insertable: true, updatable: true},
        tenant_id: %{insertable: false, updatable: false, immutable: true}
      },
      scope: %{tenant: %{required: true, field: :tenant_id}}
    })
  end
end
