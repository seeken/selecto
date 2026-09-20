defmodule Selecto.ValuesRelationTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain

  test "values-backed schema joins compile a bound CTE in declared field order" do
    assert {:ok, _, _} = Domain.validate(domain())

    selecto =
      domain()
      |> Selecto.configure(:mock_connection)
      |> Selecto.select(["id", "status.name"])

    {sql, _aliases, params} = Selecto.gen_sql(selecto, [])
    assert sql =~ ~r/WITH .*__selecto_values_status.* AS \(SELECT /s
    assert sql =~ ~r/AS id.*AS name.*UNION ALL/s
    assert sql =~ ~r/join .*__selecto_values_status/s
    assert params == ["A", "Active", "P", "Pending"]
  end

  test "values rows reject missing, unknown, and nonscalar fields" do
    for row <- [%{id: "A"}, %{id: "A", name: "Active", extra: 1}, %{id: "A", name: []}] do
      invalid = put_in(domain(), [:schemas, :status, :values], [row])
      assert {:error, diagnostics} = Domain.validate(invalid)
      assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_relation_values_row))
    end

    invalid = put_in(domain(), [:schemas, :status, :source_table], "statuses")
    assert {:error, diagnostics} = Domain.validate(invalid)
    assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_relation_source))

    invalid = put_in(domain(), [:schemas, :status, :fields], [%{bad: :field}])
    assert {:error, diagnostics} = Domain.validate(invalid)
    assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_relation_values))
  end

  test "star dimension fallback requires matching string types and an explicit mode" do
    valid =
      put_in(domain(), [:joins, :status], %{
        type: :star_dimension,
        display_field: :name,
        display_fallback: :dimension_key
      })

    assert {:ok, _, _} = Domain.validate(valid)

    invalid = put_in(valid, [:schemas, :status, :columns, :name, :type], :integer)
    assert {:error, diagnostics} = Domain.validate(invalid)
    assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_display_fallback))

    invalid = put_in(valid, [:joins, :status, :type], :left)
    assert {:error, diagnostics} = Domain.validate(invalid)
    assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_display_fallback))
  end

  test "one-to-one values association publishes labeled owner foreign-key options" do
    assert {:ok, normalized, _} = Domain.validate(domain())

    assert Domain.values_foreign_keys(domain()) == %{
             "status_id" => %{
               association: "status",
               display_name: "status",
               value_field: "id",
               values: ["A", "P"]
             }
           }

    owner = normalized.source.columns.status_id

    assert owner.foreign_key == %{
             kind: :values,
             association: "status",
             value_field: "id",
             label_field: "id"
           }

    assert owner.options == [%{value: "A", label: "A"}, %{value: "P", label: "P"}]

    bad = put_in(domain(), [:schemas, :status, :values, Access.at(0), :id], nil)
    assert {:error, diagnostics} = Domain.validate(bad)
    assert Enum.any?(diagnostics.errors, &(&1.code == :null_values_foreign_key))
  end

  test "values-backed lookup executes against an in-memory SQLite table" do
    assert {:ok, connection} = SelectoDBSQLite.Adapter.connect(database: ":memory:")

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               connection,
               "CREATE TABLE items (id INTEGER, status_id TEXT)",
               [],
               []
             )

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               connection,
               "INSERT INTO items VALUES (1, 'A'), (2, 'P')",
               [],
               []
             )

    selecto =
      domain()
      |> Selecto.configure(:mock_connection)
      |> Map.put(:adapter, SelectoDBSQLite.Adapter)
      |> Selecto.select(["id", "status.name"])

    {sql, _aliases, params} = Selecto.gen_sql(selecto, [])
    assert {:ok, %{rows: rows}} = SelectoDBSQLite.Adapter.execute(connection, sql, params, [])
    assert rows == [[1, "Active"], [2, "Pending"]]
  end

  test "values lookup applies declared text_case to the owner join key" do
    assert {:ok, connection} = SelectoDBSQLite.Adapter.connect(database: ":memory:")

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               connection,
               "CREATE TABLE items (id INTEGER, status_id TEXT)",
               [],
               []
             )

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               connection,
               "INSERT INTO items VALUES (1, 'a')",
               [],
               []
             )

    authored = put_in(domain(), [:source, :columns, :status_id, :text_case], :uppercase)

    selecto =
      authored
      |> Selecto.configure(:mock_connection)
      |> Map.put(:adapter, SelectoDBSQLite.Adapter)
      |> Selecto.select(["id", "status.name"])

    {sql, _aliases, params} = Selecto.gen_sql(selecto, [])
    assert sql =~ "UPPER(selecto_root.status_id)"

    assert {:ok, %{rows: [[1, "Active"]]}} =
             SelectoDBSQLite.Adapter.execute(connection, sql, params, [])
  end

  defp domain do
    %{
      schema_version: 1,
      name: :items,
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :status_id],
        columns: %{id: %{type: :integer}, status_id: %{type: :string}},
        associations: %{
          status: %{
            queryable: :status,
            field: :status,
            owner_key: :status_id,
            related_key: :id,
            cardinality: :one
          }
        }
      },
      schemas: %{
        status: %{
          primary_key: :id,
          fields: [:id, :name],
          columns: %{id: %{type: :string}, name: %{type: :string}},
          values: [%{id: "A", name: "Active"}, %{id: "P", name: "Pending"}],
          associations: %{}
        }
      },
      joins: %{status: %{type: :left}}
    }
  end
end
