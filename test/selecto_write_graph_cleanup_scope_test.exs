defmodule Selecto.Write.GraphCleanupScopeTest do
  # w3exrev17 HIGH 1: a node compiled under a bound scope hands
  # `bound_scope` on to its delete-missing cleanup command, so the adapter
  # applies the bound-scope delete contract to it.
  use ExUnit.Case, async: true

  alias Selecto.Write.{Command, Result}
  alias Selecto.Write.Graph.{Materializer, Node, Row}

  defp sync_node(metadata) do
    {:ok, command} =
      Command.new(%{
        operation: :update,
        relation: "items",
        predicate: {:eq, {:field, "id"}, {:literal, 60}},
        assignments: [%{field: "sku", value: {:literal, "W"}}],
        expected_cardinality: {:exactly, 1}
      })

    %Node{
      id: "items",
      path: [:items],
      relation: "items",
      strategy: :sync,
      rows: [%Row{id: "0", path: [:items, 0], command: command}],
      identity_fields: [:id],
      sync_predicate: {:eq, {:field, :order_id}, {:literal, 50}},
      delete_missing?: true,
      metadata: metadata
    }
  end

  @results %{"0" => %Result{operation: :update, affected_rows: 1, rows: [%{"id" => 60}]}}

  test "a bound node's cleanup is a bound-scope delete" do
    assert {:ok, %Command{operation: :delete, metadata: metadata}} =
             Materializer.delete_missing_command(sync_node(%{bound_scope: true}), @results)

    assert metadata.bound_scope == true
    assert metadata.graph_cleanup == true
  end

  test "an unbound node's cleanup carries no bound_scope" do
    assert {:ok, %Command{metadata: metadata}} =
             Materializer.delete_missing_command(sync_node(%{relationship: "items"}), @results)

    refute Map.has_key?(metadata, :bound_scope)
  end
end
