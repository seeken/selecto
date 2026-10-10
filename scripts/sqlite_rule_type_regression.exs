# Public Updato proof; load the selected core, Updato and SQLite dependencies.
ExUnit.start()
{:ok, _} = Application.ensure_all_started(:selecto_updato)
{:ok, _} = Application.ensure_all_started(:selecto_db_sqlite)

defmodule Selecto.Rule.NativeSQLiteTypeTest do
  use ExUnit.Case, async: true
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY,quantity NUMERIC,tenant_id INTEGER)")
    on_exit(fn -> Adapter.disconnect(db) end)
    %{db: db}
  end

  test "original INPUT text and actual stored NUMERIC candidate keep distinct kinds", %{db: db} do
    authored = domain("text")
    assert {:ok, _} = insert(authored, db)
    assert sql(db, "SELECT quantity,typeof(quantity) FROM items") == [[0.1, "real"]]
  end

  test "numeric text is not decimal INPUT even when SQLite would store it numerically", %{db: db} do
    assert {:error, %{details: %{code: :data_rule_failed}}} = insert(domain("decimal"), db)
    assert sql(db, "SELECT * FROM items") == []
  end

  defp insert(authored, db) do
    authored
    |> SelectoUpdato.new()
    |> SelectoUpdato.insert(%{quantity: "0.1"})
    |> SelectoUpdato.execute(%Selecto{adapter: Adapter, connection: db})
  end

  defp domain(input_type) do
    %{
      name: "Native type kinds",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :quantity, :tenant_id],
        columns: %{
          id: %{type: :integer},
          quantity: %{type: :decimal},
          tenant_id: %{type: :integer}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{operations: %{insert: %{enabled: true}}, fields: %{quantity: %{insertable: true}}},
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{
          raw: %{version: 1, test: %{op: "type.is", type: input_type}},
          stored: %{version: 1, test: %{op: "type.is", type: "decimal"}}
        },
        normalizers: %{},
        bindings: %{
          raw: %{
            subject: %{scope: :input, path: [:quantity]},
            operations: [:insert],
            rule: %{id: :raw, version: 1}
          },
          stored: %{
            subject: %{scope: :candidate, path: [:quantity]},
            operations: [:insert],
            rule: %{id: :stored, version: 1}
          }
        }
      }
    }
  end

  defp sql(db, statement) do
    {:ok, result} = Adapter.execute(db, statement, [], [])
    result.rows
  end
end
