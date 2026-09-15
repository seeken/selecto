defmodule Selecto.DomainImportsTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain

  test "validates and projects a governed import contract" do
    assert {:ok, normalized, diagnostics} = Domain.validate(import_domain())
    assert diagnostics.errors == []
    assert :imports in normalized.sections.canonical

    projection = Domain.project(normalized, :import)

    assert projection.projection == :import
    refute Map.has_key?(projection, :extensions)
    refute Map.has_key?(projection, :domain_data)
    assert projection.imports.contract_version == 1
    assert projection.imports.fields.vin.write_on == [:insert, :update]
    assert projection.imports.fields.id.match_only
    refute Map.has_key?(projection.imports.fields.client_id, :trusted_provider)

    assert projection.imports.actions.record_odometer.label == "Record odometer"

    assert projection.imports.actions.record_odometer.inputs.miles == %{
             sources: [:column],
             header_aliases: ["Odometer"],
             type: :number,
             label: "Miles",
             required: true
           }
  end

  test "rejects imports without governed write authority or valid cross-references" do
    domain =
      import_domain()
      |> put_in([:imports, :fields, :description], %{sources: [:column]})
      |> put_in([:imports, :fields, :missing], %{sources: [:column], match_only: true})
      |> put_in([:imports, :actions, :missing_action], %{inputs: %{value: %{sources: [:column]}}})
      |> put_in([:imports, :key_sets, Access.at(0), :fields], [:unknown])

    assert {:error, diagnostics} = Domain.validate(domain)
    codes = Enum.map(diagnostics.errors, & &1.code)

    assert :import_field_not_write_enabled in codes
    assert :import_field_not_found in codes
    assert :import_action_not_found in codes
    assert :import_key_field_not_found in codes
  end

  test "requires canonical action input maps" do
    domain = put_in(import_domain(), [:actions, :record_odometer, :inputs], [%{id: :miles}])

    assert {:error, diagnostics} = Domain.validate(domain)
    assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_action_inputs))
  end

  test "rejects unsafe matching decisions and undeclared required action inputs" do
    domain =
      import_domain()
      |> put_in([:imports, :actions, :record_odometer, :inputs], %{})
      |> put_in([:imports, :key_sets, Access.at(0), :allowed_on_match], [:insert])

    assert {:error, diagnostics} = Domain.validate(domain)
    codes = Enum.map(diagnostics.errors, & &1.code)

    assert :required_import_action_input_missing in codes
    assert :invalid_import_enum_list in codes
  end

  defp import_domain do
    %{
      schema_version: 1,
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
          client_id: %{insertable: true},
          vin: %{insertable: true, updatable: true}
        }
      },
      actions: %{
        record_odometer: %{
          label: "Record odometer",
          inputs: %{
            miles: %{label: "Miles", type: :number, required: true},
            read_date: %{type: :date, required: false}
          }
        }
      },
      imports: %{
        contract_version: 1,
        enabled: true,
        field_policy: :declared_only,
        fields: %{
          id: %{sources: [:column], match_only: true},
          client_id: %{sources: [:trusted], trusted_provider: :current_client_id},
          vin: %{
            sources: [:column],
            header_aliases: ["VIN"],
            transforms: [:trim, :uppercase]
          }
        },
        actions: %{
          record_odometer: %{
            inputs: %{
              miles: %{sources: [:column], header_aliases: ["Odometer"]},
              read_date: %{sources: [:static]}
            }
          }
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
