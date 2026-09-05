defmodule Selecto.Document.Fixtures do
  @moduledoc "Independently authored synthetic work orders for the document reference slice."
  alias Selecto.Document.ShapeRelease

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
