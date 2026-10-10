defmodule Selecto.SQLiteDiagnosticsTest do
  use ExUnit.Case, async: true

  setup do
    assert {:ok, connection} = SelectoDBSQLite.Adapter.connect(database: ":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(connection) end)

    assert :ok =
             Exqlite.Sqlite3.execute(connection, "CREATE TABLE items (id INTEGER PRIMARY KEY)")

    domain = %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id],
        columns: %{id: %{type: :integer}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    query =
      Selecto.configure(domain, connection, adapter: SelectoDBSQLite.Adapter, validate: false)
      |> Selecto.select(["id"])
      |> Selecto.filter({"id", 1})

    {:ok, query: query}
  end

  test "public explain returns a bound SQLite query plan and readable details", %{query: query} do
    assert {:ok, result} = Selecto.explain(query)
    assert result.explain_sql == "EXPLAIN QUERY PLAN " <> result.query_sql
    assert result.params == [1]
    assert result.columns == ["id", "parent", "notused", "detail"]
    assert [[_, _, _, detail]] = result.rows
    assert detail =~ "SEARCH selecto_root"
    assert result.plan_lines == [detail]
    assert {:ok, text_result} = Selecto.explain(query, format: :text)
    assert text_result.plan_lines == result.plan_lines
  end

  test "SQLite analyze and unsupported explain options fail with explicit errors", %{query: query} do
    assert {:error, %Selecto.Error{type: :validation_error, message: message}} =
             Selecto.explain_analyze(query)

    assert message =~ "SQLite does not support EXPLAIN ANALYZE"

    for opts <- [[format: :json], [buffers: true], [timing: false], [verbose: false]] do
      assert {:error, %Selecto.Error{type: :validation_error, message: message}} =
               Selecto.explain(query, opts)

      assert message =~ "SQLite EXPLAIN QUERY PLAN does not support"
    end
  end
end
