defmodule Selecto.DomainContractExportTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain
  alias Selecto.Domain.SchemaV2

  defp relation(table) do
    %{
      "source_table" => table,
      "primary_key" => "id",
      "fields" => ["id", "label", "site_id"],
      "columns" => %{
        "id" => %{"type" => "integer"},
        "label" => %{"type" => "string"},
        "site_id" => %{"type" => "integer"}
      },
      "associations" => %{}
    }
  end

  defp base do
    %{
      "schema_version" => 1,
      "name" => "Synthetic items",
      "source" => relation("contract_items"),
      "schemas" => %{},
      "joins" => %{}
    }
  end

  defp flagged do
    base()
    |> Map.put("require_tenant", 0)
    |> put_in(["source", "columns", "label"], %{
      "type" => "string",
      "hidden" => 1,
      "internal" => 0,
      "nullable" => true,
      "filterable" => 0,
      "selectable" => 1,
      "sortable" => "1",
      "groupable" => 1,
      "detail_selectable" => 1,
      "query_filterable" => 0,
      "aggregatable" => 0,
      "options" => %{
        "number" => 17,
        "fraction" => 1.25,
        "fraction_string" => "1.25",
        "string" => "17",
        "hidden" => "1"
      }
    })
    |> Map.put("components", %{
      "query_params" => 1,
      "filter_choices" => %{
        "label" => %{
          "label" => "Labels",
          "picker_hidden" => 0,
          "choices" => [%{"value" => "A", "label" => "Synthetic"}]
        }
      }
    })
    |> Map.put("writes", %{
      "operations" => %{"update" => %{"enabled" => 1, "bulk" => 0, "require_filter" => 1}},
      "fields" => %{"label" => %{"updatable" => 1, "insertable" => 0, "write_once" => 0}}
    })
  end

  defp export!(domain) do
    assert {:ok, export} = Domain.contract_json(domain)
    export
  end

  test "flag positions hold JSON booleans by the portable truth test" do
    export = export!(flagged())
    label = export["source"]["columns"]["label"]

    assert export["require_tenant"] == false
    assert label["hidden"] == true
    assert label["internal"] == false
    assert label["nullable"] == true
    assert label["filterable"] == false
    assert label["sortable"] == true
    assert label["aggregatable"] == false
    assert export["components"]["query_params"] == true
    assert export["components"]["filter_choices"]["label"]["picker_hidden"] == false

    assert export["writes"]["operations"]["update"] == %{
             "enabled" => true,
             "bulk" => false,
             "require_filter" => true
           }

    assert export["writes"]["fields"]["label"] == %{
             "updatable" => true,
             "insertable" => false,
             "write_once" => false
           }
  end

  test "data positions keep their JSON types" do
    export = export!(flagged())

    assert export["source"]["columns"]["label"]["options"] == %{
             "number" => 17,
             "fraction" => 1.25,
             "fraction_string" => "1.25",
             "string" => "17",
             "hidden" => "1"
           }

    assert SchemaV2.jcs(export) =~ ~s("number":17)
    assert SchemaV2.jcs(export) =~ ~s("string":"17")
  end

  test "a domain written with 0/1 flags exports the same bytes as one written with booleans" do
    booleans =
      flagged()
      |> Map.put("require_tenant", false)
      |> update_in(["source", "columns", "label"], fn column ->
        Map.merge(column, %{
          "hidden" => true,
          "internal" => false,
          "filterable" => false,
          "selectable" => true,
          "sortable" => true,
          "groupable" => true,
          "detail_selectable" => true,
          "query_filterable" => false,
          "aggregatable" => false
        })
      end)
      |> put_in(["components", "query_params"], true)
      |> put_in(["components", "filter_choices", "label", "picker_hidden"], false)
      |> put_in(["writes", "operations", "update"], %{
        "enabled" => true,
        "bulk" => false,
        "require_filter" => true
      })
      |> put_in(["writes", "fields", "label"], %{
        "updatable" => true,
        "insertable" => false,
        "write_once" => false
      })

    assert SchemaV2.jcs(export!(flagged())) == SchemaV2.jcs(export!(booleans))
  end

  test "encode, validate and export again gives the same bytes" do
    bytes = flagged() |> export!() |> SchemaV2.jcs()
    reparsed = Jason.decode!(bytes)

    assert {:ok, _normalized, diagnostics} = Domain.validate(reparsed)
    assert diagnostics.errors == []
    assert reparsed |> export!() |> SchemaV2.jcs() == bytes
  end

  test "an atom-keyed domain exports the same contract as its JSON form" do
    atom_domain = %{
      schema_version: 1,
      name: "Synthetic items",
      source: %{
        source_table: "contract_items",
        primary_key: :id,
        fields: [:id, :label, :site_id],
        columns: %{
          id: %{type: :integer},
          label: %{type: :string, internal: 1},
          site_id: %{type: :integer}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{}
    }

    json_domain =
      base()
      |> put_in(["source", "columns", "label", "internal"], true)
      |> Map.put("writes", %{})

    assert SchemaV2.jcs(export!(atom_domain)) == SchemaV2.jcs(export!(json_domain))
  end

  test "tenant aliases: a null alias beside a present one takes its value" do
    export = export!(base() |> Map.put("tenant_required", nil) |> Map.put("require_tenant", 1))
    assert export["tenant_required"] == true
    assert export["require_tenant"] == true

    export = export!(Map.put(base(), "tenant_required", nil))
    assert export["tenant_required"] == false
  end

  test "action, editor and write-relationship flags, recursively" do
    domain =
      base()
      |> Map.put("actions", %{
        "inspect" => %{
          "prerequisite_column" => 0,
          "inputs" => %{"note" => %{"type" => "string", "required" => 1}}
        }
      })

    export = export!(domain)
    assert export["actions"]["inspect"]["prerequisite_column"] == false
    assert export["actions"]["inspect"]["inputs"]["note"]["required"] == true

    # The flag pass itself, on positions this small domain does not declare.
    nested = %{
      "writes" => %{
        "scope" => %{"tenant" => %{"required" => 1, "field" => "site_id"}},
        "relationships" => %{
          "lines" => %{
            "writable" => 1,
            "delete_missing" => 0,
            "domain" => %{
              "require_tenant" => 1,
              "writes" => %{"fields" => %{"qty" => %{"required" => "0"}}}
            }
          }
        }
      },
      "editors" => %{
        "main" => %{"fields" => [%{"field" => "label", "readonly" => 1, "nullable" => 0}]}
      },
      "detail_actions" => %{"open" => %{"payload" => %{"navigation_enabled" => 1}}},
      "co_domains" => %{"sites" => %{"search" => %{"rank" => 0}}}
    }

    flagged = Selecto.Domain.ContractExport.flags(nested)
    assert flagged["writes"]["scope"]["tenant"] == %{"required" => true, "field" => "site_id"}
    lines = flagged["writes"]["relationships"]["lines"]
    assert lines["writable"] == true
    assert lines["delete_missing"] == false
    assert lines["domain"]["require_tenant"] == true
    assert lines["domain"]["writes"]["fields"]["qty"]["required"] == false

    assert flagged["editors"]["main"]["fields"] == [
             %{"field" => "label", "readonly" => true, "nullable" => false}
           ]

    assert flagged["detail_actions"]["open"]["payload"]["navigation_enabled"] == true
    assert flagged["co_domains"]["sites"]["search"]["rank"] == false
  end

  test "a configured Selecto exports its domain, never the host's required filters" do
    domain = %{
      name: "Synthetic items",
      source: %{
        source_table: "contract_items",
        primary_key: :id,
        fields: [:id, :label],
        columns: %{id: %{type: :integer}, label: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    selecto =
      Selecto.configure(domain, :mock_connection,
        validate: false,
        adapter: Selecto.Verification.QuerySafety.Adapter
      )

    scoped = Selecto.require_tenant_filter(selecto, {"id", 93_271})
    assert Selecto.required_filters(scoped) != []

    unscoped = selecto |> export!() |> SchemaV2.jcs()
    assert scoped |> export!() |> SchemaV2.jcs() == unscoped
    assert unscoped == domain |> export!() |> SchemaV2.jcs()
    refute unscoped =~ "93271"
  end

  test "authored required filters stay in the contract" do
    domain = Map.put(base(), "required_filters", [["eq", "label", "kept"]])
    assert export!(domain)["required_filters"] == [["eq", "label", "kept"]]
  end

  test "a schema 2 document exports its schema 1 form" do
    v2 =
      base()
      |> Map.put("schema_version", 2)
      |> update_in(["source"], &Map.delete(&1, "fields"))

    export = export!(v2)
    assert export["schema_version"] == 1
    assert export["domain_fingerprint"] == SchemaV2.fingerprint(v2)
  end

  test "the export is a fresh value and refuses what is not a JSON contract" do
    assert {:error, %{errors: [%{code: :ambiguous_domain_keys}]}} =
             Domain.contract_json(Map.put(base(), :name, "Twice"))

    assert {:error, %{errors: [%{code: :invalid_contract_value, path: ["source", "hook"]}]}} =
             Domain.contract_json(put_in(base(), ["source", "hook"], fn -> :ok end))

    assert {:error, %{errors: [_ | _]}} = Domain.contract_json(Map.delete(base(), "source"))
    assert {:error, _diagnostics} = Domain.contract_json(:not_a_domain)
  end

  test "contract_keys: the recognised top-level sections; the other levels admit any key" do
    keys = Domain.contract_keys()

    assert keys.top_level ==
             Selecto.Domain.Sections.sections() |> Map.values() |> List.flatten() |> Enum.sort()

    assert keys.top_level == Enum.sort(keys.top_level)

    for key <- ~w(associations jsonb_schemas require_tenant tenant_required domain_data events
                  json_schemas source writes),
        do: assert(key in keys.top_level)

    assert Map.take(keys, [:relation, :association, :join, :through, :join_types]) ==
             %{relation: :any, association: :any, join: :any, through: :any, join_types: :any}

    # Every recognised section parses without an unknown-section warning.
    {:ok, _normalized, diagnostics} = Domain.normalize(Map.new(keys.top_level, &{&1, nil}))
    assert diagnostics.unknown_sections == []
  end

  test "the parser is unchanged: validate/1 still refuses 0/1 write flags" do
    assert {:error, diagnostics} = Domain.validate(flagged())
    assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_write_operation_option))
    assert {:ok, _export} = Domain.contract_json(flagged())
  end
end
