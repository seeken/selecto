defmodule Selecto.SQLiteValuePortsTest do
  use ExUnit.Case, async: true

  defmodule Dialect do
    def render_computed_value(
          %Selecto.Dialect.ComputedValue{
            operation: :cast,
            expression: expression,
            type: "integer"
          },
          _query
        ),
        do: {:ok, ["CAST(", expression, " AS INTEGER)"]}

    def render_computed_value(
          %Selecto.Dialect.ComputedValue{operation: :divide, expression: [left, right]},
          _query
        ),
        do: {:ok, ["(CAST(", left, " AS REAL) / CAST(", right, " AS REAL))"]}

    def render_collection_operation(
          %Selecto.Dialect.Collection.Operation{operation: :unnest, column: column},
          _query
        ),
        do: {:ok, ["json_each(", column, ")"]}

    def render_table_function_join(
          %Selecto.Dialect.TableFunction.Join{source_sql: source, alias: name},
          _query
        ),
        do: {:ok, [" CROSS JOIN ", source, " AS ", name]}

    def render_json_contains(
          %Selecto.Dialect.Json.Contains{column: column, table_alias: table, value: value},
          _query
        ) do
      [{key, expected}] = Map.to_list(value)

      {:ok,
       [
         "EXISTS (SELECT 1 FROM json_each(",
         table,
         ".",
         column,
         ") doc WHERE doc.key = ",
         {:param, key},
         " AND doc.value = ",
         {:param, expected},
         ")"
       ]}
    end
  end

  defmodule Adapter do
    def name, do: :sqlite
    def dialect, do: Selecto.SQLiteValuePortsTest.Dialect
    defdelegate connect(connection), to: SelectoDBSQLite.Adapter
    defdelegate placeholder(index), to: SelectoDBSQLite.Adapter
    defdelegate quote_identifier(name), to: SelectoDBSQLite.Adapter
    def supports?(_feature), do: true
  end

  setup do
    assert {:ok, connection} = Exqlite.Sqlite3.open(":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(connection) end)
    assert :ok = Exqlite.Sqlite3.execute(connection, "PRAGMA temp_store=MEMORY")

    assert :ok =
             Exqlite.Sqlite3.execute(
               connection,
               "CREATE TABLE items(id INTEGER, total NUMERIC, payload TEXT)"
             )

    assert :ok =
             Exqlite.Sqlite3.execute(
               connection,
               ~s|INSERT INTO items VALUES (1,5,'["b","a"]'),(2,10,'{"q": "bound"}')|
             )

    domain = %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :total, :payload, :half],
        columns: %{
          id: %{type: :integer},
          total: %{type: :decimal},
          payload: %{type: :json},
          half: %{
            type: :decimal,
            computed: %{
              kind: :expression,
              expression: ["divide", ["field", "total"], ["literal", 2]]
            }
          }
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    %{query: Selecto.configure(domain, connection, adapter: Adapter, validate: false)}
  end

  test "decimal division reaches the dialect before integer division can discard its fraction", %{
    query: query
  } do
    query = query |> Selecto.select(["half"]) |> Selecto.filter({"id", 1})
    assert {sql, [2, 1]} = Selecto.to_sql(query)
    assert sql =~ "AS REAL) / CAST("
    assert rows(query) == [[2.5]]
  end

  test "SQLite unnest ordinality uses one-based json_each keys for select, filter, and sort", %{
    query: query
  } do
    query =
      query
      |> Selecto.unnest("payload", as: "tag_rows", ordinality: "position")
      |> Selecto.select(["tag_rows", "tag_rows_ordinality"])
      |> Selecto.filter({"id", 1})
      |> Selecto.order_by([{"tag_rows_ordinality", :desc}])

    assert rows(query) == [["a", 2], ["b", 1]]
    assert rows(Selecto.filter(query, {"tag_rows_ordinality", 1})) == [["b", 1]]
  end

  test "structured JSON filter parameters survive until global SQL finalization", %{query: query} do
    query =
      query
      |> Selecto.select(["id"])
      |> Selecto.filter({"payload", {:json_contains, %{"q" => "bound"}}})
      |> Selecto.filter({"id", 2})

    assert {_sql, ["q", "bound", 2]} = Selecto.to_sql(query)
    assert rows(query) == [[2]]
  end

  defp rows(query) do
    {sql, params} = Selecto.to_sql(query)
    assert {:ok, statement} = Exqlite.Sqlite3.prepare(query.connection, sql)

    try do
      assert :ok = Exqlite.Sqlite3.bind(statement, params)
      fetch(query.connection, statement, [])
    after
      Exqlite.Sqlite3.release(query.connection, statement)
    end
  end

  defp fetch(connection, statement, rows) do
    case Exqlite.Sqlite3.step(connection, statement) do
      {:row, row} -> fetch(connection, statement, [row | rows])
      :done -> Enum.reverse(rows)
      other -> flunk("SQLite query failed: #{inspect(other)}")
    end
  end
end
