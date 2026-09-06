defmodule Selecto.Document.Fixtures do
  @moduledoc "Independently authored synthetic work orders for the document reference slice."
  alias Selecto.Document.{ObjectId, ShapeRelease}

  def work_orders do
    [
      %{
        "_id" => "wo-1",
        "tenant_id" => "tenant-a",
        "kind" => "repair",
        "title" => "Replace pump",
        "state" => "open",
        "priority" => 2,
        "version" => 1,
        "schedule" => %{"due_at" => nil, "timezone" => "UTC"},
        "parts" => [
          %{"part_id" => "part-1", "sku" => "pump-a", "quantity" => 3, "reserved" => 0},
          %{"part_id" => "part-2", "sku" => "seal-b", "quantity" => 2, "reserved" => 1}
        ],
        "tags" => ["urgent", "urgent"],
        "source_payload" => %{"legacy_code" => "synthetic-a"},
        "labor" => %{"minutes" => 30}
      },
      %{
        "_id" => "wo-2",
        "tenant_id" => "tenant-a",
        "kind" => "inspection",
        "title" => "Inspect valve",
        "state" => "open",
        "version" => 4,
        "schedule" => %{"timezone" => "UTC"},
        "parts" => [],
        "tags" => [],
        "source_payload" => %{},
        "checklist" => [%{"item" => "seal", "passed" => true}]
      },
      %{
        "_id" => "wo-3",
        "tenant_id" => "tenant-b",
        "kind" => "repair",
        "title" => "Service motor",
        "state" => "closed",
        "priority" => 1,
        "version" => 2,
        "schedule" => %{"due_at" => "2026-08-26T12:00:00Z", "timezone" => "UTC"},
        "parts" => [
          %{"part_id" => "part-1", "sku" => "motor-c", "quantity" => 1, "reserved" => 0}
        ],
        "tags" => ["routine"],
        "source_payload" => %{"origin" => "synthetic"},
        "labor" => %{"minutes" => 15}
      }
    ]
  end

  @doc "Known-invalid legacy evidence; inference can describe it but approval never coerces it."
  def legacy_work_orders do
    [first | _] = work_orders()

    [
      first
      |> Map.put("_id", "legacy-1")
      |> Map.put("priority", "high")
      |> Map.put("schedule", %{"due_at" => 1_782_000_000})
    ]
  end

  def shape do
    fields = %{
      "id" => scalar(["_id"], "string", true, server_managed: true),
      "tenant_id" => scalar(["tenant_id"], "string", true, server_managed: true),
      "kind" => scalar(["kind"], "string", true),
      "title" => scalar(["title"], "string", true),
      "state" => scalar(["state"], "string", true),
      "priority" => scalar(["priority"], "integer", false),
      "version" => scalar(["version"], "integer", true, server_managed: true),
      "due_at" => scalar(["schedule", "due_at"], "string", false, nullable: true),
      "timezone" => scalar(["schedule", "timezone"], "string", false),
      "parts" => opaque(["parts"], "array"),
      "tags" => opaque(["tags"], "array"),
      "source_payload" => opaque(["source_payload"], "object")
    }

    %{
      "schema_version" => 1,
      "id" => "work-orders/v1",
      "status" => "draft",
      "source" => %{
        "id" => "work_orders_docs",
        "kind" => "document_collection",
        "collection" => "work_orders",
        "sql_table" => "work_orders",
        "identity_path" => ["_id"],
        "tenant_path" => ["tenant_id"],
        "version_path" => ["version"]
      },
      "shape" => %{
        "fields" => fields,
        "unknown_field_policy" => "ignore",
        "variants" => %{
          "path" => ["kind"],
          "values" => ["inspection", "repair"],
          "unknown_policy" => "reject"
        }
      },
      "relations" => %{
        "work_orders" => %{
          "kind" => "root",
          "source" => "work_orders_docs",
          "identity_path" => ["_id"],
          "fields" => Enum.sort(Map.keys(fields)),
          "access_patterns" => %{
            "by_tenant_id" => %{"index" => "tenant_identity", "keys" => ["tenant_id", "id"]}
          }
        },
        "work_order_parts" => %{
          "kind" => "array",
          "source" => "work_orders_docs",
          "parent" => "work_orders",
          "path" => ["parts"],
          "identity_path" => ["part_id"],
          "max_elements" => 200,
          "ordering" => "source",
          "duplicates" => "reject_identity",
          "fields" => %{
            "part_id" => scalar(["part_id"], "string", true),
            "sku" => scalar(["sku"], "string", true),
            "quantity" => scalar(["quantity"], "integer", true),
            "reserved" => scalar(["reserved"], "integer", true)
          },
          "access_patterns" => %{
            "by_parent_part" => %{"index" => "tenant_identity", "keys" => ["part_id"]}
          }
        }
      }
    }
  end

  def release do
    {:ok, draft} = ShapeRelease.new(shape())
    {:ok, release} = ShapeRelease.approve(draft, approved_by: "synthetic-fixture-author")
    release
  end

  @doc "A separately authored root aggregate release; the initial release stays unchanged."
  def aggregate_shape do
    shape()
    |> Map.put("id", "work-orders/aggregates-v1")
    |> put_in(["relations", "work_orders", "aggregate_ops"], ["count"])
    |> put_in(["shape", "fields", "priority", "aggregate_ops"], ~w(sum min max))
    |> put_in(["shape", "fields", "priority", "nullable"], true)
  end

  def aggregate_release do
    {:ok, draft} = ShapeRelease.new(aggregate_shape())
    {:ok, release} = ShapeRelease.approve(draft, approved_by: "synthetic-fixture-author")
    release
  end

  @doc "An optional owned schedule object with inherited parent identity; older releases are unchanged."
  def object_relation_shape do
    shape = aggregate_shape()

    object =
      opaque(["schedule"], "object")
      |> Map.merge(%{"required" => false, "nullable" => true, "missing" => "preserve"})

    relation = %{
      "kind" => "object",
      "source" => "work_orders_docs",
      "parent" => "work_orders",
      "path" => ["schedule"],
      "identity" => "parent",
      "cardinality" => "zero_or_one",
      "fields" => %{
        "due_at" => scalar(["due_at"], "string", false, nullable: true),
        "timezone" => scalar(["timezone"], "string", false),
        "duration_minutes" => scalar(["duration_minutes"], "integer", false, nullable: true)
      },
      "access_patterns" => shape["relations"]["work_orders"]["access_patterns"]
    }

    shape
    |> Map.put("id", "work-orders/owned-object-v1")
    |> put_in(["shape", "fields", "schedule"], object)
    |> update_in(["relations", "work_orders", "fields"], &Enum.sort(["schedule" | &1]))
    |> put_in(["relations", "work_order_schedule"], relation)
  end

  def object_relation_release do
    {:ok, draft} = ShapeRelease.new(object_relation_shape())
    {:ok, release} = ShapeRelease.approve(draft, approved_by: "synthetic-fixture-author")
    release
  end

  @doc "Valid shared owned-object documents; all documents remain synthetic."
  def object_relation_documents,
    do: object_relation_cases() |> Enum.filter(& &1.valid) |> Enum.map(& &1.document)

  @doc "Shared ownership/presence/type corpus. Rows use due_at, timezone, duration_minutes in that order; invalid parents require errors before child filtering."
  def object_relation_cases do
    missing = %Selecto.Document.Missing{}
    [base | _] = work_orders()

    cases = [
      {"missing", missing, true, [], {false, false, false, false}},
      {"null", nil, true, [], {false, false, false, false}},
      {"empty", %{}, true, [[missing, missing, missing]], {false, true, false, false}},
      {"utc", %{"timezone" => "UTC", "duration_minutes" => 15}, true, [[missing, "UTC", 15]],
       {true, false, false, true}},
      {"other_timezone", %{"timezone" => "America/Denver", "duration_minutes" => 0}, true,
       [[missing, "America/Denver", 0]], {false, false, false, false}},
      {"nullable_due_at", %{"due_at" => nil, "timezone" => "UTC", "duration_minutes" => nil},
       true, [[nil, "UTC", nil]], {true, false, false, false}},
      {"present_due_at", %{"due_at" => "2026-08-26T12:00:00Z"}, true,
       [["2026-08-26T12:00:00Z", missing, missing]], {false, true, false, false}},
      {"scalar", "UTC", false, nil, nil},
      {"array", [], false, nil, nil},
      {"number", 1, false, nil, nil},
      {"boolean", true, false, nil, nil},
      {"wrong_timezone_type", %{"timezone" => 1}, false, nil, nil},
      {"null_timezone", %{"timezone" => nil}, false, nil, nil},
      {"wrong_duration_type", %{"duration_minutes" => "15"}, false, nil, nil}
    ]

    compiled =
      Enum.map(cases, fn {id, value, valid, rows, predicates} ->
        document = Map.put(base, "_id", "object-" <> id)

        document =
          if Selecto.Document.Missing.missing?(value),
            do: Map.delete(document, "schedule"),
            else: Map.put(document, "schedule", value)

        %{
          id: id,
          document: document,
          valid: valid,
          rows: rows,
          predicates: object_predicate_answers(predicates)
        }
      end)

    compiled ++
      [
        %{
          id: "invalid_parent_title",
          document: base |> Map.put("_id", "object-invalid_parent_title") |> Map.delete("title"),
          valid: false,
          rows: nil,
          predicates: nil
        },
        %{
          id: "invalid_parent_variant",
          document:
            base |> Map.put("_id", "object-invalid_parent_variant") |> Map.put("kind", "unknown"),
          valid: false,
          rows: nil,
          predicates: nil
        }
      ]
  end

  @doc "Native-query inputs corresponding to object_relation_cases/0 predicate answers."
  def object_relation_predicates do
    %{
      timezone_eq_utc: %{"op" => "eq", "field" => "timezone", "value" => "UTC"},
      timezone_missing: %{"op" => "missing", "field" => "timezone"},
      timezone_is_null: %{"op" => "is_null", "field" => "timezone"},
      duration_gt_zero: %{"op" => "gt", "field" => "duration_minutes", "value" => 0}
    }
  end

  @doc "Explicit ObjectId root/array identities and nullable reference fields; prior releases are unchanged."
  def object_id_shape do
    object_relation_shape()
    |> Map.put("id", "work-orders/object-id-v1")
    |> put_in(["shape", "fields", "id", "type"], "object_id")
    |> put_in(["relations", "work_order_parts", "fields", "part_id", "type"], "object_id")
    |> put_in(
      ["shape", "fields", "customer_id"],
      scalar(["customer_id"], "object_id", false, nullable: true)
    )
    |> update_in(["relations", "work_orders", "fields"], &Enum.sort(["customer_id" | &1]))
    |> put_in(
      ["relations", "work_order_schedule", "fields", "owner_id"],
      scalar(["owner_id"], "object_id", false, nullable: true)
    )
  end

  def object_id_release do
    {:ok, draft} = ShapeRelease.new(object_id_shape())
    {:ok, release} = ShapeRelease.approve(draft, approved_by: "synthetic-fixture-author")
    release
  end

  @doc "Three synthetic tenants/work orders with canonical tagged identities."
  def object_id_documents do
    work_orders()
    |> Enum.with_index(1)
    |> Enum.map(fn {document, index} ->
      document =
        document
        |> Map.put("_id", object_id(index))
        |> Map.update!("parts", fn parts ->
          Enum.with_index(parts, 1)
          |> Enum.map(fn {part, part_index} ->
            Map.put(part, "part_id", object_id(100 + part_index))
          end)
        end)

      case index do
        1 ->
          document
          |> Map.put("customer_id", object_id(201))
          |> put_in(["schedule", "owner_id"], object_id(301))

        2 ->
          document |> Map.put("customer_id", nil) |> put_in(["schedule", "owner_id"], nil)

        _ ->
          document
      end
    end)
  end

  def object_id_work_orders, do: object_id_documents()

  @doc "Separate root-patch fixture with optional boolean input and existing ObjectId/object refinements."
  def patch_shape do
    object_id_shape()
    |> Map.put("id", "work-orders/root-patches-v1")
    |> put_in(["shape", "fields", "expedited"], scalar(["expedited"], "boolean", false))
    |> update_in(["relations", "work_orders", "fields"], &Enum.sort(["expedited" | &1]))
  end

  def patch_release do
    {:ok, draft} = ShapeRelease.new(patch_shape())
    {:ok, release} = ShapeRelease.approve(draft, approved_by: "synthetic-fixture-author")
    release
  end

  def patch_documents do
    [first, second, third] = object_id_documents()
    [Map.put(first, "expedited", false), Map.put(second, "expedited", true), third]
  end

  @doc "Deterministic explicitly constructed synthetic ObjectId (positive fixture integer)."
  def object_id(number) when is_integer(number) and number >= 0 and number < 1_000_000 do
    hex = number |> Integer.to_string(16) |> String.pad_leading(24, "0")
    {:ok, value} = ObjectId.new(hex)
    value
  end

  @doc "Portable value validity corpus; ordinary strings/maps are never implicitly coerced."
  def object_id_cases do
    valid = %{"$bson" => "object_id", "value" => "abcdef0123456789abcdef01"}

    [
      %{id: "canonical", value: valid, valid: true},
      %{id: "zero", value: object_id(0), valid: true},
      %{id: "raw_hex_string", value: valid["value"], valid: false},
      %{
        id: "uppercase",
        value: Map.put(valid, "value", String.upcase(valid["value"])),
        valid: false
      },
      %{id: "extra_key", value: Map.put(valid, "extra", true), valid: false},
      %{id: "atom_keys", value: %{bson: "object_id", value: valid["value"]}, valid: false},
      %{id: "extended_json", value: %{"$oid" => valid["value"]}, valid: false},
      %{id: "wrong_tag", value: Map.put(valid, "$bson", "binary"), valid: false},
      %{id: "short", value: Map.put(valid, "value", "abcdef"), valid: false},
      %{id: "non_hex", value: Map.put(valid, "value", String.duplicate("g", 24)), valid: false},
      %{id: "number", value: 1, valid: false},
      %{id: "null", value: nil, valid: false},
      %{id: "missing", value: %Selecto.Document.Missing{}, valid: false}
    ]
  end

  defp object_predicate_answers(nil), do: nil

  defp object_predicate_answers({equal, missing, null, positive}),
    do: %{
      timezone_eq_utc: equal,
      timezone_missing: missing,
      timezone_is_null: null,
      duration_gt_zero: positive
    }

  @doc "Separate authored scalar-array grants for root fields and identified child fields."
  def scalar_array_shape do
    aggregate_shape()
    |> Map.put("id", "work-orders/scalar-arrays-v1")
    |> put_in(["shape", "fields", "tags"], scalar_array(["tags"], "string"))
    |> put_in(["shape", "fields", "ratings"], scalar_array(["ratings"], "integer"))
    |> put_in(["shape", "fields", "flags"], scalar_array(["flags"], "boolean"))
    |> update_in(["relations", "work_orders", "fields"], &Enum.sort(&1 ++ ["ratings", "flags"]))
    |> put_in(
      ["relations", "work_order_parts", "fields", "labels"],
      scalar_array(["labels"], "string")
    )
  end

  def scalar_array_release do
    {:ok, draft} = ShapeRelease.new(scalar_array_shape())
    {:ok, release} = ShapeRelease.approve(draft, approved_by: "synthetic-fixture-author")
    release
  end

  def scalar_array_work_orders do
    Enum.map(work_orders(), fn document ->
      document
      |> Map.put("ratings", if(document["_id"] == "wo-1", do: [1, 2, 2], else: []))
      |> Map.put("flags", if(document["_id"] == "wo-1", do: [true, false], else: []))
      |> Map.update!("parts", fn parts ->
        Enum.map(parts, fn part ->
          Map.put(part, "labels", if(part["part_id"] == "part-1", do: ["critical"], else: []))
        end)
      end)
    end)
  end

  @doc "Synthetic membership truth cases shared by native adapter tests; the descriptor bound is 8."
  def scalar_array_cases(type) when type in ~w(string integer boolean) do
    {first, second, wrong} =
      case type do
        "string" -> {"alpha", "beta", 1}
        "integer" -> {1, 2, "1"}
        "boolean" -> {true, false, 1}
      end

    %{
      "contains" => first,
      "contains_any" => [first, second],
      "contains_all" => [first, second],
      "cases" => [
        %{id: "empty", value: [], valid: true, expected: [false, false, false]},
        %{id: "first", value: [first], valid: true, expected: [true, true, false]},
        %{id: "second", value: [second], valid: true, expected: [false, true, false]},
        %{id: "both", value: [first, second], valid: true, expected: [true, true, true]},
        %{id: "duplicates", value: [first, first], valid: true, expected: [true, true, false]},
        %{id: "mixed", value: [first, wrong], valid: false, expected: [false, false, false]},
        %{id: "null_item", value: [first, nil], valid: false, expected: [false, false, false]},
        %{
          id: "over_bound",
          value: List.duplicate(first, 9),
          valid: false,
          expected: [false, false, false]
        },
        %{id: "null", value: nil, valid: false, expected: [false, false, false]},
        %{
          id: "missing",
          value: %Selecto.Document.Missing{},
          valid: false,
          expected: [false, false, false]
        },
        %{id: "container", value: first, valid: false, expected: [false, false, false]}
      ]
    }
  end

  defp scalar_array(path, type) do
    opaque(path, "array")
    |> Map.merge(%{
      "required" => false,
      "nullable" => true,
      "missing" => "preserve",
      "scalar_array" => %{
        "element_type" => type,
        "max_elements" => 8,
        "predicate_ops" => ~w(contains contains_any contains_all)
      }
    })
  end

  defp scalar(path, type, required, opts \\ []) do
    %{
      "path" => path,
      "type" => type,
      "required" => required,
      "nullable" => Keyword.get(opts, :nullable, false),
      "missing" => if(required, do: "reject", else: "preserve"),
      "filterable" => true,
      "sortable" => true,
      "server_managed" => Keyword.get(opts, :server_managed, false)
    }
  end

  defp opaque(path, type),
    do: scalar(path, type, true) |> Map.put("filterable", false) |> Map.put("sortable", false)
end
