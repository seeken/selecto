defmodule Selecto.SharedWriteContractTest do
  use ExUnit.Case, async: true
  alias Selecto.Write.SharedContract

  defp domain do
    %{
      name: "Notes",
      source: %{
        source_table: "notes",
        primary_key: :id,
        fields: [:id, :name, :owner_id, :version, :created_at],
        redact_fields: [],
        associations: %{},
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          owner_id: %{type: :string},
          version: %{type: :integer},
          created_at: %{type: :utc_datetime}
        }
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true},
          delete: %{enabled: true}
        },
        fields: %{id: %{insertable: true}, name: %{insertable: true, updatable: true}},
        host_bound_fields: %{owner_id: %{mode: :owner, source: ["context", "user_id"]}},
        row_revision: %{column: "version", required: true}
      }
    }
  end

  test "malformed shared declarations fail closed without raising" do
    valid = domain()
    assert SharedContract.errors(valid) == []

    for {key, value} <- [
          row_revision: nil,
          row_revision: %{column: "missing"},
          row_revision: %{column: "version", columns: ["name"]},
          row_revision: %{column: "version", required: "false"},
          host_bound_fields: %{owner_id: %{mode: :owner, source: ["request", "user_id"]}},
          host_bound_fields: %{name: %{mode: :created_at}},
          unique_keys: %{key: ["missing"]}
        ] do
      refute SharedContract.errors(put_in(valid, [:writes, key], value)) == []
    end
  end

  test "DuckDB declarations refuse even an empty binding map and SQL Server refuses cleanly" do
    operation =
      SelectoUpdato.Operation.new(domain()) |> SelectoUpdato.Update.update(%{name: "Next"})

    assert {:error,
            %{
              type: :write_capability_missing,
              details: %{missing: [:row_revision, :host_bound_fields]}
            }} = SharedContract.preflight(operation, :duckdb)

    assert {:error, %{type: :unsupported_feature}} =
             SharedContract.preflight(operation, :sqlserver)

    empty = %{operation | domain: %{domain() | writes: %{host_bound_fields: %{}}}}

    assert {:error, %{details: %{missing: [:host_bound_fields]}}} =
             SharedContract.preflight(empty, :duckdb)
  end

  test "caller host assignments refuse before trusted owner scope and fills" do
    domain = domain() |> update_in([:writes], &Map.delete(&1, :row_revision))

    operation =
      SelectoUpdato.Operation.new(domain)
      |> SelectoUpdato.Update.update(%{name: "Next"})
      |> SelectoUpdato.Operation.filter({"id", 1})

    spoof = %{operation | changes: %{owner_id: "alice"}}
    assert {:error, %{type: :host_bound_field}} = SharedContract.preflight(spoof, :sqlite)

    assert {:ok, command, _} =
             SelectoUpdato.PortableCommand.compile(operation, context: %{user_id: "alice"})

    assert "owner_id" in command.metadata.tenant_fields

    assert command.metadata.post_image.predicate ==
             {:eq, {:field, "owner_id"}, {:literal, "alice"}}
  end

  test "revision tokens bind backend, domain, identity and revision while normalizing key spelling" do
    domain = domain()
    first = Selecto.RowRevision.token(domain, :sqlite, %{id: 1, version: 2})
    assert first == Selecto.RowRevision.token(domain, :sqlite, %{"id" => 1, "version" => 2})

    for {backend, domain, values} <- [
          {:sqlite, domain, %{id: 2, version: 2}},
          {:sqlite, domain, %{id: 1, version: 3}},
          {:postgresql, domain, %{id: 1, version: 2}},
          {:sqlite, %{domain | name: "Other"}, %{id: 1, version: 2}}
        ] do
      refute first == Selecto.RowRevision.token(domain, backend, values)
    end
  end

  test "trusted owner context must be present and nonempty" do
    domain = domain() |> update_in([:writes], &Map.delete(&1, :row_revision))

    operation =
      SelectoUpdato.Operation.new(domain)
      |> SelectoUpdato.Update.update(%{name: "Next"})
      |> SelectoUpdato.Operation.filter({"id", 1})

    for context <- [%{}, %{user_id: ""}, %{user_id: nil}, %{user_id: []}] do
      assert {:error, %{type: :missing_host_context}} =
               SelectoUpdato.PortableCommand.compile(operation, context: context)
    end
  end

  test "database timestamps remain pending for submitted-literal validators" do
    domain =
      domain()
      |> update_in([:writes], &Map.delete(&1, :row_revision))
      |> put_in([:writes, :host_bound_fields], %{created_at: %{mode: :created_at}})
      |> put_in([:writes, :fields, :created_at], %{validators: [:required]})

    operation =
      SelectoUpdato.Operation.new(domain) |> SelectoUpdato.Insert.insert(%{id: 1, name: "Next"})

    assert {:error, %{type: :required_data_rule_pending}} =
             SelectoUpdato.PortableCommand.compile(operation)
  end

  test "revision reads preserve aggregate grain" do
    query = %Selecto{domain: domain(), set: %{group_by: [], selected: [{:count, "id"}]}}
    result = {:ok, {[[2]], ["count"], []}, %{}}

    assert Selecto.RowRevision.read(query, [], fn received, _ ->
             assert received.set.selected == query.set.selected
             result
           end) == result
  end
end
