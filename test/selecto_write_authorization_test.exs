defmodule Selecto.WriteAuthorizationTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.WriteContract
  alias Selecto.Write
  alias Selecto.Write.{Authorization, Batch, Command, Error, Preview, Result}
  alias SelectoUpdato.GovernedWrite

  # A conforming adapter: the governed callbacks require an authorization and
  # delegate to the unsafe ones, which record every write they execute.
  defmodule ConformingAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    alias Selecto.Write.{Authorization, Batch, Command, Preview, Result}

    def name, do: :conforming_write_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_pid) do
      %{
        protocol_version: 1,
        insert: true,
        update: true,
        upsert: true,
        delete: true,
        atomic_batch: true,
        transactions: true,
        prepared_candidate_state: true
      }
    end

    def preview_write(_pid, _write, _opts), do: {:ok, %Preview{statements: []}}

    def execute_write(pid, write, opts) do
      with :ok <- Authorization.require_for(write, opts) do
        execute_write_unsafe(pid, write, opts)
      end
    end

    def execute_write_unsafe(pid, write, _opts) do
      send(pid, {:executed, write})
      {:ok, result(write)}
    end

    def execute_prepared_write(pid, prepare_fun, opts) when is_function(prepare_fun, 1) do
      execute_prepared_write_unsafe(pid, Authorization.governed_preparation(prepare_fun), opts)
    end

    def execute_prepared_write_unsafe(pid, prepare_fun, _opts) do
      with {:ok, write, _context} <- prepare_fun.(fn _request -> {:error, :unused} end) do
        send(pid, {:executed, write})
        {:ok, result(write)}
      end
    end

    defp result(%Batch{commands: commands}),
      do: Enum.map(commands, &%Result{operation: &1.operation, affected_rows: 1})

    defp result(%Command{operation: operation}),
      do: %Result{operation: operation, affected_rows: 1}
  end

  # An adapter written before the boundary existed: it never checks.
  defmodule LegacyAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    alias Selecto.Write.{Preview, Result}

    def name, do: :legacy_write_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_pid),
      do: %{protocol_version: 1, insert: true, update: true, prepared_candidate_state: true}

    def preview_write(_pid, _write, _opts), do: {:ok, %Preview{statements: []}}

    def execute_write(pid, write, _opts) do
      send(pid, {:executed, write})
      {:ok, %Result{operation: write.operation, affected_rows: 1}}
    end

    def execute_prepared_write(pid, prepare_fun, _opts) do
      with {:ok, write, _context} <- prepare_fun.(fn _request -> {:error, :unused} end) do
        send(pid, {:executed, write})
        {:ok, %Result{operation: write.operation, affected_rows: 1}}
      end
    end
  end

  # Any module other than the governed entry point.
  defmodule Impostor do
    def issue(write) do
      case Authorization.issue(write) do
        result -> result
      end
    end
  end

  setup do
    {:ok, selecto: %Selecto{adapter: ConformingAdapter, connection: self()}}
  end

  describe "the governed path" do
    test "executes a write the governed entry point authorized", %{selecto: selecto} do
      command = command!(:insert)

      assert {:ok, %Result{operation: :insert}} = GovernedWrite.execute(selecto, command)
      assert_received {:executed, ^command}
    end

    test "executes a batch under one authorization", %{selecto: selecto} do
      {:ok, batch} = Batch.new([command!(:insert), command!(:update)])

      assert {:ok, [%Result{operation: :insert}, %Result{operation: :update}]} =
               GovernedWrite.execute(selecto, batch)

      assert_received {:executed, ^batch}
    end

    test "executes a governed prepared write", %{selecto: selecto} do
      command = command!(:update)

      assert {:ok, %Result{operation: :update}} =
               Write.execute_prepared(selecto, fn _loader ->
                 GovernedWrite.prepared(command, %{})
               end)

      assert_received {:executed, ^command}
    end
  end

  describe "raw writes" do
    test "Selecto.Write.execute/3 refuses a command without an authorization", %{
      selecto: selecto
    } do
      assert {:error, %Error{type: :ungoverned_write}} = Write.execute(selecto, command!(:insert))

      {:ok, batch} = Batch.new([command!(:insert)])
      assert {:error, %Error{type: :ungoverned_write}} = Write.execute(selecto, batch)

      refute_received {:executed, _write}
    end

    test "an adapter refuses a direct call without an authorization" do
      command = command!(:delete)

      assert {:error, %Error{type: :ungoverned_write}} =
               ConformingAdapter.execute_write(self(), command, [])

      assert {:error, %Error{type: :ungoverned_write}} =
               ConformingAdapter.execute_prepared_write(
                 self(),
                 fn _loader -> {:ok, command, %{}} end,
                 []
               )

      refute_received {:executed, _write}
    end

    test "a prepared write without an authorization is refused", %{selecto: selecto} do
      assert {:error, %Error{type: :ungoverned_write}} =
               Write.execute_prepared(selecto, fn _loader -> {:ok, command!(:update), %{}} end)

      refute_received {:executed, _write}
    end

    test "core refuses before dispatch even when the adapter never checks" do
      selecto = %Selecto{adapter: LegacyAdapter, connection: self()}

      assert {:error, %Error{type: :ungoverned_write}} = Write.execute(selecto, command!(:insert))

      assert {:error, %Error{type: :ungoverned_write}} =
               Write.execute_prepared(selecto, fn _loader -> {:ok, command!(:update), %{}} end)

      refute_received {:executed, _write}
    end

    test "the unsafe primitives run a raw write for trusted tooling", %{selecto: selecto} do
      command = command!(:insert)

      assert {:ok, %Result{operation: :insert}} = Write.execute_unsafe(selecto, command)
      assert_received {:executed, ^command}

      assert {:ok, %Result{operation: :update}} =
               Write.execute_prepared_unsafe(selecto, fn _loader ->
                 {:ok, command!(:update), %{}}
               end)

      assert_received {:executed, %Command{operation: :update}}
    end

    test "unsafe execution still runs the shared preflight checks", %{selecto: selecto} do
      assert {:error, %Error{type: :invalid_command}} =
               Write.execute_unsafe(selecto, :not_a_write)

      selecto = %Selecto{adapter: LegacyAdapter, connection: self()}

      assert {:error, %Error{type: :write_not_supported}} =
               Write.execute_unsafe(selecto, command!(:insert))
    end
  end

  describe "authorizations" do
    test "only the governed entry point can issue one" do
      assert {:error, %Error{type: :ungoverned_write}} = Impostor.issue(command!(:insert))
      assert {:error, %Error{type: :ungoverned_write}} = Authorization.issue(command!(:insert))
    end

    test "cover only portable write values" do
      assert {:error, %Error{type: :invalid_command}} = GovernedWrite.authorize(%{op: :insert})
    end

    test "a lookalike authorizes nothing", %{selecto: selecto} do
      command = command!(:insert)
      {:ok, _real} = GovernedWrite.authorize(command)
      forged = struct!(Authorization, ref: make_ref())

      assert {:error, %Error{type: :ungoverned_write}} =
               Write.execute(selecto, command, authorization: forged)

      assert {:error, %Error{type: :ungoverned_write}} =
               ConformingAdapter.execute_write(self(), command, authorization: forged)

      refute_received {:executed, _write}
    end

    test "are single-use", %{selecto: selecto} do
      command = command!(:insert)
      {:ok, authorization} = GovernedWrite.authorize(command)

      assert {:ok, %Result{}} = Write.execute(selecto, command, authorization: authorization)
      assert_received {:executed, ^command}

      assert {:error, %Error{type: :ungoverned_write}} =
               Write.execute(selecto, command, authorization: authorization)

      assert {:error, %Error{type: :ungoverned_write}} =
               ConformingAdapter.execute_write(self(), command, authorization: authorization)

      refute_received {:executed, _write}
    end

    test "are spent by dispatch even when the adapter never consumes them" do
      selecto = %Selecto{adapter: LegacyAdapter, connection: self()}
      command = command!(:insert)
      {:ok, authorization} = GovernedWrite.authorize(command)

      assert {:ok, %Result{}} = Write.execute(selecto, command, authorization: authorization)
      assert_received {:executed, ^command}

      assert {:error, %Error{type: :ungoverned_write}} =
               Write.execute(selecto, command, authorization: authorization)
    end

    test "are spent by a refused dispatch", %{selecto: selecto} do
      command = %{command!(:insert) | returning: [:id]}
      selecto = %{selecto | adapter: LegacyAdapter}
      {:ok, authorization} = GovernedWrite.authorize(command)

      assert {:error, %Error{type: :write_capability_missing}} =
               Write.execute(selecto, command, authorization: authorization)

      assert {:error, %Error{type: :ungoverned_write}} =
               Authorization.check(command, authorization)
    end

    test "are bound to the exact payload", %{selecto: selecto} do
      command = command!(:update)
      {:ok, authorization} = GovernedWrite.authorize(command)

      altered = %{command | predicate: {:eq, {:field, :tenant_id}, {:literal, 8}}}

      assert {:error, %Error{type: :ungoverned_write}} =
               Write.execute(selecto, altered, authorization: authorization)

      refute_received {:executed, _write}

      {:ok, authorization} = GovernedWrite.authorize(command)
      retargeted = %{command | relation: :other_items}

      assert {:error, %Error{type: :ungoverned_write}} =
               ConformingAdapter.execute_write(self(), retargeted, authorization: authorization)

      refute_received {:executed, _write}
    end

    test "for a batch do not cover the batch's commands one by one", %{selecto: selecto} do
      insert = command!(:insert)
      {:ok, batch} = Batch.new([insert, command!(:update)])
      {:ok, authorization} = GovernedWrite.authorize(batch)

      assert {:error, %Error{type: :ungoverned_write}} =
               Write.execute(selecto, insert, authorization: authorization)

      {:ok, authorization} = GovernedWrite.authorize(insert)
      {:ok, superset} = Batch.new([insert, command!(:delete)])

      assert {:error, %Error{type: :ungoverned_write}} =
               Write.execute(selecto, superset, authorization: authorization)

      refute_received {:executed, _write}
    end

    test "for a prepared write are bound to the prepared payload", %{selecto: selecto} do
      command = command!(:update)

      assert {:error, %Error{type: :ungoverned_write}} =
               Write.execute_prepared(selecto, fn _loader ->
                 {:ok, write, context, authorization} = GovernedWrite.prepared(command, %{})
                 {:ok, %{write | relation: :other_items}, context, authorization}
               end)

      refute_received {:executed, _write}
    end

    test "are valid only in the process that issued them", %{selecto: selecto} do
      command = command!(:insert)
      {:ok, authorization} = GovernedWrite.authorize(command)

      result =
        Task.async(fn -> Write.execute(selecto, command, authorization: authorization) end)
        |> Task.await()

      assert {:error, %Error{type: :ungoverned_write}} = result
      assert :ok = Authorization.check(command, authorization)
    end

    test "can be revoked before use", %{selecto: selecto} do
      command = command!(:insert)
      {:ok, authorization} = GovernedWrite.authorize(command)

      assert :ok = Authorization.revoke(authorization)

      assert {:error, %Error{type: :ungoverned_write}} =
               Write.execute(selecto, command, authorization: authorization)
    end

    test "do not reveal their registry entry when inspected" do
      {:ok, authorization} = GovernedWrite.authorize(command!(:insert))

      assert inspect(authorization) == "#Selecto.Write.Authorization<...>"
    end
  end

  describe "write policy" do
    test "a domain without writes.operations has no write policy" do
      assert {:error, %Error{type: :write_policy_missing}} = WriteContract.compile(domain(nil))

      assert {:error, %Error{type: :write_policy_missing}} =
               WriteContract.compile(domain(%{fields: %{name: %{insertable: true}}}))

      assert {:error, %Error{type: :write_policy_missing}} =
               WriteContract.compile(domain(%{operations: %{}}))
    end

    test "a domain without writes.fields permits deletes only" do
      writes = %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true},
          upsert: %{enabled: true},
          delete: %{enabled: true}
        }
      }

      assert {:ok, contract} = WriteContract.compile(domain(writes))
      refute contract.fields_declared?
      assert :ok = WriteContract.require_write_policy(contract, :delete)

      for operation <- [:insert, :update, :upsert] do
        assert {:error, %Error{type: :write_policy_missing, details: details}} =
                 WriteContract.require_write_policy(contract, operation)

        assert details.required == [:writes, :fields]
      end

      empty_fields = Map.put(writes, :fields, %{})
      assert {:ok, contract} = WriteContract.compile(domain(empty_fields))

      assert {:error, %Error{type: :write_policy_missing}} =
               WriteContract.require_write_policy(contract, :insert)
    end

    test "a declared contract satisfies the policy for every enabled operation" do
      writes = %{
        operations: %{insert: %{enabled: true}, delete: %{enabled: false}},
        fields: %{name: %{insertable: true}}
      }

      assert {:ok, contract} = WriteContract.compile(domain(writes))
      assert contract.fields_declared?
      assert :ok = WriteContract.require_write_policy(contract, :insert)
      refute WriteContract.operation_enabled?(contract, :delete)
    end

    test "a registry that enables nothing compiles but executes nothing" do
      writes = %{operations: %{insert: %{enabled: false}}, fields: %{name: %{insertable: true}}}

      assert {:ok, contract} = WriteContract.compile(domain(writes))
      refute WriteContract.operation_enabled?(contract, :insert)
    end
  end

  test "a preview needs no authorization because it never executes", %{selecto: selecto} do
    assert {:ok, %Preview{}} = Write.preview(selecto, command!(:insert))
    refute_received {:executed, _write}
  end

  defp command!(operation) do
    attrs =
      case operation do
        :insert ->
          %{assignments: [%{field: :name, value: {:literal, "new"}}]}

        :update ->
          %{
            assignments: [%{field: :name, value: {:literal, "renamed"}}],
            predicate: {:eq, {:field, :tenant_id}, {:literal, 7}}
          }

        :delete ->
          %{predicate: {:eq, {:field, :tenant_id}, {:literal, 7}}}
      end

    {:ok, command} = Command.new(Map.merge(%{operation: operation, relation: :items}, attrs))
    command
  end

  defp domain(writes) do
    base = %{
      name: "Items",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :tenant_id, :name],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          name: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{}
    }

    if writes, do: Map.put(base, :writes, writes), else: base
  end
end
