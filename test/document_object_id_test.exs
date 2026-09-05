defmodule Selecto.DocumentObjectIdTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Canonical, Drift, Fixtures, Inference, ObjectId, ShapeRelease}
  alias Selecto.Query.{CapabilityProfile, Cursor, Plan, Result}

  @secret String.duplicate("object-id-secret", 3)

  test "ObjectId construction is explicit and validation accepts only exact canonical tags" do
    hex = "ABCDEF0123456789ABCDEF01"
    assert {:ok, canonical} = ObjectId.new(hex)
    assert canonical == %{"$bson" => "object_id", "value" => String.downcase(hex)}
    assert ObjectId.valid?(canonical)
    assert Jason.decode!(Canonical.encode(canonical)) == canonical

    for sample <- Fixtures.object_id_cases(),
        do: assert(ObjectId.valid?(sample.value) == sample.valid, sample.id)

    for invalid <- [
          nil,
          canonical,
          String.duplicate("a", 23),
          String.duplicate("a", 25),
          String.duplicate("z", 24),
          :binary.copy(<<255>>, 24)
        ] do
      assert {:error, :invalid_object_id} = ObjectId.new(invalid)
    end

    refute ObjectId.valid?(%{"$bson" => "object_id", "value" => :binary.copy(<<255>>, 24)})
    refute ObjectId.valid?(Map.put(canonical, :__struct__, __MODULE__))
  end

  test "authored root and child identities preserve ObjectId distinct from strings" do
    release = Fixtures.object_id_release()
    assert ShapeRelease.features(release) == ["object_id", "object_relation"]
    assert :ok = ShapeRelease.validate(release, require_approved: true)

    for document <- Fixtures.object_id_documents(),
        do: assert(:ok = ShapeRelease.validate_document(release, document))

    [document | _] = Fixtures.object_id_documents()

    for invalid <- Enum.reject(Fixtures.object_id_cases(), & &1.valid) do
      assert {:error, _} =
               ShapeRelease.validate_document(release, Map.put(document, "_id", invalid.value))

      invalid_child =
        Map.update!(document, "parts", fn [part | rest] ->
          [Map.put(part, "part_id", invalid.value) | rest]
        end)

      assert {:error, _} = ShapeRelease.validate_document(release, invalid_child)
    end

    [part | _] = document["parts"]

    assert {:error, _} =
             ShapeRelease.validate_document(release, Map.put(document, "parts", [part, part]))

    assert {:error, _} =
             ShapeRelease.new(
               put_in(Fixtures.object_id_shape(), ["shape", "fields", "id", "nullable"], true)
             )

    assert {:error, _} =
             ShapeRelease.new(
               put_in(
                 Fixtures.object_id_shape(),
                 ["relations", "work_order_parts", "fields", "part_id", "required"],
                 false
               )
             )

    assert {:error, _} =
             ShapeRelease.new(
               put_in(
                 Fixtures.object_id_shape(),
                 ["shape", "fields", "tenant_id", "type"],
                 "object_id"
               )
             )

    for old <- [
          Fixtures.release(),
          Fixtures.aggregate_release(),
          Fixtures.object_relation_release(),
          Fixtures.scalar_array_release()
        ] do
      refute "object_id" in ShapeRelease.features(old)
      assert old["shape"]["fields"]["id"]["type"] == "string"
      assert :ok = ShapeRelease.validate(old, require_approved: true)
    end
  end

  test "ObjectId predicates and ordering use declared type without string coercion" do
    for op <- ~w(eq ne gt gte lt lte in) do
      value =
        if op == "in",
          do: [Fixtures.object_id(1), Fixtures.object_id(2)],
          else: Fixtures.object_id(1)

      assert {:ok, plan} = query(%{"where" => %{"op" => op, "field" => "id", "value" => value}})
      assert plan.predicates["value"] == value
      assert "document.object_id" in plan.required_capabilities
      assert :ok = Plan.validate(plan)
    end

    for sample <- Enum.reject(Fixtures.object_id_cases(), & &1.valid) do
      assert {:error, _} =
               query(%{"where" => %{"op" => "eq", "field" => "id", "value" => sample.value}})

      assert {:error, _} =
               query(%{"where" => %{"op" => "in", "field" => "id", "value" => [sample.value]}})
    end

    assert {:ok, ordered} = query(%{"order_by" => [%{"field" => "id", "direction" => "desc"}]})
    assert [%{"field" => %{"type" => "object_id"}, "direction" => "desc"}] = ordered.ordering

    assert {:error, _} =
             query(%{
               "where" => %{"op" => "eq", "field" => "title", "value" => Fixtures.object_id(1)}
             })

    assert {:ok, _} =
             query(%{
               "where" => %{
                 "op" => "eq",
                 "field" => "title",
                 "value" => Fixtures.object_id(1)["value"]
               }
             })

    for op <- ~w(exists missing is_null is_not_null),
        do: assert({:ok, _} = query(%{"where" => %{"op" => op, "field" => "customer_id"}}))
  end

  test "ObjectId wire representation descendants cannot be published in any relation scope" do
    shape = Fixtures.object_id_shape()
    template = shape["shape"]["fields"]["title"]
    field = fn path -> Map.put(template, "path", path) end

    invalid = [
      put_in(shape, ["shape", "fields", "id_hex"], field.(["_id", "value"])),
      put_in(shape, ["shape", "fields", "customer_hex"], field.(["customer_id", "value"])),
      put_in(
        shape,
        ["relations", "work_order_parts", "fields", "part_hex"],
        field.(["part_id", "value"])
      ),
      put_in(
        shape,
        ["relations", "work_order_schedule", "fields", "owner_hex"],
        field.(["owner_id", "value"])
      ),
      put_in(shape, ["shape", "fields", "owner_hex"], field.(["schedule", "owner_id", "value"]))
    ]

    root_object_id =
      put_in(
        shape,
        ["shape", "fields", "root_owner"],
        Map.put(shape["shape"]["fields"]["customer_id"], "path", ["schedule", "root_owner"])
      )

    invalid = [
      put_in(
        root_object_id,
        ["relations", "work_order_schedule", "fields", "root_owner_hex"],
        field.(["root_owner", "value"])
      )
      | invalid
    ]

    for declaration <- invalid do
      assert {:error, errors} = ShapeRelease.new(declaration)
      assert "ObjectId fields are atomic and cannot publish descendant paths" in errors
      assert {:error, _} = ShapeRelease.approve(declaration, approved_by: "atomic-id-test")

      forged =
        declaration
        |> Map.put("status", "approved")
        |> Map.put("approval", %{"approved_by" => "atomic-id-test"})
        |> Map.delete("digest")

      forged = Map.put(forged, "digest", Canonical.digest(forged))
      assert {:error, _} = ShapeRelease.validate(forged, require_approved: true)
      assert {:error, _} = Plan.new(forged, "work_orders", %{"select" => ["id"]}, context())
    end
  end

  test "physical path type conflicts fail across root and owned-object or array views" do
    shape = Fixtures.object_id_shape()
    owner = shape["relations"]["work_order_schedule"]["fields"]["owner_id"]

    root_owner =
      owner
      |> Map.put("path", ["schedule", "owner_id"])
      |> Map.put("type", "object")
      |> Map.put("filterable", false)
      |> Map.put("sortable", false)

    conflicting = put_in(shape, ["shape", "fields", "root_owner"], root_owner)
    assert {:error, errors} = ShapeRelease.new(conflicting)
    assert "ObjectId physical paths cannot have conflicting field types" in errors

    # Reversing the scopes cannot bypass the same physical-path lookup.
    reversed =
      put_in(conflicting, ["shape", "fields", "root_owner", "type"], "object_id")
      |> put_in(["relations", "work_order_schedule", "fields", "owner_id", "type"], "string")

    assert {:error, _} = ShapeRelease.new(reversed)

    parts = shape["relations"]["work_order_parts"]
    # Both identities remain valid in their local scope, but the native element
    # path cannot simultaneously be a string in another view.
    other_parts = put_in(parts, ["fields", "part_id", "type"], "string")

    assert {:error, errors} =
             ShapeRelease.new(put_in(shape, ["relations", "other_parts"], other_parts))

    assert "ObjectId physical paths cannot have conflicting field types" in errors

    other_parts =
      put_in(
        parts,
        ["fields", "wire_value"],
        Map.put(shape["shape"]["fields"]["title"], "path", ["part_id", "value"])
      )

    assert {:error, errors} =
             ShapeRelease.new(put_in(shape, ["relations", "other_parts"], other_parts))

    assert "ObjectId fields are atomic and cannot publish descendant paths" in errors
  end

  test "same-type ObjectId views and ordinary object ancestors remain valid" do
    shape = Fixtures.object_id_shape()
    owner = shape["relations"]["work_order_schedule"]["fields"]["owner_id"]

    compatible =
      put_in(
        shape,
        ["shape", "fields", "root_owner"],
        Map.put(owner, "path", ["schedule", "owner_id"])
      )

    compatible =
      put_in(
        compatible,
        ["relations", "other_parts"],
        compatible["relations"]["work_order_parts"]
      )

    assert {:ok, draft} = ShapeRelease.new(compatible)
    assert {:ok, release} = ShapeRelease.approve(draft, approved_by: "atomic-id-test")

    for document <- Fixtures.object_id_documents(),
        do: assert(:ok = ShapeRelease.validate_document(release, document))

    # A property with this name on an ordinary ancestor is not the wire value
    # of the separate ObjectId child; prefixes are compared by whole segments.
    ordinary =
      put_in(
        compatible,
        ["shape", "fields", "schedule_value"],
        Map.put(shape["shape"]["fields"]["timezone"], "path", ["schedule", "value"])
      )

    assert {:ok, _} = ShapeRelease.new(ordinary)
  end

  test "non-ObjectId overlapping type refinements preserve existing release acceptance" do
    shape =
      put_in(Fixtures.object_relation_shape(), ["shape", "fields", "timezone", "type"], "binary")

    assert shape["relations"]["work_order_schedule"]["fields"]["timezone"]["type"] == "string"
    assert {:ok, draft} = ShapeRelease.new(shape)
    assert {:ok, release} = ShapeRelease.approve(draft, approved_by: "legacy-overlap-test")
    assert ShapeRelease.features(release) == ["object_relation"]
    assert release["digest"] == Canonical.digest(Map.delete(release, "digest"))
    assert :ok = ShapeRelease.validate(release, require_approved: true)

    for document <- Fixtures.object_relation_documents(),
        do: assert(:ok = ShapeRelease.validate_document(release, document))
  end

  test "array and object parent scopes require the reviewed root identity type" do
    release = Fixtures.object_id_release()
    parent = Fixtures.object_id(1)

    for relation <- ["work_order_parts", "work_order_schedule"] do
      assert {:ok, plan} = Plan.new(release, relation, %{"parent_identity" => parent}, context())
      assert plan.relation["parent_identity"] == parent
      assert :ok = Plan.validate(plan)

      for invalid <- [parent["value"], 1, Map.put(parent, "extra", true)] do
        assert {:error, _} =
                 Plan.new(release, relation, %{"parent_identity" => invalid}, context())
      end

      assert {:error, _} =
               Plan.new(
                 Fixtures.object_relation_release(),
                 relation,
                 %{"parent_identity" => parent},
                 context()
               )
    end

    {:ok, object} =
      Plan.new(
        release,
        "work_order_schedule",
        %{"parent_identity" => parent, "select" => ["owner_id"]},
        context()
      )

    assert Result.relation_identity_metadata(object)["parent_identity"] == parent

    result = %Result{
      rows: [[Fixtures.object_id(301)]],
      columns: ["owner_id"],
      metadata: %{"relation_identity" => Result.relation_identity_metadata(object)}
    }

    assert :ok = Result.validate(result, object)

    integer_shape = put_in(Fixtures.shape(), ["shape", "fields", "id", "type"], "integer")

    {:ok, integer_release} =
      ShapeRelease.approve(integer_shape, approved_by: "existing-integer-scope")

    assert {:error, _} =
             Plan.new(integer_release, "work_order_parts", %{"parent_identity" => 1}, context())
  end

  test "signed cursors preserve canonical ObjectId values and reject tag or scope changes" do
    {:ok, plan} = query(%{"limit" => 1})
    value = Fixtures.object_id(1)
    opts = [cursor_secret: @secret, cursor_now: 1000]
    assert {:ok, token} = Cursor.encode(plan, [value], opts)
    assert {:ok, [^value]} = Cursor.decode(plan, token, opts)
    [body, _signature] = String.split(token, ".")
    payload = Base.url_decode64!(body, padding: false)
    assert payload == Canonical.encode(Jason.decode!(payload))
    assert Jason.decode!(payload)["values"] == [value]
    assert {:error, _} = Cursor.encode(plan, [value["value"]], opts)
    assert {:error, _} = Cursor.encode(plan, [Map.put(value, "extra", true)], opts)

    assert {:ok, next} = query(%{"limit" => 1, "cursor" => token}, opts)
    assert next.page["after"] == [value]
    assert :ok = Plan.validate(next, opts)

    assert {:error, _} =
             Plan.validate(
               %{next | page: Map.put(next.page, "after", [Fixtures.object_id(2)])},
               opts
             )

    {:ok, other_parent} =
      Plan.new(
        Fixtures.object_id_release(),
        "work_order_parts",
        %{"parent_identity" => Fixtures.object_id(2)},
        context()
      )

    assert {:error, _} = Cursor.decode(other_parent, token, opts)
  end

  test "ObjectId release-wide capability closure includes child-only fields on unselected roots and counts" do
    shapes = [
      put_in(
        Fixtures.aggregate_shape(),
        ["relations", "work_order_parts", "fields", "part_id", "type"],
        "object_id"
      ),
      put_in(
        Fixtures.object_relation_shape(),
        ["relations", "work_order_schedule", "fields", "owner_id"],
        Fixtures.object_id_shape()["relations"]["work_order_schedule"]["fields"]["owner_id"]
      )
    ]

    for shape <- shapes do
      {:ok, release} = ShapeRelease.approve(shape, approved_by: "child-only-object-id")
      assert release["shape"]["fields"]["id"]["type"] == "string"
      assert "object_id" in ShapeRelease.features(release)

      for request <- [
            %{"select" => ["id"]},
            %{"aggregate" => [%{"op" => "count", "as" => "total"}]}
          ] do
        {:ok, plan} = Plan.new(release, "work_orders", request, context())
        assert "document.object_id" in plan.required_capabilities

        profile = %CapabilityProfile{
          version: "object-id-test",
          enabled: plan.required_capabilities,
          certified: plan.required_capabilities,
          limits: plan.bounds
        }

        assert :ok = CapabilityProfile.preflight(profile, plan)

        assert {:error, _} =
                 CapabilityProfile.preflight(
                   %{profile | certified: List.delete(profile.certified, "document.object_id")},
                   plan
                 )
      end
    end
  end

  test "ordinary map inference never invents native ObjectId identity" do
    {:ok, report} = Inference.run(Fixtures.object_id_documents())
    id = Enum.find(report["paths"], &(&1["path"] == ["_id"]))
    assert id["types"] == %{"object" => 3}
    refute Inference.canonical_json(report) =~ Fixtures.object_id(201)["value"]
    {:ok, drift} = Drift.compare(Fixtures.object_id_release(), report)
    assert "native_object_id_identity" in drift["not_evaluated"]

    assert Enum.any?(
             drift["findings"],
             &(&1["path"] == ["_id"] and &1["kind"] == "object_id_requires_typed_validation" and
                 &1["classification"] == "inconclusive")
           )

    refute Enum.any?(
             drift["findings"],
             &(&1["path"] == ["_id", "value"] and &1["kind"] == "unpublished_path")
           )

    {:ok, strings} =
      Inference.run([
        Map.put(hd(Fixtures.object_id_documents()), "_id", Fixtures.object_id(1)["value"])
      ])

    {:ok, invalid} = Drift.compare(Fixtures.object_id_release(), strings)

    assert Enum.any?(
             invalid["findings"],
             &(&1["path"] == ["_id"] and &1["kind"] == "incompatible_types")
           )
  end

  test "projected ObjectIds preserve canonical tags and approved missing/null policies" do
    {:ok, plan} = query(%{"select" => ["id", "customer_id"]})
    id = Fixtures.object_id(1)

    for optional <- [Fixtures.object_id(201), nil, %Selecto.Document.Missing{}] do
      result = %Result{columns: ["id", "customer_id"], rows: [[id, optional]]}
      assert :ok = Result.validate(result, plan)
      assert Jason.decode!(Jason.encode!(result))["rows"] |> hd() |> hd() == id
    end

    for value <- [id["value"], Map.put(id, "extra", true), nil, %Selecto.Document.Missing{}] do
      assert {:error, _} =
               Result.validate(
                 %Result{columns: ["id", "customer_id"], rows: [[value, nil]]},
                 plan
               )
    end

    assert {:error, _} =
             Result.validate(
               %Result{columns: ["id", "customer_id"], rows: [[id, id["value"]]]},
               plan
             )
  end

  defp context, do: [trusted_context: %{tenant_id: "tenant-a"}]

  defp query(request, opts \\ []),
    do: Plan.new(Fixtures.object_id_release(), "work_orders", request, context() ++ opts)
end
