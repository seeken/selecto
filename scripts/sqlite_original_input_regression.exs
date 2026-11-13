# Public Updato proof; load the selected core, Updato and SQLite dependencies.
ExUnit.start()
{:ok, _} = Application.ensure_all_started(:selecto)
{:ok, _} = Application.ensure_all_started(:selecto_db_sqlite)

defmodule SelectoUpdato.NativeSQLiteOriginalInputTest do
  use ExUnit.Case, async: true
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    sql(db, "CREATE TABLE accounts(id INTEGER PRIMARY KEY)")
    sql(db, "INSERT INTO accounts VALUES(42)")

    sql(
      db,
      "CREATE TABLE items(id INTEGER PRIMARY KEY,quantity NUMERIC,tenant_id INTEGER,name TEXT,account_id INTEGER REFERENCES accounts(id))"
    )

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

  test "engine-injected tenant remains absent from submitted INPUT", %{db: db} do
    authored = domain("text")
    authored = put_in(authored, [:writes, :fields, :tenant_id], %{insertable: true})

    authored =
      put_in(authored, [:writes, :scope], %{tenant: %{required: true, field: :tenant_id}})

    authored =
      put_in(authored, [:rules, :definitions, :tenant], %{
        version: 1,
        test: %{op: "presence.absent"}
      })

    authored =
      put_in(authored, [:rules, :bindings, :tenant], %{
        subject: %{scope: :input, path: [:tenant_id]},
        operations: [:insert],
        rule: %{id: :tenant, version: 1}
      })

    op = authored |> SelectoUpdato.new() |> SelectoUpdato.insert(%{quantity: "0.1"})

    assert {:ok, _} =
             SelectoUpdato.execute(op, %Selecto{adapter: Adapter, connection: db},
               context: %{tenant_id: 7}
             )

    assert sql(db, "SELECT tenant_id FROM items") == [[7]]
  end

  test "native input is checked before text-case formatting in preview and execution", %{db: db} do
    authored = field_domain(:name, %{op: "value.eq", value: "abc"})
    authored = put_in(authored, [:source, :columns, :name, :text_case], :uppercase)
    op = authored |> SelectoUpdato.new() |> SelectoUpdato.insert(%{quantity: "0.1", name: "abc"})
    target = %Selecto{adapter: Adapter, connection: db}
    assert {:ok, _} = SelectoUpdato.preview(op, target)
    assert sql(db, "SELECT * FROM items") == []
    assert {:ok, _} = SelectoUpdato.execute(op, target)
    assert sql(db, "SELECT name FROM items") == [["ABC"]]

    rejected = %{op | attrs: %{quantity: "0.1", name: "ABC"}}

    assert {:error, %{details: %{code: :data_rule_failed}}} =
             SelectoUpdato.execute(rejected, target)

    assert sql(db, "SELECT name FROM items") == [["ABC"]]
  end

  test "INPUT empty-to-null is applied once before native candidate projection", %{db: db} do
    authored = field_domain(:name, %{op: "value.eq", value: nil})

    authored =
      put_in(authored, [:rules, :normalizers, :empty], %{
        version: 1,
        steps: [%{op: "text.empty_to_null"}]
      })

    authored =
      put_in(authored, [:rules, :bindings, :field, :normalizer], %{id: :empty, version: 1})

    authored =
      put_in(authored, [:rules, :bindings, :stored_name], %{
        subject: %{scope: :candidate, path: [:name]},
        operations: [:insert],
        rule: %{id: :field, version: 1}
      })

    op = authored |> SelectoUpdato.new() |> SelectoUpdato.insert(%{quantity: "0.1", name: ""})
    assert {:ok, _} = SelectoUpdato.execute(op, %Selecto{adapter: Adapter, connection: db})
    assert sql(db, "SELECT name,typeof(name) FROM items") == [[nil, "null"]]
  end

  test "trusted foreign-key context is absent from original INPUT", %{db: db} do
    authored = field_domain(:account_id, %{op: "presence.absent"})

    authored =
      put_in(authored, [:writes, :constraints], %{
        foreign_keys: %{
          account_id: %{
            source: {:context, :account_id},
            references: %{relation: "accounts", field: :id},
            required: true
          }
        }
      })

    op = authored |> SelectoUpdato.new() |> SelectoUpdato.insert(%{quantity: "0.1"})

    assert {:ok, _} =
             SelectoUpdato.execute(op, %Selecto{adapter: Adapter, connection: db},
               context: %{account_id: 42}
             )

    assert sql(db, "SELECT account_id FROM items") == [[42]]
  end

  defp field_domain(field, test) do
    authored = domain("text")

    authored =
      put_in(authored, [:source, :fields], [:id, :quantity, :tenant_id, :name, :account_id])

    authored = put_in(authored, [:source, :columns, :name], %{type: :string})
    authored = put_in(authored, [:source, :columns, :account_id], %{type: :integer})
    authored = put_in(authored, [:writes, :fields, field], %{insertable: true})
    authored = put_in(authored, [:rules, :definitions, :field], %{version: 1, test: test})

    put_in(authored, [:rules, :bindings, :field], %{
      subject: %{scope: :input, path: [field]},
      operations: [:insert],
      rule: %{id: :field, version: 1}
    })
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
