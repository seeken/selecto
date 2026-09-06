defmodule Selecto.Document.SourceProfileTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Fixtures, Numeric, ShapeRelease}
  alias Selecto.Query.{Cursor, Plan}
  alias Selecto.Write.{Capabilities, Command, DocumentMutation}

  defp release(namespace \\ ["bucket-a", "scope_a"]) do
    draft = Fixtures.shape() |> put_in(["source", "namespace"], namespace)
    draft = put_in(draft, ["source", "numeric_semantics"], "json_number")
    {:ok, draft} = ShapeRelease.new(draft)
    {:ok, release} = ShapeRelease.approve(draft, approved_by: "synthetic-source-profile")
    release
  end

  test "JSON number interpretation is approved, explicit and legacy behavior remains strict" do
    source = release()
    doc = hd(Fixtures.work_orders()) |> Map.put("priority", 2.0) |> Map.put("version", 1.0)
    assert :ok = ShapeRelease.validate_document(source, doc)
    assert {:error, _} = ShapeRelease.validate_document(Fixtures.release(), doc)
    field = source["shape"]["fields"]["priority"]
    assert Numeric.normalize(source, field, 2.0) === 2
    assert Numeric.normalize(Fixtures.release(), field, 2.0) === 2.0

    for value <- [2.5, "2", true, 9_007_199_254_740_992, 9_007_199_254_740_992.0] do
      assert {:error, _} = ShapeRelease.validate_document(source, Map.put(doc, "priority", value))
    end

    assert ShapeRelease.features(source) == ["json_number", "source_namespace"]

    for value <- [nil, false, "strict", %{}] do
      assert {:error, _} =
               ShapeRelease.new(put_in(Fixtures.shape(), ["source", "numeric_semantics"], value))
    end

    for value <- [[], ["bucket", "$scope"], ["bucket.scope"], :invalid, List.duplicate("a", 9)] do
      assert {:error, _} =
               ShapeRelease.new(put_in(Fixtures.shape(), ["source", "namespace"], value))
    end
  end

  test "namespace and number profile derive preflight gates and namespace changes invalidate cursors" do
    opts = [trusted_context: %{tenant_id: "tenant-a"}, cursor_secret: String.duplicate("a", 32)]
    {:ok, plan} = Plan.new(release(), "work_orders", %{"select" => ["id", "priority"]}, opts)
    assert "document.json_number" in plan.required_capabilities
    assert "document.source_namespace" in plan.required_capabilities
    {:ok, token} = Cursor.encode(plan, ["wo-1"], opts)

    {:ok, other} =
      Plan.new(
        release(["bucket-a", "other"]),
        "work_orders",
        %{"select" => ["id", "priority"]},
        opts
      )

    assert {:error, _} = Cursor.decode(other, token, opts)
    assert {:ok, ["wo-1"]} = Cursor.decode(plan, token, opts)
  end

  test "document write features are explicit and cannot be suppressed by caller capability lists" do
    mutation = %DocumentMutation{
      identity: %{path: ["_id"], value: "wo-1"},
      tenant: %{path: ["tenant_id"], value: "tenant-a"},
      version: %{path: ["version"], expected: 1},
      action: "revise",
      idempotency_key: "key",
      payload_digest: DocumentMutation.digest("payload"),
      scope_digest: DocumentMutation.digest("scope"),
      shape_version: "work-orders/v1",
      shape_digest: release()["digest"],
      shape_features: ShapeRelease.features(release()),
      effects: ["work_orders.revised/v1"],
      mutations: [%{op: :set, path: ["priority"], value: 3}]
    }

    assert :ok = DocumentMutation.validate(mutation)

    command = %Command{
      operation: :update,
      relation: "work_orders",
      metadata: %{document: mutation}
    }

    assert :document_json_number in Capabilities.requirements(command)
    assert :document_source_namespace in Capabilities.requirements(command)

    capabilities =
      Map.new(DocumentMutation.capabilities(mutation), &{&1, true})
      |> Map.merge(%{protocol_version: 1, update: true})

    assert :ok = Capabilities.require(capabilities, command)

    assert {:error, _} =
             Capabilities.require(Map.delete(capabilities, :document_json_number), command)

    assert {:error, _} =
             Capabilities.require(Map.delete(capabilities, :document_source_namespace), command)
  end
end
