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

  test "through collections and flat joins enforce bridge and target policies with exact text keys",
       %{base: base} do
    connection = base.connection

    for sql <- [
          "ALTER TABLE items ADD COLUMN tenant_id INTEGER",
          "UPDATE items SET tenant_id = 7",
          "CREATE TABLE tags (id INTEGER, tenant_id INTEGER, label TEXT, active INTEGER)",
          "CREATE TABLE links (record_id INTEGER, tag_id TEXT, tenant_id INTEGER, active INTEGER, deleted_at TEXT)",
          "INSERT INTO tags VALUES (10,7,'allowed',2),(10,8,'other tenant',2),(9007199254740993,7,'large',2),(11,7,'inactive',0),(12,7,'inactive bridge',2),(13,7,'deleted bridge',2),(14,7,'other bridge tenant',2)",
          "INSERT INTO links VALUES (1,'9007199254740993',7,1,NULL),(1,'10',7,1,NULL),(1,'11',7,1,NULL),(1,'12',7,0,NULL),(1,'13',7,1,'deleted'),(1,'14',8,1,NULL)"
        ],
        do: assert(:ok = Exqlite.Sqlite3.execute(connection, sql))

    domain = domain()

    source =
      domain.source
      |> Map.put(:fields, [:id, :payload, :tenant_id])
      |> put_in([:columns, :tenant_id], %{type: :integer})

    association = %{
      queryable: :tags,
      field: :tags,
      owner_key: :id,
      related_key: :id,
      where: %{active: 2},
      through: %{
        table: "links",
        owner_key: :record_id,
        related_key: :tag_id,
        source_scope_key: :tenant_id,
        through_scope_key: :tenant_id,
        target_scope_key: :tenant_id,
        target_key_cast: :string,
        where: %{active: 1, deleted_at: nil}
      }
    }

    source = put_in(source, [:associations, :tags], association)

    schema = %{
      source_table: "tags",
      primary_key: :id,
      fields: [:id, :tenant_id, :label, :active],
      redact_fields: [],
      columns: %{
        id: %{type: :integer},
        tenant_id: %{type: :integer},
        label: %{type: :string},
        active: %{type: :integer}
      },
      associations: %{}
    }

    domain = %{
      domain
      | source: source,
        schemas: Map.put(domain.schemas, :tags, schema),
        joins: Map.put(domain.joins, :tags, %{type: :left})
    }

    query =
      Selecto.configure(domain, connection, adapter: Adapter, validate: false)
      |> Selecto.filter({"tenant_id", 7})

    collection =
      query
      |> Selecto.select(["id"])
      |> Selecto.order_by([{"id", :asc}])
      |> Selecto.subselect([
        %{
          target_schema: :tags,
          join_path: [:tags],
          fields: [:id, :label],
          alias: "tags",
          order_by: [{:asc, :id}],
          limit: 2
        }
      ])

    assert [[1, first], [2, second]] = rows(collection)

    assert Jason.decode!(first) == [
             %{"id" => 10, "label" => "allowed"},
             %{"id" => 9_007_199_254_740_993, "label" => "large"}
           ]

    assert Jason.decode!(second) == []
    assert {_sql, [1, 2, 7]} = Selecto.to_sql(collection)

    flat =
      query
      |> Selecto.select(["id", "tags.label"])
      |> Selecto.order_by([{"id", :asc}, {"tags.label", :asc}])

    assert rows(flat) == [[1, "allowed"], [1, "large"], [2, nil]]
    assert {_sql, [1, 2, 7]} = Selecto.to_sql(flat)
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
