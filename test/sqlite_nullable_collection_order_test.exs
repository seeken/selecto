defmodule Selecto.SQLiteNullableCollectionOrderTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.Adapter

  setup_all do
    assert {:ok, db} = Adapter.connect(database: ":memory:", temp_store: "MEMORY")

    on_exit(fn ->
      try do
        memory_only!(db)
      after
        assert :ok = Adapter.disconnect(db)
      end
    end)

    memory_only!(db)

    for sql <- [
          "CREATE TABLE nullable_collection_parents (id INTEGER NOT NULL, organization_id INTEGER NOT NULL, name TEXT, UNIQUE(organization_id,id))",
          "CREATE TABLE nullable_collection_children (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, name TEXT)"
        ],
        do: assert({:ok, _} = Adapter.execute(db, sql, [], []))

    for row <- [
          [101, 7, "Own Parent"],
          [101, 8, "Foreign Same ID"],
          [102, 7, "Empty Parent"],
          [103, 7, "Other Parent"]
        ] do
      assert {:ok, _} =
               Adapter.execute(
                 db,
                 "INSERT INTO nullable_collection_parents VALUES (?,?,?)",
                 row,
                 []
               )
    end

    # Equal names, equal NULLs and deliberately non-key insertion order expose
    # both nullable placement and the stable key appended to limited queries.
    for row <- [
          [5, 7, 101, "Alpha ' 雪"],
          [4, 7, 101, nil],
          [2, 7, 101, "Alpha ' 雪"],
          [1, 7, 101, nil],
          [3, 7, 101, "Beta"],
          [8, 8, 101, "Aardvark Foreign"],
          [7, 7, 103, nil],
          [6, 7, 103, "Beta"]
        ] do
      assert {:ok, _} =
               Adapter.execute(
                 db,
                 "INSERT INTO nullable_collection_children VALUES (?,?,?,?)",
                 row,
                 []
               )
    end

    base =
      domain()
      |> Selecto.configure(db, adapter: Adapter)
      |> Selecto.with_tenant(%{tenant_id: 7, tenant_field: :organization_id})
      |> Selecto.apply_tenant_scope()

    before_rows = snapshot(db)
    %{base: base, db: db, before_rows: before_rows}
  end

  test "ASC, DESC and bare collection orders put NULLs in the portable position", %{base: base} do
    assert ids(base, [{:asc, :name}, {:asc, :id}]) == [2, 5, 3, 1, 4]
    assert ids(base, [{:desc, :name}, {:asc, :id}]) == [1, 4, 3, 2, 5]
    assert ids(base, [:name, {:asc, :id}]) == [2, 5, 3, 1, 4]
    assert ids(base, [{:asc, :name}], limit: 2) == [2, 5]
    assert ids(base, [{:desc, :name}], limit: 2) == [1, 4]
    assert ids(base, [:name], limit: 2) == [2, 5]
  end

  test "pages seek after equal values and NULL ties without gaps or duplicates", %{base: base} do
    asc = [{:asc, :name}]
    assert ids(base, asc, limit: 2, after: %{parent_key: 101, values: ["Alpha ' 雪", 2]}) == [5, 3]

    asc_pages = [
      ids(base, asc, limit: 2),
      ids(base, asc, limit: 2, after: %{parent_key: 101, values: ["Alpha ' 雪", 5]}),
      ids(base, asc, limit: 2, after: %{parent_key: 101, values: [nil, 1]})
    ]

    assert List.flatten(asc_pages) == [2, 5, 3, 1, 4]
    assert ids(base, asc, limit: 2, after: %{parent_key: 101, values: [nil, 4]}) == []
    desc = [{:desc, :name}]
    assert ids(base, desc, limit: 2, after: %{parent_key: 101, values: [nil, 1]}) == [4, 3]

    desc_pages = [
      ids(base, desc, limit: 2),
      ids(base, desc, limit: 2, after: %{parent_key: 101, values: [nil, 4]}),
      ids(base, desc, limit: 2, after: %{parent_key: 101, values: ["Alpha ' 雪", 2]})
    ]

    assert List.flatten(desc_pages) == [1, 4, 3, 2, 5]

    assert ids(base, [:name], limit: 2, after: %{parent_key: 101, values: ["Alpha ' 雪", 2]}) == [
             5,
             3
           ]
  end

  test "cursor parent boundaries, tenant scope, raw NULL cells and empty collections survive", %{
    base: base
  } do
    before_rows = snapshot(base.connection)

    assert ids(base, [{:asc, :name}],
             root: 103,
             limit: 2,
             after: %{parent_key: 101, values: [nil, 4]}
           ) == [6, 7]

    assert ids(base, [{:asc, :name}],
             root: 102,
             limit: 2,
             after: %{parent_key: 101, values: [nil, 4]}
           ) == []

    assert {:ok, {[[101, "Own Parent", raw]], ["id", "name", "children"], ["id", "name"]}} =
             Selecto.execute(query(base, [{:desc, :name}, {:asc, :id}], []))

    assert is_binary(raw)

    assert Jason.decode!(raw) == [
             %{"id" => 1, "name" => nil},
             %{"id" => 4, "name" => nil},
             %{"id" => 3, "name" => "Beta"},
             %{"id" => 2, "name" => "Alpha ' 雪"},
             %{"id" => 5, "name" => "Alpha ' 雪"}
           ]

    assert {:ok, {[[102, "Empty Parent", "[]"]], _, _}} =
             Selecto.execute(query(base, [{:asc, :name}], root: 102))

    assert snapshot(base.connection) == before_rows
  end

  test "collection reads leave all stored children unchanged", %{
    base: base,
    db: db,
    before_rows: before_rows
  } do
    assert ids(base, [{:desc, :name}], limit: 2) == [1, 4]
    assert snapshot(db) == before_rows
  end

  defp ids(base, orders, opts \\ []) do
    before_rows = snapshot(base.connection)
    assert {:ok, {[[_, _, raw]], _, _}} = Selecto.execute(query(base, orders, opts))
    assert snapshot(base.connection) == before_rows
    raw |> Jason.decode!() |> Enum.map(&Map.fetch!(&1, "id"))
  end

  defp snapshot(db) do
    for {table, order} <- [
          {"nullable_collection_parents", "organization_id,id"},
          {"nullable_collection_children", "id"}
        ],
        into: %{} do
      assert {:ok, %{rows: rows}} =
               Adapter.execute(db, "SELECT * FROM " <> table <> " ORDER BY " <> order, [], [])

      {table, rows}
    end
  end

  defp query(base, orders, opts) do
    config = %{
      target_schema: :children,
      fields: [:id, :name],
      alias: "children",
      format: :json_agg,
      join_path: [:children],
      order_by: orders
    }

    config =
      Enum.reduce(Keyword.take(opts, [:limit, :after]), config, fn {key, value}, acc ->
        Map.put(acc, key, value)
      end)

    base
    |> Selecto.select(["id", "name"])
    |> Selecto.subselect([config])
    |> Selecto.filter({"id", Keyword.get(opts, :root, 101)})
    |> Selecto.order_by([{:asc, "id"}])
  end

  defp memory_only!(db) do
    assert {:ok, _} =
             Adapter.execute(
               db,
               "CREATE TEMP TABLE IF NOT EXISTS memory_proof (id INTEGER)",
               [],
               []
             )

    assert {:ok, %{rows: databases}} = Adapter.execute(db, "PRAGMA database_list", [], [])
    assert {:ok, %{rows: [[2]]}} = Adapter.execute(db, "PRAGMA temp_store", [], [])
    assert Enum.all?(databases, fn [_, _, path] -> path == "" end)
    assert Enum.any?(databases, fn [_, name, _] -> name == "temp" end)
  end

  defp domain do
    %{
      schema_version: 1,
      name: "SQLiteNullableCollectionOrdering",
      domain_version: "1.0.0",
      domain_fingerprint: "sqlite-nullable-collection-order-test-v1",
      source: %{
        source_table: "nullable_collection_parents",
        primary_key: :id,
        fields: [:id, :organization_id, :name],
        redact_fields: [],
        tenant_field: :organization_id,
        columns: %{
          id: %{type: :integer},
          organization_id: %{type: :integer},
          name: %{type: :string}
        },
        associations: %{
          children: %{
            queryable: :children,
            owner_key: :id,
            related_key: :parent_id,
            cardinality: :many
          }
        }
      },
      schemas: %{
        children: %{
          source_table: "nullable_collection_children",
          primary_key: :id,
          fields: [:id, :tenant_id, :parent_id, :name],
          redact_fields: [],
          tenant_field: :tenant_id,
          columns: %{
            id: %{type: :integer},
            tenant_id: %{type: :integer},
            parent_id: %{type: :integer},
            name: %{type: :string}
          },
          associations: %{}
        }
      },
      joins: %{children: %{type: :left}}
    }
  end
end
