defmodule SelectoUpdato.PortableSurfaceTest do
  use ExUnit.Case, async: true

  @retired_operations [:insert_all, :upsert_all, :insert_from_query, :soft_delete]
  @retired_modules [
    SelectoUpdato.ConstraintEngine,
    SelectoUpdato.Hooks,
    SelectoUpdato.Nested.Strategy,
    SelectoUpdato.WritePlan,
    SelectoUpdato.WriteState,
    SelectoUpdato.WriteValidator
  ]

  test "exports only the four portable operation builders" do
    assert Code.ensure_loaded?(SelectoUpdato)
    assert Code.ensure_loaded?(SelectoUpdato.Insert)
    assert Code.ensure_loaded?(SelectoUpdato.Upsert)
    assert Code.ensure_loaded?(SelectoUpdato.Delete)
    assert Code.ensure_loaded?(SelectoUpdato.Operation)

    assert function_exported?(SelectoUpdato, :insert, 2)
    assert function_exported?(SelectoUpdato, :update, 2)
    assert function_exported?(SelectoUpdato, :upsert, 2)
    assert function_exported?(SelectoUpdato, :delete, 1)

    refute function_exported?(SelectoUpdato.Insert, :insert_all, 2)
    refute function_exported?(SelectoUpdato.Insert, :insert_from_query, 2)
    refute function_exported?(SelectoUpdato.Upsert, :upsert_all, 2)
    refute function_exported?(SelectoUpdato.Delete, :soft_delete, 1)
    refute function_exported?(SelectoUpdato.Operation, :with_changeset, 2)
  end

  test "does not ship the retired persistence subsystem" do
    for module <- @retired_modules do
      refute Code.ensure_loaded?(module), "retired module still loads: #{inspect(module)}"
    end
  end

  test "rejects retired operation declarations" do
    for operation <- @retired_operations do
      domain =
        base_domain()
        |> put_in([:writes, :operations], %{operation => %{enabled: true}})

      assert {:error, %SelectoUpdato.Error{details: %{errors: errors}}} =
               SelectoUpdato.validate_domain(domain)

      assert {[:writes, :operations, operation], "is not a supported operation"} in errors
    end
  end

  test "accepts write policy colocated with source columns" do
    domain = %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name],
        columns: %{
          id: %{type: :integer, write: %{server_managed: true}},
          name: %{
            type: :string,
            write: %{insertable: true, required_on: [:insert]}
          }
        },
        associations: %{}
      },
      schemas: %{},
      writes: %{operations: %{insert: %{enabled: true}}}
    }

    operation = domain |> SelectoUpdato.new() |> SelectoUpdato.insert(%{name: "Widget"})

    assert {:ok, command, %{}} = SelectoUpdato.PortableCommand.compile(operation)
    assert command.operation == :insert
    assert command.assignments == [%{field: "name", value: {:literal, "Widget"}}]
  end

  test "legacy Ecto-shaped sources fail through contract validation rather than crashing" do
    domain = %{
      source: Example.Schema,
      writes: %{fields: %{name: %{insertable: "yes"}}}
    }

    assert {:error, %SelectoUpdato.Error{type: :invalid_operation}} =
             SelectoUpdato.WriteContract.validate_writes_shape(domain)
  end

  test "domains without explicit write operations and fields fail closed" do
    domain =
      base_domain()
      |> Map.delete(:writes)
      |> Map.put(:writable, [:name])
      |> Map.put(:required_on_insert, [:name])

    refute SelectoUpdato.WriteContract.operation_supported?(domain, :insert)
    assert SelectoUpdato.WriteContract.writable_fields(domain) == []
    assert SelectoUpdato.WriteContract.required_fields(domain, :insert) == []
  end

  test "rejects duplicate colocated and writes.fields declarations" do
    domain =
      base_domain()
      |> put_in([:source, :columns, :name, :write], %{insertable: true})

    operation = domain |> SelectoUpdato.new() |> SelectoUpdato.insert(%{name: "Widget"})

    assert {:error, %SelectoUpdato.Error{type: :invalid_domain, details: %{errors: errors}}} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert Enum.any?(errors, &(&1.code == :duplicate_write_authoring))
  end

  defp base_domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name],
        columns: %{id: %{type: :integer}, name: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: %{name: %{insertable: true}}
      }
    }
  end
end
