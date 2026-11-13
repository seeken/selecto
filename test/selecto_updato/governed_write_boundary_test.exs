defmodule SelectoUpdato.GovernedWriteBoundaryTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{Authorization, Batch, Command, Error, Graph, Result}

  # A conforming adapter: the governed callbacks refuse a write without an
  # authorization for it, then record what the unsafe callbacks execute.
  defmodule ConformingAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    alias Selecto.Write.{Authorization, Batch, Command, Graph, Result}

    def name, do: :governed_boundary_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities({_pid, prepared?}) do
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
        write_graph: true,
        prepared_candidate_state: prepared?
      }
    end

    def preview_write(_connection, write, _opts),
      do: {:ok, %Selecto.Write.Preview{statements: [], metadata: %{write: write}}}

    def execute_write(connection, write, opts) do
      with :ok <- Authorization.require_for(write, opts) do
        execute_write_unsafe(connection, write, opts)
      end
    end

    def execute_write_unsafe({pid, _prepared?}, write, _opts) do
      send(pid, {:executed, write})
      {:ok, result(write)}
    end

    def execute_prepared_write({pid, true} = connection, prepare_fun, opts) do
      send(pid, :prepared_dispatch)

      execute_prepared_write_unsafe(
        connection,
        Authorization.governed_preparation(prepare_fun),
        opts
      )
    end

    def execute_prepared_write_unsafe({pid, _prepared?}, prepare_fun, _opts) do
      loader = fn request -> {:error, Selecto.Write.Error.new(:unexpected, inspect(request))} end

      with {:ok, write, _context} <- prepare_fun.(loader) do
        send(pid, {:executed, write})
        {:ok, result(write)}
      end
    end

    defp result(%Batch{commands: commands}),
      do: Enum.map(commands, &%Result{operation: &1.operation, affected_rows: 1})

    defp result(%Graph{}), do: %Result{operation: :graph, affected_rows: 1}

    defp result(%Command{operation: operation}),
      do: %Result{operation: operation, affected_rows: 1, rows: [%{"id" => 1}]}
  end

  setup do
    {:ok,
     selecto: %Selecto{adapter: ConformingAdapter, connection: {self(), false}},
     prepared_selecto: %Selecto{adapter: ConformingAdapter, connection: {self(), true}}}
  end

  describe "GW001: a domain without a writes section" do
    test "fails every operation with write_policy_missing", %{selecto: selecto} do
      domain = Map.delete(items_domain(), :writes)

      for operation <- [insert(domain), update(domain), delete(domain)] do
        assert {:error, %SelectoUpdato.Error{type: :write_policy_missing}} =
                 SelectoUpdato.execute(operation, selecto)

        assert {:error, %SelectoUpdato.Error{type: :write_policy_missing}} =
                 SelectoUpdato.preview(operation, selecto)
      end

      refute_received {:executed, _write}
    end
  end

  describe "GW002: writes.operations without writes.fields" do
    test "fails assignments with write_policy_missing and still deletes", %{selecto: selecto} do
      domain =
        items_domain()
        |> put_in([:writes, :operations, :upsert], %{enabled: true, conflict_targets: [[:id]]})
        |> update_in([:writes], &Map.delete(&1, :fields))

      for operation <- [insert(domain), update(domain), upsert(domain)] do
        assert {:error, %SelectoUpdato.Error{type: :write_policy_missing, details: details}} =
                 SelectoUpdato.execute(operation, selecto)

        assert details.required == [:writes, :fields]
      end

      refute_received {:executed, _write}

      assert {:ok, %Result{operation: :delete}} = SelectoUpdato.execute(delete(domain), selecto)
      assert_received {:executed, %Command{operation: :delete}}
    end

    test "an empty writes.fields registry declares no assignment grants", %{selecto: selecto} do
      domain = put_in(items_domain(), [:writes, :fields], %{})

      assert {:error, %SelectoUpdato.Error{type: :write_policy_missing}} =
               SelectoUpdato.execute(update(domain), selecto)
    end
  end

  describe "GW003: a full contract" do
    test "a governed update executes with an authorization for its command", %{
      selecto: selecto
    } do
      assert {:ok, %Result{operation: :update}} =
               SelectoUpdato.execute(update(items_domain()), selecto)

      assert_received {:executed, %Command{operation: :update}}
    end

    test "a governed prepared write executes inside the adapter's transaction", %{
      prepared_selecto: selecto
    } do
      operation =
        order_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.insert(%{reference: "SO-1", items: [%{sku: "WIDGET"}]})

      assert {:ok, %Result{operation: :graph}} = SelectoUpdato.execute(operation, selecto)
      assert_received :prepared_dispatch
      assert_received {:executed, %Graph{}}
    end

    test "a batch over one domain executes under one authorization", %{selecto: selecto} do
      multi =
        SelectoUpdato.multi()
        |> SelectoUpdato.multi_insert(:created, items_domain(), %{name: "new", tenant_id: 7})
        |> SelectoUpdato.multi_update(:renamed, items_domain(),
          filters: [{:id, 1}, {:tenant_id, 7}],
          changes: %{name: "renamed"}
        )

      assert {:ok, %{created: %Result{}, renamed: %Result{}}} = SelectoUpdato.run(multi, selecto)
      assert_received {:executed, %Batch{commands: [_insert, _update]}}
    end
  end

  describe "GW004: writes that bypass Updato" do
    test "a validated command sent straight to Selecto.Write is refused", %{selecto: selecto} do
      {:ok, command, _context} = SelectoUpdato.PortableCommand.compile(update(items_domain()))

      assert {:error, %Error{type: :ungoverned_write}} = Selecto.Write.execute(selecto, command)

      assert {:error, %Error{type: :ungoverned_write}} =
               ConformingAdapter.execute_write(selecto.connection, command, [])

      refute_received {:executed, _write}
    end

    test "batch and graph forms are refused", %{selecto: selecto} do
      {:ok, command, _context} = SelectoUpdato.PortableCommand.compile(update(items_domain()))
      {:ok, batch} = Batch.new([command])

      {:ok, graph, _context} =
        order_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.insert(%{reference: "SO-1", items: [%{sku: "WIDGET"}]})
        |> SelectoUpdato.PortableCommand.compile()

      for write <- [batch, graph] do
        assert {:error, %Error{type: :ungoverned_write}} = Selecto.Write.execute(selecto, write)

        assert {:error, %Error{type: :ungoverned_write}} =
                 ConformingAdapter.execute_write(selecto.connection, write, [])
      end

      refute_received {:executed, _write}
    end

    test "a raw prepared write is refused", %{prepared_selecto: selecto} do
      {:ok, command, _context} = SelectoUpdato.PortableCommand.compile(update(items_domain()))

      assert {:error, %Error{type: :ungoverned_write}} =
               Selecto.Write.execute_prepared(selecto, fn _loader -> {:ok, command, %{}} end)

      refute_received {:executed, _write}
    end

    test "callers cannot mint an authorization or replace Updato's", %{
      selecto: selecto,
      prepared_selecto: prepared_selecto
    } do
      assert {:error, %Error{type: :ungoverned_write}} = Authorization.issue(update_command())

      # A caller-supplied authorization never reaches the adapter: Updato
      # governs the write and issues its own.
      assert {:ok, %Result{operation: :update}} =
               SelectoUpdato.execute(update(items_domain()), selecto, authorization: :forged)

      assert_received {:executed, %Command{operation: :update}}

      assert {:ok, %Result{operation: :graph}} =
               order_domain()
               |> SelectoUpdato.new(tenant: %{tenant_id: 7})
               |> SelectoUpdato.insert(%{reference: "SO-1", items: [%{sku: "WIDGET"}]})
               |> SelectoUpdato.execute(prepared_selecto, authorization: :forged)

      assert_received {:executed, %Graph{}}
    end

    test "a planned write is data, not permission to execute", %{selecto: selecto} do
      {:ok, command} = SelectoUpdato.Executor.build_write_plan(update(items_domain()), selecto)

      assert {:error, %Error{type: :ungoverned_write}} = Selecto.Write.execute(selecto, command)
    end
  end

  describe "nested graphs" do
    test "an edge without allowed_ops has no write policy", %{prepared_selecto: selecto} do
      domain =
        update_in(
          order_domain(),
          [:writes, :relationships, :items],
          &Map.delete(&1, :allowed_ops)
        )

      assert {:error, %SelectoUpdato.Error{type: :write_policy_missing}} =
               domain
               |> SelectoUpdato.new(tenant: %{tenant_id: 7})
               |> SelectoUpdato.insert(%{reference: "SO-1", items: [%{sku: "WIDGET"}]})
               |> SelectoUpdato.execute(selecto)

      refute_received {:executed, _write}
    end

    test "an edge without a child domain has no write policy", %{prepared_selecto: selecto} do
      domain =
        update_in(order_domain(), [:writes, :relationships, :items], &Map.delete(&1, :domain))

      assert {:error, %SelectoUpdato.Error{type: :write_policy_missing}} =
               domain
               |> SelectoUpdato.new(tenant: %{tenant_id: 7})
               |> SelectoUpdato.insert(%{reference: "SO-1", items: [%{sku: "WIDGET"}]})
               |> SelectoUpdato.execute(selecto)
    end

    test "a child domain without writes.operations or writes.fields has no write policy", %{
      prepared_selecto: selecto
    } do
      for strip <- [
            &Map.delete(&1, :writes),
            &update_in(&1, [:writes], fn w -> Map.delete(w, :fields) end)
          ] do
        domain =
          update_in(order_domain(), [:writes, :relationships, :items, :domain], strip)

        assert {:error, %SelectoUpdato.Error{type: :write_policy_missing}} =
                 domain
                 |> SelectoUpdato.new(tenant: %{tenant_id: 7})
                 |> SelectoUpdato.insert(%{reference: "SO-1", items: [%{sku: "WIDGET"}]})
                 |> SelectoUpdato.execute(selecto)
      end

      refute_received {:executed, _write}
    end
  end

  test "a batch across domains executes under one authorization, each command governed", %{
    selecto: selecto
  } do
    other = put_in(items_domain(), [:source, :source_table], "archived_items")
    no_fields = update_in(other, [:writes], &Map.delete(&1, :fields))

    multi =
      SelectoUpdato.multi()
      |> SelectoUpdato.multi_insert(:created, items_domain(), %{name: "new", tenant_id: 7})
      |> SelectoUpdato.multi_insert(:archived, other, %{name: "old", tenant_id: 7})

    assert {:ok, %{created: %Result{}, archived: %Result{}}} = SelectoUpdato.run(multi, selecto)
    assert_received {:executed, %Batch{commands: [_created, _archived]}}

    # Every command is still governed by its own domain's contract.
    ungoverned =
      SelectoUpdato.multi()
      |> SelectoUpdato.multi_insert(:created, items_domain(), %{name: "new", tenant_id: 7})
      |> SelectoUpdato.multi_insert(:archived, no_fields, %{name: "old", tenant_id: 7})

    assert {:error, %SelectoUpdato.Error{type: :write_policy_missing}} =
             SelectoUpdato.run(ungoverned, selecto)

    refute_received {:executed, _write}
  end

  defp insert(domain),
    do: domain |> SelectoUpdato.new() |> SelectoUpdato.insert(%{name: "new", tenant_id: 7})

  defp update(domain) do
    domain
    |> SelectoUpdato.new()
    |> SelectoUpdato.filters([{:id, 1}, {:tenant_id, 7}])
    |> SelectoUpdato.update(%{name: "renamed"})
  end

  defp upsert(domain) do
    domain
    |> SelectoUpdato.new()
    |> SelectoUpdato.upsert(%{id: 1, name: "renamed", tenant_id: 7})
    |> SelectoUpdato.conflict_target([:id])
  end

  defp delete(domain) do
    domain
    |> SelectoUpdato.new()
    |> SelectoUpdato.filters([{:id, 2}, {:tenant_id, 7}])
    |> SelectoUpdato.delete()
  end

  defp update_command do
    {:ok, command} =
      Command.new(%{
        operation: :update,
        relation: "items",
        assignments: [%{field: "name", value: {:literal, "x"}}],
        predicate: {:eq, {:field, "id"}, {:literal, 1}}
      })

    command
  end

  defp items_domain do
    %{
      name: "items",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :tenant_id, :name],
        columns: %{id: %{type: :integer}, tenant_id: %{type: :integer}, name: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true, require_filter: true},
          delete: %{enabled: true, require_filter: true}
        },
        fields: %{
          tenant_id: %{insertable: true, immutable: true},
          name: %{insertable: true, updatable: true}
        }
      }
    }
  end

  defp order_domain do
    items =
      nested_domain("order_items", [:id, :tenant_id, :order_id, :sku], %{
        sku: %{insertable: true, updatable: true}
      })

    nested_domain("orders", [:id, :tenant_id, :reference], %{
      reference: %{insertable: true, updatable: true}
    })
    |> put_in([:writes, :relationships], %{
      items: %{
        writable: true,
        cardinality: :many,
        ownership: :owned,
        allowed_ops: [:insert, :update, :delete],
        domain: items,
        child_key: :order_id,
        parent_key: :id,
        strategy: :sync,
        identity_fields: [:id],
        delete_missing: true
      }
    })
  end

  defp nested_domain(relation, fields, write_fields) do
    %{
      name: relation,
      source: %{
        source_table: relation,
        primary_key: :id,
        fields: fields,
        columns: Map.new(fields, &{&1, %{type: :string}}),
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true, expected_cardinality: {:exactly, 1}},
          update: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}}
        },
        fields: Map.merge(%{tenant_id: %{insertable: true, immutable: true}}, write_fields),
        scope: %{tenant: %{required: true, field: :tenant_id}},
        relationships: %{}
      }
    }
  end
end
