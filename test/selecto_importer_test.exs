defmodule Selecto.ImporterTest do
  use ExUnit.Case, async: true

  alias Selecto.Importer

  test "inspects quoted CSV, normalizes governed mappings, and previews insert/update rows" do
    assert {:ok, importer} = Importer.new(domain())

    csv = "VIN,Odometer,Description\n abc-1 ,1200,Existing\n\"new,2\",,New unit\n"
    assert {:ok, inspection} = Importer.inspect_csv(importer, csv)
    assert inspection.row_count == 2
    assert Enum.map(inspection.columns, & &1.id) == ["c1", "c2", "c3"]
    assert get_in(inspection.rows, [Access.at(1), :values, "c1"]) == "new,2"

    config = %{
      domain_fingerprint: Importer.domain_fingerprint(importer),
      mappings: [
        %{
          target: "vin",
          source: %{kind: "column", column_id: "c1"},
          transforms: ["trim", "uppercase"]
        },
        %{target: "description", source: %{kind: "column", column_id: "c3"}},
        %{target: "client_id", source: %{kind: "trusted"}}
      ],
      actions: [
        %{
          action: "record_odometer",
          inputs: %{
            "miles" => %{source: %{kind: "column", column_id: "c2"}, blank_policy: "omit"}
          }
        }
      ],
      match: %{key_set: "vin"},
      idempotency: %{mode: "source_row"}
    }

    resolver = fn
      %{"vin" => "ABC-1"}, _key_set, _row -> %{matches: [%{"id" => 9}]}
      _key, _key_set, _row -> %{matches: []}
    end

    assert {:ok, preview} =
             Importer.preview_rows(importer, inspection, config,
               key_resolver: resolver,
               trusted_values: %{"current_client_id" => 44}
             )

    [existing, new] = preview.rows
    assert existing.decision == "update"
    assert existing.write.filters == [%{field: "id", op: "eq", value: 9}]
    refute Map.has_key?(existing.assignments, "client_id")

    assert existing.actions == [
             %{action: "record_odometer", inputs: %{"miles" => "1200"}, target: %{ids: [9]}}
           ]

    assert new.decision == "error"
    assert Enum.any?(new.errors, &(&1.code == :import_action_requires_match))
  end

  test "configuration validation rejects unknown nested settings" do
    assert {:ok, importer} = Importer.new(domain())
    assert {:ok, inspection} = Importer.inspect_csv(importer, "VIN\nabc-1\n")

    configuration = %{
      mappings: [
        %{
          target: "vin",
          source: %{kind: "column", column_id: "c1", unexpected: true}
        }
      ],
      match: %{key_set: "vin"}
    }

    assert {:error, %{details: %{code: :invalid_import_configuration}}} =
             Importer.normalize_configuration(importer, configuration,
               columns: inspection.columns
             )
  end

  test "CSV inspection rejects invalid UTF-8 before parsing and hashes valid Unicode bytes" do
    assert {:ok, importer} = Importer.new(domain())
    bytes = <<"VIN,Name\nA,Caf", 0xC3, 0xA9, "\n">>
    assert {:ok, inspection} = Importer.inspect_csv(importer, bytes)
    assert get_in(inspection.rows, [Access.at(0), :values, "c2"]) == "Café"

    assert inspection.sha256 ==
             "sha256:" <> Base.encode16(:crypto.hash(:sha256, "VIN,Name\nA,Café\n"), case: :lower)

    assert {:error, %{details: %{code: :invalid_import_file}}} =
             Importer.inspect_csv(importer, <<"VIN,Name\nA,", 0xFF, "\n">>)

    assert {:error, %{details: %{code: :import_parser_error}}} =
             Importer.inspect_csv(importer, "VIN,Name\n\"BAD,Name\n")
  end

  test "CSV inspection recognizes CRLF record separators" do
    assert {:ok, importer} = Importer.new(domain())
    assert {:ok, inspection} = Importer.inspect_csv(importer, "VIN,Name\r\nA,Truck\r\n")
    assert Enum.map(inspection.columns, & &1.label) == ["VIN", "Name"]
    assert inspection.row_count == 1
    assert hd(inspection.rows).values == %{"c1" => "A", "c2" => "Truck"}
  end

  defp domain do
    %{
      schema_version: 1,
      domain_fingerprint: "sha256:equipment-v1",
      name: :equipment,
      source: %{
        source_table: "equipment",
        primary_key: :id,
        fields: [:id, :client_id, :vin, :description],
        columns: %{
          id: %{type: :integer},
          client_id: %{type: :integer},
          vin: %{type: :string},
          description: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{insert: %{enabled: true}, update: %{enabled: true}},
        fields: %{
          client_id: %{insertable: true, required: true},
          vin: %{insertable: true, updatable: true},
          description: %{insertable: true, updatable: true}
        }
      },
      actions: %{
        record_odometer: %{
          label: "Record odometer",
          inputs: %{miles: %{label: "Miles", type: :number, required: false}}
        }
      },
      imports: %{
        contract_version: 1,
        enabled: true,
        field_policy: :declared_only,
        fields: %{
          client_id: %{sources: [:trusted], trusted_provider: :current_client_id},
          vin: %{sources: [:column], transforms: [:trim, :uppercase]},
          description: %{sources: [:column]}
        },
        actions: %{
          record_odometer: %{inputs: %{miles: %{sources: [:column], blank_policy: :omit}}}
        },
        key_sets: [
          %{
            id: :vin,
            fields: [:vin],
            cardinality: :zero_or_one,
            allowed_on_match: [:update, :skip, :error],
            allowed_on_missing: [:insert, :skip, :error],
            default_on_match: :update,
            default_on_missing: :insert
          }
        ],
        idempotency: %{supported: true}
      }
    }
  end
end
