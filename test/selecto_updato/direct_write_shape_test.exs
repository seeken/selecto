defmodule SelectoUpdato.DirectWriteShapeTest do
  use ExUnit.Case, async: true
  alias SelectoUpdato.{DirectWrite, Mutation}

  test "struct domains and graph nodes return typed errors before adapter access" do
    target = %Selecto{adapter: __MODULE__.UnreachableAdapter, connection: self()}
    child = %{source: %{columns: %{label: %{type: :string}}}, writes: %{relationships: %{}}}

    domain = %{
      source: %{columns: %{label: %{type: :string}}},
      writes: %{relationships: %{children: %{domain: child}}}
    }

    for malformed <- [Decimal.new("1.5"), %Selecto{}, Mutation.literal("value")] do
      assert {:error, %{type: :invalid_write}} = DirectWrite.import_domain(malformed)
      assert {:error, %{type: :invalid_write}} = DirectWrite.execute_graph(malformed, target, %{})

      assert {:error, %{type: :invalid_write}} =
               DirectWrite.execute_graph(domain, target, malformed)

      assert {:error, %{type: :invalid_write}} =
               DirectWrite.execute_graph(domain, target, %{children: [malformed]})

      malformed_domain = put_in(domain, [:writes, :relationships, :children, :domain], malformed)

      assert {:error, %{type: :invalid_write}} =
               DirectWrite.execute_graph(malformed_domain, target, %{children: [%{}]})
    end
  end

  defmodule GraphAdapter do
    def name, do: :graph_recording

    def write_capabilities(_connection),
      do: %{
        protocol_version: 1,
        insert: true,
        transactions: true,
        atomic_batch: true,
        write_graph: true,
        returning: true,
        generated_keys: :returning,
        prepared_candidate_state: true,
        graph_domain_inference: true,
        native_rule_candidates: true
      }

    def execute_prepared_write(pid, checked, _opts) do
      loader = fn
        {:write_graph_domain, domain} -> {:ok, %{domain: domain, edges: [%{child: :items}]}}
        _request -> {:ok, []}
      end

      case checked.(loader) do
        {:ok, graph, _context, _authorization} ->
          send(pid, {:graph, graph})
          {:ok, %{}}

        other ->
          other
      end
    end
  end

  test "a creation graph is bounded by the target's engine tenant (lesson 47)" do
    item = %{
      source: %{
        source_table: "items",
        primary_key: :id,
        tenant_field: :tenant_id,
        fields: [:id, :tenant_id, :order_id, :sku],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          order_id: %{type: :integer},
          sku: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: %{sku: %{insertable: true}, tenant_id: %{insertable: true}}
      }
    }

    domain = %{
      source: %{
        source_table: "orders",
        primary_key: :id,
        tenant_field: :tenant_id,
        fields: [:id, :tenant_id, :reference],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          reference: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: %{reference: %{insertable: true}, tenant_id: %{insertable: true}},
        relationships: %{
          items: %{
            writable: true,
            cardinality: :many,
            ownership: :owned,
            allowed_ops: [:insert],
            domain: item,
            child_key: :order_id,
            parent_key: :id,
            strategy: :sync,
            identity_fields: [:id],
            delete_missing: true
          }
        }
      }
    }

    target = %Selecto{
      adapter: GraphAdapter,
      connection: self(),
      tenant: Selecto.Tenant.normalize_context(%{tenant_id: 7})
    }

    result =
      DirectWrite.execute_graph(domain, target, %{reference: "SO-1", items: [%{sku: "W"}]})

    assert {:ok, _} = result
    assert_receive {:graph, %Selecto.Write.Graph{nodes: nodes}}

    for node <- nodes, row <- node.rows do
      assert %{field: "tenant_id", value: {:literal, 7}} in row.command.assignments
    end

    assert {:error, %{type: :tenant_mismatch}} =
             DirectWrite.execute_graph(domain, target, %{
               reference: "SO-1",
               tenant_id: 8,
               items: [%{sku: "W"}]
             })
  end

  test "flat assignment containers reject structs and malformed or ambiguous keys" do
    for assignments <- [
          Decimal.new("1.5"),
          %{{} => "invalid"},
          %{%{} => "invalid"},
          %{"name" => "first", name: "contradiction"}
        ] do
      assert {:error, %{type: :invalid_write}} =
               DirectWrite.build(%{}, Map.put(command(), "assignments", assignments))
    end
  end

  test "bounded structural containers refuse before domain or adapter conversion" do
    for {submitted, opts} <- [
          {Decimal.new("1.5"), []},
          {Map.put(command(), {}, "invalid"), []},
          {Map.put(command(), %{}, "invalid"), []},
          {Map.put(command(), "predicate", Decimal.new("1.5")), []},
          {Map.put(command(), "predicate", %{{} => 1}), []},
          {Map.put(command(), "returning", Decimal.new("1.5")), []},
          {Map.put(command(), "returning", [Decimal.new("1.5")]), []},
          {Map.put(command(), "conflict_target", Decimal.new("1.5")), []},
          {Map.put(command(), "conflict_target", [%{}]), []},
          {Map.put(command(), "upsert_update_fields", %{}), []},
          {command(), Decimal.new("1.5")},
          {command(), %{}},
          {command(), [{"query", nil}]},
          {command(), [query: Decimal.new("1.5")]},
          {command(), [query: %Selecto{}]}
        ] do
      assert {:error, %{type: :invalid_write}} = DirectWrite.build(%{}, submitted, opts)
    end
  end

  defp command do
    %{
      "operation" => "update",
      "relation" => "root",
      "assignments" => %{"name" => "safe"},
      "predicate" => %{"field" => "id", "op" => "eq", "value" => 1},
      "returning" => []
    }
  end
end
