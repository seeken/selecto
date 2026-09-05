defmodule Selecto.DocumentScalarArrayTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Fixtures, Missing, ShapeRelease}
  alias Selecto.Query.{CapabilityProfile, Cursor, Plan}

  @operations ~w(contains contains_any contains_all)
  @maximum 9_007_199_254_740_991

  test "new scalar-array release is explicit and the original fixture contracts stay unchanged" do
    release = Fixtures.scalar_array_release()
    assert :ok = ShapeRelease.validate(release, require_approved: true)

    for document <- Fixtures.scalar_array_work_orders(),
        do: assert(:ok = ShapeRelease.validate_document(release, document))

    for older <- [Fixtures.release(), Fixtures.aggregate_release()] do
      refute Map.has_key?(older["shape"]["fields"]["tags"], "scalar_array")

      assert {:error, _} =
               Plan.new(older, "work_orders", where("tags", "contains", "urgent"), context())
    end

    assert {:ok, plan} = query(where("tags", "contains", "urgent"))
    assert plan.predicates["field"]["scalar_array"]["max_elements"] == 8
    refute plan.predicates["field"]["filterable"]
    assert "predicate.contains" in plan.required_capabilities
    assert "document.scalar_array" in plan.required_capabilities
    assert :ok = Plan.validate(plan)
    assert Jason.decode!(Jason.encode!(plan))["predicates"] == plan.predicates

    tampered = put_in(plan.predicates["field"]["scalar_array"]["max_elements"], 1000)
    assert {:error, _} = Plan.validate(tampered)
  end

  test "array descriptors reject coercive types, invalid bounds and implicit or native grants" do
    shape = Fixtures.scalar_array_shape()
    descriptor = shape["shape"]["fields"]["tags"]["scalar_array"]

    for invalid <- [
          nil,
          true,
          Map.delete(descriptor, "predicate_ops"),
          Map.put(descriptor, "element_type", "float"),
          Map.put(descriptor, "element_type", "array"),
          Map.put(descriptor, "max_elements", 0),
          Map.put(descriptor, "max_elements", 1001),
          Map.put(descriptor, "max_elements", "8"),
          Map.put(descriptor, "predicate_ops", ["contains", "contains"]),
          Map.put(descriptor, "predicate_ops", ["$all"]),
          Map.put(descriptor, "native", %{})
        ] do
      assert {:error, _} =
               ShapeRelease.new(
                 put_in(shape, ["shape", "fields", "tags", "scalar_array"], invalid)
               )
    end

    assert {:error, _} =
             ShapeRelease.new(
               put_in(shape, ["shape", "fields", "title", "scalar_array"], descriptor)
             )

    assert {:error, _} =
             ShapeRelease.new(put_in(shape, ["shape", "fields", "tags", "filterable"], true))

    no_grants = put_in(shape, ["shape", "fields", "tags", "scalar_array", "predicate_ops"], [])
    {:ok, release} = ShapeRelease.approve(no_grants, approved_by: "scalar-array-test")

    assert {:error, _} =
             Plan.new(release, "work_orders", where("tags", "contains", "urgent"), context())

    assert {:ok, _} = Plan.new(release, "work_orders", %{"select" => ["tags"]}, context())
  end

  test "typed operands are strict bounded literals and duplicate set operands remain valid" do
    for {type, field} <- [{"string", "tags"}, {"integer", "ratings"}, {"boolean", "flags"}] do
      cases = Fixtures.scalar_array_cases(type)

      for op <- @operations do
        assert {:ok, _} = query(where(field, op, cases[op]))
        assert {:error, _} = query(where(field, op, nil))
        assert {:error, _} = query(where(field, op, %{"$in" => [cases["contains"]]}))
      end

      for op <- ~w(contains_any contains_all) do
        assert {:ok, _} = query(where(field, op, []))
        assert {:ok, _} = query(where(field, op, List.duplicate(cases["contains"], 100)))
        assert {:error, _} = query(where(field, op, List.duplicate(cases["contains"], 101)))
        assert {:error, _} = query(where(field, op, [cases["contains"], nil]))
      end
    end

    for {field, value} <- [
          {"ratings", 1.0},
          {"ratings", @maximum + 1},
          {"flags", 1},
          {"tags", <<255>>},
          {"tags", String.duplicate("x", 16_385)},
          {"tags", ["urgent"]}
        ],
        do: assert({:error, _} = query(where(field, "contains", value)))

    assert {:ok, _} = query(where("tags", "contains", "$ne"))
    assert {:error, _} = query(where("source_payload", "contains", "urgent"))
    assert {:error, _} = query(where("tags.path", "contains", "urgent"))
    assert {:error, _} = query(where("tags", "$contains", "urgent"))
  end

  test "typed array validity inspects the entire bounded value with no matching prefix fallback" do
    for type <- ~w(string integer boolean) do
      descriptor = %{"element_type" => type, "max_elements" => 8}

      for sample <- Fixtures.scalar_array_cases(type)["cases"] do
        assert ShapeRelease.scalar_array_valid?(descriptor, sample.value) == sample.valid,
               "#{type}/#{sample.id}"
      end

      first = Fixtures.scalar_array_cases(type)["contains"]
      assert ShapeRelease.scalar_array_valid?(descriptor, List.duplicate(first, 8))
      refute ShapeRelease.scalar_array_valid?(descriptor, List.duplicate(first, 8) ++ [first])
      refute ShapeRelease.scalar_array_valid?(descriptor, [first, %{}])
      refute ShapeRelease.scalar_array_valid?(descriptor, [first, []])
    end

    for integer <- [-@maximum, 0, @maximum],
        do: assert(ShapeRelease.scalar_array_element?("integer", integer))

    for invalid <- [-@maximum - 1, @maximum + 1, 1.0, true],
        do: refute(ShapeRelease.scalar_array_element?("integer", invalid))

    assert ShapeRelease.scalar_array_element?("string", String.duplicate("é", 8192))
    refute ShapeRelease.scalar_array_element?("string", String.duplicate("é", 8193))

    refute ShapeRelease.scalar_array_valid?(
             %{"element_type" => "object", "max_elements" => 8},
             []
           )
  end

  test "whole-document validation distinguishes permitted missing/null from malformed array items" do
    release = Fixtures.scalar_array_release()
    document = hd(Fixtures.scalar_array_work_orders())
    assert :ok = ShapeRelease.validate_document(release, Map.delete(document, "tags"))
    assert :ok = ShapeRelease.validate_document(release, Map.put(document, "tags", nil))
    assert :ok = ShapeRelease.validate_document(release, Map.put(document, "tags", []))

    for value <- [["urgent", 1], [nil], List.duplicate("urgent", 9), "urgent", true, %{}] do
      assert {:error, _} =
               ShapeRelease.validate_document(release, Map.put(document, "tags", value))
    end

    for value <- [["critical", 1], List.duplicate("critical", 9)] do
      invalid =
        Map.update!(document, "parts", fn [first | rest] ->
          [Map.put(first, "labels", value) | rest]
        end)

      assert {:error, _} = ShapeRelease.validate_document(release, invalid)
    end

    refute ShapeRelease.scalar_array_valid?(
             release["shape"]["fields"]["tags"]["scalar_array"],
             %Missing{}
           )
  end

  test "full shape refinements require capability even on unselected fields and aggregate count" do
    for request <- [
          %{"select" => ["id"]},
          %{"aggregate" => [%{"op" => "count", "as" => "total"}]}
        ] do
      {:ok, plan} = query(request)
      assert "document.scalar_array" in plan.required_capabilities

      profile = %CapabilityProfile{
        version: "scalar-array-test",
        enabled: plan.required_capabilities,
        certified: plan.required_capabilities,
        limits: plan.bounds
      }

      assert :ok = CapabilityProfile.preflight(profile, plan)

      assert {:error, _} =
               CapabilityProfile.preflight(
                 %{profile | certified: List.delete(profile.certified, "document.scalar_array")},
                 plan
               )
    end

    shape = Fixtures.scalar_array_shape()

    fields =
      Map.new(shape["shape"]["fields"], fn {id, field} ->
        {id, Map.delete(field, "scalar_array")}
      end)

    {:ok, release} =
      ShapeRelease.approve(put_in(shape, ["shape", "fields"], fields),
        approved_by: "child-only-scalar-array"
      )

    {:ok, plan} = Plan.new(release, "work_orders", %{"select" => ["id"]}, context())
    assert "document.scalar_array" in plan.required_capabilities
  end

  test "child scope, boolean composition and signed cursors retain typed membership intent" do
    query = Map.merge(where("labels", "contains", "critical"), %{"parent_identity" => "wo-1"})

    assert {:ok, child} =
             Plan.new(Fixtures.scalar_array_release(), "work_order_parts", query, context())

    assert child.predicates["field"]["path"] == ["labels"]
    assert "document.array_relation" in child.required_capabilities
    assert :ok = Plan.validate(child)

    assert {:error, _} =
             Plan.new(
               Fixtures.scalar_array_release(),
               "work_order_parts",
               Map.delete(query, "parent_identity"),
               context()
             )

    combined = %{
      "where" => %{
        "op" => "or",
        "args" => [
          where("tags", "contains", "urgent")["where"],
          %{"op" => "eq", "field" => "state", "value" => "open"}
        ]
      }
    }

    assert {:ok, plan} = query(combined)
    assert "predicate.or" in plan.required_capabilities
    assert "predicate.eq" in plan.required_capabilities
    assert "predicate.contains" in plan.required_capabilities

    secret = String.duplicate("x", 32)
    assert {:ok, token} = Cursor.encode(plan, ["wo-1"], cursor_secret: secret)

    assert {:ok, next} =
             Plan.new(
               Fixtures.scalar_array_release(),
               "work_orders",
               Map.put(combined, "cursor", token),
               context() ++ [cursor_secret: secret]
             )

    assert :ok = Plan.validate(next, cursor_secret: secret)

    assert {:error, _} =
             Plan.new(
               Fixtures.scalar_array_release(),
               "work_orders",
               Map.put(where("tags", "contains", "different"), "cursor", token),
               context() ++ [cursor_secret: secret]
             )
  end

  defp where(field, op, value),
    do: %{"where" => %{"op" => op, "field" => field, "value" => value}}

  defp query(input),
    do: Plan.new(Fixtures.scalar_array_release(), "work_orders", input, context())

  defp context, do: [trusted_context: %{tenant_id: "tenant-a"}]
end
