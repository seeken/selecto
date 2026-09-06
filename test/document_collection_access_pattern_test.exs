defmodule Selecto.Document.CollectionAccessPatternTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Fixtures, ShapeRelease}
  alias Selecto.Query.Plan

  defp pattern do
    %{
      "index" => "tenant_id_asc__id_asc",
      "keys" => ["tenant_id", "id"],
      "collection_schema" => %{
        "scope" => "collection",
        "tenant" => "tenant_id",
        "identity" => "id",
        "order" => ["id"]
      },
      "filter_fields" => ["state", "priority"],
      "max_documents" => 200,
      "max_pages" => 4
    }
  end

  test "approved collection patterns derive a portable capability" do
    shape =
      put_in(Fixtures.shape(), ["relations", "work_orders", "access_patterns"], %{
        "by_tenant" => pattern()
      })

    assert {:ok, draft} = ShapeRelease.new(shape)
    assert {:ok, release} = ShapeRelease.approve(draft, approved_by: "firestore-control")
    assert ShapeRelease.features(release) == ["collection_access_pattern"]

    assert {:ok, plan} =
             Plan.new(release, "work_orders", %{"select" => ["id"]},
               trusted_context: %{tenant_id: "tenant-a"}
             )

    assert "document.collection_access_pattern" in plan.required_capabilities
  end

  test "unsafe and unbounded collection patterns are rejected" do
    invalid = [
      put_in(pattern(), ["collection_schema", "scope"], "all"),
      put_in(pattern(), ["collection_schema", "tenant"], "unknown"),
      put_in(pattern(), ["collection_schema", "order"], ["priority"]),
      Map.put(pattern(), "filter_fields", ["tenant_id"]),
      Map.put(pattern(), "max_documents", 10_001),
      Map.put(pattern(), "max_pages", 0)
    ]

    for changed <- invalid do
      shape =
        put_in(Fixtures.shape(), ["relations", "work_orders", "access_patterns"], %{
          "by_tenant" => changed
        })

      assert {:error, _} = ShapeRelease.new(shape)
    end
  end
end
