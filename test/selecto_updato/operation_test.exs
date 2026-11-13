defmodule SelectoUpdato.OperationTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.Operation

  test "copies filters only from a Selecto query" do
    selecto = %Selecto{
      domain: %{required_filters: [{"tenant_id", 7}]},
      set: %{
        filtered: [{"active", true}],
        post_retarget_filters: [{"region", "west"}]
      }
    }

    operation = Operation.new(%{}) |> Operation.filter_from_selecto(selecto)

    assert operation.filters == [
             {"tenant_id", 7},
             {"active", true},
             {"region", "west"}
           ]
  end

  test "rejects legacy map-shaped query state" do
    operation = Operation.new(%{})

    assert_raise FunctionClauseError, fn ->
      apply(Operation, :filter_from_selecto, [operation, %{filters: [{"id", 1}]}])
    end
  end

  test "captures query enforcement without retaining runtime connection state" do
    selecto = %Selecto{
      connection: self(),
      domain: %{
        name: "Items",
        source: %{source_table: "items", primary_key: :id},
        domain_fingerprint: "sha256:items"
      },
      set: %{filtered: [{"status", "active"}], required_filters: []}
    }

    operation = Operation.new(%{}) |> Operation.enforce_query(selecto)

    assert operation.query_enforcement.filters == [{"status", "active"}]
    assert operation.query_enforcement.source.relation == "items"
    assert operation.query_enforcement.source.primary_key == :id
    assert operation.query_enforcement.source.fingerprint == "sha256:items"
    refute Map.has_key?(operation.query_enforcement, :connection)
  end
end
