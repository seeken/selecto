defmodule Selecto.Document.KeyAccessPatternTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Fixtures, ShapeRelease}
  alias Selecto.Query.Plan
  alias Selecto.Write.DocumentMutation

  defp shape do
    Fixtures.shape()
    |> put_in(["relations", "work_orders", "access_patterns", "by_tenant_id"], %{
      "index" => "primary",
      "keys" => ["tenant_id", "id"],
      "key_schema" => %{"partition" => "tenant_id", "sort" => "id"},
      "consistent_read" => "strong",
      "filter_fields" => ["state", "priority"],
      "max_evaluated_items" => 200,
      "max_pages" => 4
    })
  end

  test "approved named key patterns are digest-bound and derive an adapter gate" do
    {:ok, draft} = ShapeRelease.new(shape())
    {:ok, release} = ShapeRelease.approve(draft, approved_by: "key-pattern-author")
    assert ShapeRelease.features(release) == ["key_access_pattern"]

    {:ok, plan} =
      Plan.new(release, "work_orders", %{"select" => ["id"]},
        trusted_context: %{tenant_id: "tenant-a"}
      )

    assert "document.key_access_pattern" in plan.required_capabilities

    assert plan.metadata["access_pattern"]["key_schema"] == %{
             "partition" => "tenant_id",
             "sort" => "id"
           }
  end

  test "embedded children may reuse the root key access pattern" do
    root_pattern =
      get_in(shape(), ["relations", "work_orders", "access_patterns", "by_tenant_id"])

    shaped =
      put_in(
        shape(),
        ["relations", "work_order_parts", "access_patterns"],
        %{"by_parent" => %{root_pattern | "filter_fields" => []}}
      )

    assert {:ok, _} = ShapeRelease.new(shaped)
  end

  test "partial, unsafe and unbounded key patterns are rejected" do
    pattern = get_in(shape(), ["relations", "work_orders", "access_patterns", "by_tenant_id"])

    invalid = [
      Map.delete(pattern, "max_pages"),
      put_in(pattern, ["key_schema", "partition"], "state"),
      put_in(pattern, ["key_schema", "sort"], "unknown"),
      Map.put(pattern, "filter_fields", ["tenant_id"]),
      Map.put(pattern, "consistent_read", "sometimes"),
      Map.put(pattern, "max_evaluated_items", 10_001),
      Map.put(pattern, "max_pages", 0)
    ]

    for changed <- invalid do
      assert {:error, _} =
               ShapeRelease.new(
                 put_in(
                   shape(),
                   ["relations", "work_orders", "access_patterns", "by_tenant_id"],
                   changed
                 )
               )
    end
  end

  test "governed writes derive the key-access capability" do
    {:ok, draft} = ShapeRelease.new(shape())
    {:ok, release} = ShapeRelease.approve(draft, approved_by: "key-pattern-author")

    mutation = %DocumentMutation{
      identity: %{path: ["_id"], value: "wo-1"},
      tenant: %{path: ["tenant_id"], value: "tenant-a"},
      version: %{path: ["version"], expected: 1},
      mutations: [%{op: :set, path: ["title"], value: "changed"}],
      action: "revise",
      idempotency_key: "key",
      payload_digest: DocumentMutation.digest("payload"),
      scope_digest: DocumentMutation.digest("scope"),
      shape_version: release["id"],
      shape_digest: release["digest"],
      shape_features: ShapeRelease.features(release),
      effects: ["work_orders.revised/v1"]
    }

    assert :ok = DocumentMutation.validate(mutation)
    assert :document_key_access_pattern in DocumentMutation.capabilities(mutation)
  end
end
