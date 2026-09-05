defmodule Selecto.DocumentObjectRelationTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Canonical, Fixtures, Path, ShapeRelease}
  alias Selecto.Query.{CapabilityProfile, Cursor, Plan, Result}

  @relation "work_order_schedule"
  @columns ~w(due_at timezone duration_minutes)

  test "owned object release is separately authored, canonical, and backward compatible" do
    release = Fixtures.object_relation_release()
    assert :ok = ShapeRelease.validate(release, require_approved: true)
    assert ShapeRelease.features(release) == ["object_relation"]
    assert release == Jason.decode!(Canonical.encode(release))
    assert {:ok, relation} = ShapeRelease.relation(release, @relation)
    assert relation["identity"] == "parent"
    assert relation["cardinality"] == "zero_or_one"
    assert relation["access_patterns"] == release["relations"]["work_orders"]["access_patterns"]

    assert {:ok, %{"path" => ["duration_minutes"], "type" => "integer"}} =
             ShapeRelease.field(release, @relation, "duration_minutes")

    for prior <- [
          Fixtures.release(),
          Fixtures.aggregate_release(),
          Fixtures.scalar_array_release()
        ] do
      refute "object_relation" in ShapeRelease.features(prior)
      assert {:error, _} = ShapeRelease.relation(prior, @relation)
      assert :ok = ShapeRelease.validate(prior, require_approved: true)
    end
  end

  test "shared object corpus preserves absence, null, empty objects, and whole-parent validity" do
    release = Fixtures.object_relation_release()

    for sample <- Fixtures.object_relation_cases() do
      if sample.valid do
        assert :ok = ShapeRelease.validate_document(release, sample.document)
        assert {:ok, rows} = ShapeRelease.object_rows(release, @relation, sample.document)
        projected = Enum.map(rows, fn row -> Enum.map(@columns, &Path.fetch(row, [&1])) end)
        assert projected == sample.rows, sample.id
      else
        assert {:error, _} = ShapeRelease.validate_document(release, sample.document)
        assert {:error, _} = ShapeRelease.object_rows(release, @relation, sample.document)
      end
    end

    assert length(Fixtures.object_relation_documents()) == 7
  end

  test "root object presence policy controls zero rows independently of present child requiredness" do
    shape = Fixtures.object_relation_shape()

    required_child =
      put_in(shape, ["relations", @relation, "fields", "timezone"], %{
        "path" => ["timezone"],
        "type" => "string",
        "required" => true,
        "nullable" => false,
        "missing" => "reject",
        "filterable" => true,
        "sortable" => true
      })

    {:ok, release} = ShapeRelease.approve(required_child, approved_by: "object-test")
    [base | _] = Fixtures.work_orders()
    assert {:ok, []} = ShapeRelease.object_rows(release, @relation, Map.delete(base, "schedule"))

    assert {:ok, []} =
             ShapeRelease.object_rows(release, @relation, Map.put(base, "schedule", nil))

    assert {:error, _} =
             ShapeRelease.object_rows(release, @relation, Map.put(base, "schedule", %{}))

    strict =
      shape
      |> put_in(["shape", "fields", "schedule", "missing"], "reject")
      |> put_in(["shape", "fields", "schedule", "nullable"], false)

    {:ok, strict} = ShapeRelease.approve(strict, approved_by: "object-test")
    assert {:error, _} = ShapeRelease.object_rows(strict, @relation, Map.delete(base, "schedule"))

    assert {:error, _} =
             ShapeRelease.object_rows(strict, @relation, Map.put(base, "schedule", nil))

    assert {:ok, [%{}]} =
             ShapeRelease.object_rows(strict, @relation, Map.put(base, "schedule", %{}))
  end

  test "object contracts reject foreign parents, implicit identities, invented indexes, and unsupported relation options" do
    shape = Fixtures.object_relation_shape()
    relation = shape["relations"][@relation]

    for invalid <- [
          Map.put(relation, "parent", "work_order_parts"),
          Map.put(relation, "source", "other_source"),
          Map.put(relation, "path", ["parts"]),
          Map.put(relation, "path", ["$where"]),
          Map.put(relation, "identity", "document"),
          Map.put(relation, "cardinality", "one"),
          Map.put(relation, "identity_path", ["timezone"]),
          Map.put(relation, "ordering", "source"),
          Map.put(relation, "duplicates", "allow"),
          Map.put(relation, "max_elements", 1),
          Map.put(relation, "fields", %{}),
          Map.put(relation, "access_patterns", %{}),
          put_in(relation, ["access_patterns", "by_tenant_id", "index"], "unreviewed_index"),
          put_in(relation, ["access_patterns", "by_tenant_id", "keys"], ["id"]),
          Map.put(relation, "aggregate_ops", ["count"])
        ],
        do:
          assert({:error, _} = ShapeRelease.new(put_in(shape, ["relations", @relation], invalid)))

    assert {:error, _} =
             ShapeRelease.new(put_in(shape, ["shape", "fields", "id", "type"], "integer"))

    assert {:error, _} =
             ShapeRelease.new(
               put_in(
                 shape,
                 ["relations", @relation, "fields", "timezone", "path"],
                 List.duplicate("nested", 32)
               )
             )
  end

  test "object planning scopes one parent, permits governed predicates, and excludes row paging options" do
    assert {:ok, plan} = query(%{"select" => @columns})
    assert plan.page == %{"limit" => 1, "after" => nil}
    assert plan.ordering == []
    assert plan.aggregates == []
    assert :ok = Plan.validate(plan)
    refute "query.cursor" in plan.required_capabilities
    refute "query.ordering" in plan.required_capabilities
    assert {:error, _} = Cursor.encode(plan, [], cursor_key: String.duplicate("k", 32))
    assert {:error, _} = Plan.cursor_values(plan, [])
    assert {:ok, _} = query(%{"limit" => 1})

    for predicate <- Map.values(Fixtures.object_relation_predicates()) do
      assert {:ok, _} = query(%{"where" => predicate})
    end

    for invalid <- [
          %{"parent_identity" => nil},
          %{"parent_identity" => ""},
          %{"parent_identity" => 1},
          %{"limit" => 2},
          %{"limit" => 1.0},
          %{"limit" => nil},
          %{"order_by" => []},
          %{"cursor" => nil},
          %{"aggregate" => []},
          %{"aggregate" => [%{"op" => "count", "as" => "n"}]}
        ] do
      assert {:error, _} = query(invalid)
    end

    assert {:error, _} = Plan.new(Fixtures.object_relation_release(), @relation, %{}, context())
    assert {:error, _} = query(%{"select" => ["_id"]})

    assert {:error, _} =
             query(%{"where" => %{"op" => "eq", "field" => "duration_minutes", "value" => "15"}})

    assert {:error, _} =
             query(%{"where" => %{"op" => "$where", "field" => "timezone", "value" => "UTC"}})

    assert {:error, _} = Plan.validate(%{plan | page: %{"limit" => 2, "after" => nil}})
  end

  test "object results require inherited identity for zero and one row and prohibit cursors" do
    {:ok, plan} = query(%{"select" => @columns})

    identity = %{
      "kind" => "parent",
      "parent_relation" => "work_orders",
      "parent_identity" => "object-utc"
    }

    assert identity == Result.relation_identity_metadata(plan)
    metadata = %{"relation_identity" => identity}

    for rows <- [[], [[nil, "UTC", 15]]] do
      result = %Result{rows: rows, columns: @columns, metadata: metadata}
      assert :ok = Result.validate(result, plan)
      assert {:error, _} = Result.validate(%{result | metadata: %{}}, plan)

      assert {:error, _} =
               Result.validate(%{result | metadata: %{relation_identity: identity}}, plan)

      assert {:error, _} =
               Result.validate(
                 %{
                   result
                   | metadata: put_in(metadata, ["relation_identity", "parent_identity"], "other")
                 },
                 plan
               )

      assert {:error, _} = Result.validate(%{result | next_cursor: "cursor"}, plan)
    end

    assert {:error, _} =
             Result.validate(
               %Result{
                 rows: [[nil, "UTC", 15], [nil, "UTC", 15]],
                 columns: @columns,
                 metadata: metadata
               },
               plan
             )
  end

  test "unselected root reads and count require object support and object scalar arrays add their own gate" do
    for input <- [%{"select" => ["id"]}, %{"aggregate" => [%{"op" => "count", "as" => "total"}]}] do
      {:ok, plan} = Plan.new(Fixtures.object_relation_release(), "work_orders", input, context())
      assert "document.object_relation" in plan.required_capabilities

      profile = %CapabilityProfile{
        version: "object-test",
        enabled: plan.required_capabilities,
        certified: plan.required_capabilities,
        limits: plan.bounds
      }

      assert :ok = CapabilityProfile.preflight(profile, plan)

      assert {:error, _} =
               CapabilityProfile.preflight(
                 %{
                   profile
                   | certified: List.delete(profile.certified, "document.object_relation")
                 },
                 plan
               )
    end

    field = Fixtures.scalar_array_shape()["shape"]["fields"]["tags"]

    shape =
      put_in(Fixtures.object_relation_shape(), ["relations", @relation, "fields", "tags"], field)

    {:ok, release} = ShapeRelease.approve(shape, approved_by: "object-test")
    assert ShapeRelease.features(release) == ["object_relation", "scalar_array"]
    {:ok, plan} = Plan.new(release, "work_orders", %{"select" => ["id"]}, context())
    assert "document.scalar_array" in plan.required_capabilities

    {:ok, object_plan} =
      Plan.new(
        release,
        @relation,
        %{
          "parent_identity" => "object-utc",
          "where" => %{"op" => "contains", "field" => "tags", "value" => "urgent"}
        },
        context()
      )

    assert "predicate.contains" in object_plan.required_capabilities
    [base | _] = Fixtures.work_orders()

    assert :ok =
             ShapeRelease.validate_document(
               release,
               put_in(base, ["schedule", "tags"], ["urgent"])
             )

    assert {:error, _} =
             ShapeRelease.validate_document(
               release,
               put_in(base, ["schedule", "tags"], ["urgent", 1])
             )
  end

  test "drift recognizes owned object fields without treating absent owners as missing required children" do
    alias Selecto.Document.{Drift, Inference}
    shape = Fixtures.object_relation_shape()

    shape =
      shape
      |> put_in(["relations", @relation, "fields", "duration_minutes", "required"], true)
      |> put_in(["relations", @relation, "fields", "duration_minutes", "missing"], "reject")

    {:ok, release} = ShapeRelease.approve(shape, approved_by: "object-drift-test")
    [base | _] = Fixtures.work_orders()
    documents = [Map.delete(base, "schedule"), put_in(base, ["schedule", "duration_minutes"], 15)]
    {:ok, report} = Inference.run(documents)
    {:ok, drift} = Drift.compare(release, report)
    assert "owned_object_child_requiredness" in drift["not_evaluated"]

    refute Enum.any?(
             drift["findings"],
             &(&1["path"] == ["schedule", "duration_minutes"] and
                 &1["kind"] in ["unpublished_path", "required_field_missing"])
           )

    {:ok, invalid_report} = Inference.run([put_in(base, ["schedule", "duration_minutes"], "bad")])
    {:ok, invalid_drift} = Drift.compare(release, invalid_report)

    assert Enum.any?(
             invalid_drift["findings"],
             &(&1["path"] == ["schedule", "duration_minutes"] and
                 &1["kind"] == "incompatible_types")
           )
  end

  test "nested object-relative projections retain independent nested capability requirements" do
    shape = Fixtures.object_relation_shape()

    field =
      shape["relations"][@relation]["fields"]["due_at"] |> Map.put("path", ["details", "note"])

    shape = put_in(shape, ["relations", @relation, "fields", "note"], field)
    {:ok, release} = ShapeRelease.approve(shape, approved_by: "object-nested-test")

    {:ok, plan} =
      Plan.new(
        release,
        @relation,
        %{"parent_identity" => "object-utc", "select" => ["note"]},
        context()
      )

    assert "document.object_relation" in plan.required_capabilities
    assert "document.nested" in plan.required_capabilities

    profile = %CapabilityProfile{
      version: "object-nested-test",
      enabled: plan.required_capabilities,
      certified: plan.required_capabilities,
      limits: plan.bounds
    }

    assert :ok = CapabilityProfile.preflight(profile, plan)

    assert {:error, _} =
             CapabilityProfile.preflight(
               %{profile | certified: List.delete(profile.certified, "document.nested")},
               plan
             )
  end

  defp query(query),
    do:
      Plan.new(
        Fixtures.object_relation_release(),
        @relation,
        Map.merge(%{"parent_identity" => "object-utc"}, query),
        context()
      )

  defp context, do: [trusted_context: %{tenant_id: "tenant-a"}]
end
