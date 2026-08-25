defmodule Selecto.Write.GraphOutcomeTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{Command, Graph, Result}
  alias Selecto.Write.Graph.{Materializer, Node, Row}

  test "portable graph outcomes preserve stable paths and client-to-server identities" do
    root_command = command(:update, "orders", ["id"])
    child_command = command(:insert, "order_items", ["id"])

    root = %Node{
      id: "root",
      path: [],
      relation: "orders",
      strategy: :ordered,
      rows: [%Row{id: "root", path: [], command: root_command}]
    }

    items = %Node{
      id: "items",
      path: ["items"],
      relation: "order_items",
      strategy: :ordered,
      identity_fields: ["id"],
      rows: [
        %Row{
          id: "create:client_id=new-1",
          path: ["items", "client_id=new-1"],
          command: child_command,
          metadata: %{client_identity: "new-1", semantic_operation: :create}
        }
      ],
      metadata: %{identity_mapping?: true}
    }

    assert {:ok, graph} = Graph.new([root, items], {"root", "root"})

    results = %{
      {"root", "root"} => %Result{operation: :update, affected_rows: 1, rows: [%{"id" => 42}]},
      {"items", "create:client_id=new-1"} => %Result{
        operation: :insert,
        affected_rows: 1,
        rows: [%{"id" => 101}]
      }
    }

    assert %{
             identity_mappings: [
               %{
                 path: ["items", "client_id=new-1"],
                 client_identity: "new-1",
                 identity: %{"id" => 101}
               }
             ],
             nested_outcomes: [
               %{
                 path: ["items", "client_id=new-1"],
                 operation: :create,
                 affected_rows: 1,
                 identity: %{"id" => 101}
               }
             ]
           } = Materializer.outcome_metadata(graph, results)
  end

  defp command(operation, relation, returning) do
    %Command{
      operation: operation,
      relation: relation,
      assignments: [%{field: "status", value: {:literal, "ok"}}],
      predicate: if(operation == :update, do: {:eq, {:field, "id"}, {:literal, 42}}),
      returning: returning
    }
  end
end
