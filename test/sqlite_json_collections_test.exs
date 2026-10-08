defmodule Selecto.SQLiteJsonCollectionsTest do
  use ExUnit.Case, async: true

  alias SelectoDBSQLite.Adapter

  setup do
    assert {:ok, connection} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(connection) end)

    assert :ok =
             Exqlite.Sqlite3.execute(
               connection,
               "CREATE TABLE items (id INTEGER PRIMARY KEY, payload TEXT)"
             )

    assert :ok =
             Exqlite.Sqlite3.execute(
               connection,
               ~s|INSERT INTO items VALUES (1, '{"items":[{"sku":"b"},{"sku":"a"}]}'), (2, '{"items":[]}')|
             )

    assert :ok =
             Exqlite.Sqlite3.execute(
               connection,
               "CREATE TABLE children (id INTEGER PRIMARY KEY, item_id INTEGER, name TEXT)"
             )

    assert :ok =
             Exqlite.Sqlite3.execute(
               connection,
               "INSERT INTO children VALUES (3,1,'b'),(2,1,'a'),(1,1,'a'),(4,2,'z')"
             )

    assert :ok =
             Exqlite.Sqlite3.execute(
               connection,
               "CREATE TABLE notes (id INTEGER PRIMARY KEY, child_id INTEGER, name TEXT)"
             )

    assert :ok =
             Exqlite.Sqlite3.execute(
               connection,
               "INSERT INTO notes VALUES (1,1,'one'),(2,1,'two'),(3,2,'three')"
             )

    base = Selecto.configure(domain(), connection, adapter: Adapter, validate: false)
    %{base: base}
  end

  test "rowset extraction, filtering, and ordering resolve governed joined columns", %{base: base} do
    query =
      base
      |> Selecto.json_rowset("payload", as: "items", path: "$.items", join_type: :left)
      |> Selecto.select(["id"])
      |> Selecto.json_select([Selecto.Expr.json_extract_text("items.value", "$.sku", as: "sku")])
      |> Selecto.json_order_by([{:json_extract_text, "items.value", "$.sku", :asc}])

    assert {sql, ["$.items"]} = Selecto.to_sql(query)
    assert sql =~ ~s("items"."value")
    refute sql =~ ~s("selecto_root"."items.value")
    assert rows(query) == [[2, nil], [1, "a"], [1, "b"]]

    filtered = Selecto.json_filter(query, {:json_extract_text, "items.value", "$.sku", {:=, "a"}})
    assert {_sql, ["$.items", "a"]} = Selecto.to_sql(filtered)
    assert rows(filtered) == [[1, "a"]]
  end

  test "JSON-only references request the registered relational join", %{base: base} do
    query =
      base
      |> Selecto.json_rowset("payload", as: "items", path: "$.items")
      |> Selecto.select(["id"])
      |> Selecto.json_order_by([{:json_extract_text, "items.value", "$.sku", :asc}])

    assert rows(query) == [[1], [1]]
    assert {sql, ["$.items"]} = Selecto.to_sql(query)
    assert sql =~ "JOIN JSON_EACH"
  end

  test "ordered per-parent JSON collections apply stable paging before aggregation", %{base: base} do
    query =
      base
      |> Selecto.select(["id"])
      |> Selecto.order_by([{"id", :asc}])
      |> Selecto.subselect([
        %{
          target_schema: :children,
          fields: [:id, :name],
          alias: "children",
          order_by: [{:asc, :name}],
          limit: 2
        }
      ])

    assert [[1, first], [2, second]] = rows(query)
    assert Jason.decode!(first) == [%{"id" => 1, "name" => "a"}, %{"id" => 2, "name" => "a"}]
    assert Jason.decode!(second) == [%{"id" => 4, "name" => "z"}]
  end

  test "nested bounded collections retain JSON arrays and parent correlation", %{base: base} do
    query =
      base
      |> Selecto.select(["id"])
      |> Selecto.order_by([{"id", :asc}])
      |> Selecto.subselect([
        %{
          target_schema: :children,
          join_path: [:children],
          fields: [:id],
          alias: "children",
          order_by: [{:asc, :id}],
          limit: 2,
          nested: [
            %{
              target_schema: :notes,
              fields: [:name],
              alias: "notes",
              format: :json_agg,
              join_path: [:children, :notes],
              order_by: [{:desc, :id}],
              limit: 1,
              filters: []
            }
          ]
        }
      ])

    assert [[1, first], [2, second]] = rows(query)

    assert Jason.decode!(first) == [
             %{"id" => 1, "notes" => ["two"]},
             %{"id" => 2, "notes" => ["three"]}
           ]

    assert Jason.decode!(second) == [%{"id" => 4, "notes" => []}]
  end

  defp rows(query) do
    {sql, params} = Selecto.to_sql(query)
    assert {:ok, statement} = Exqlite.Sqlite3.prepare(query.connection, sql)

    try do
      assert :ok = Exqlite.Sqlite3.bind(statement, params)
      fetch_rows(query.connection, statement, [])
    after
      Exqlite.Sqlite3.release(query.connection, statement)
    end
  end

  defp fetch_rows(connection, statement, acc) do
    case Exqlite.Sqlite3.step(connection, statement) do
      {:row, row} -> fetch_rows(connection, statement, [row | acc])
      :done -> Enum.reverse(acc)
      other -> flunk("SQLite execution failed: #{inspect(other)}")
    end
  end

  defp domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        redact_fields: [],
        fields: [:id, :payload],
        columns: %{id: %{type: :integer}, payload: %{type: :map}},
        associations: %{
          children: %{
            queryable: :children,
            field: :children,
            owner_key: :id,
            related_key: :item_id
          }
        }
      },
      schemas: %{
        children: %{
          source_table: "children",
          primary_key: :id,
          redact_fields: [],
          fields: [:id, :item_id, :name],
          columns: %{id: %{type: :integer}, item_id: %{type: :integer}, name: %{type: :string}},
          associations: %{
            notes: %{queryable: :notes, field: :notes, owner_key: :id, related_key: :child_id}
          }
        },
        notes: %{
          source_table: "notes",
          primary_key: :id,
          redact_fields: [],
          fields: [:id, :child_id, :name],
          columns: %{id: %{type: :integer}, child_id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        }
      },
      joins: %{
        children: %{type: :left, name: "children", joins: %{notes: %{type: :left, name: "notes"}}}
      }
    }
  end
end
