defmodule Selecto.JoinNamespaceExecutionTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(db) end)

    for statement <- [
          "CREATE TABLE ns_orders(id INTEGER PRIMARY KEY,client_id INTEGER)",
          "CREATE TABLE ns_legs(id INTEGER PRIMARY KEY,order_id INTEGER,client_id INTEGER)",
          "CREATE TABLE ns_clients(id INTEGER PRIMARY KEY,name TEXT)",
          "INSERT INTO ns_orders VALUES(1,10),(2,11)",
          "INSERT INTO ns_legs VALUES(100,1,20),(101,1,NULL)",
          "INSERT INTO ns_clients VALUES(10,'order client'),(11,'no legs'),(20,'leg client')"
        ],
        do: :ok = Exqlite.Sqlite3.execute(db, statement)

    %{db: db}
  end

  test "a child reusing a root lookup ID cannot overwrite its flat join", %{db: db} do
    query = domain() |> Selecto.configure(db, adapter: Adapter)
    root = query |> Selecto.select(["id", "client.name"]) |> Selecto.order_by(["id"])
    assert {:ok, {[[1, "order client"], [2, "no legs"]], _, _}} = Selecto.execute(root)

    both =
      query
      |> Selecto.select(["id", "client.name", "legs.id", "legs.client.name"])
      |> Selecto.order_by(["id", "legs.id"])

    assert {:ok,
            {[
               [1, "order client", 100, "leg client"],
               [1, "order client", 101, nil],
               [2, "no legs", nil, nil]
             ], _, _}} = Selecto.execute(both)

    count =
      query
      |> Selecto.select(["id", "client.name"])
      |> Selecto.order_by(["id"])
      |> Selecto.subselect([
        %{fields: ["id"], target_schema: :legs, join_path: [:legs], format: :count, alias: "legs"}
      ])

    assert {:ok, {[[1, "order client", 2], [2, "no legs", 0]], _, _}} = Selecto.execute(count)
  end

  test "existing unique nested local aliases and complete paths select the same edge", %{db: db} do
    d = domain()

    d =
      put_in(d, [:schemas, :legs, :associations], %{
        leg_client: assoc(:clients, :client_id, :id, :one, :leg_client)
      })

    d = put_in(d, [:joins, :legs, :joins], %{leg_client: %{type: :left}})

    query =
      d
      |> Selecto.configure(db, adapter: Adapter)
      |> Selecto.select(["id", "leg_client.name", "legs.leg_client.name"])
      |> Selecto.order_by(["id", "legs.id"])

    assert {:ok, {[[1, "leg client", "leg client"], [1, nil, nil], [2, nil, nil]], _, _}} =
             Selecto.execute(query)
  end

  test "rebasing a computed child field changes references but preserves literal strings", %{
    db: db
  } do
    d = domain()

    computed = %{
      copy: %{type: :string, computed: %{kind: :expression, expression: [:field, :name]}},
      tag: %{type: :string, computed: %{kind: :expression, expression: [:literal, "client.name"]}},
      flag: %{
        type: :boolean,
        computed: %{kind: :predicate, expression: [:eq, :name, "client.name"]}
      }
    }

    d = update_in(d, [:schemas, :clients, :columns], &Map.merge(&1, computed))
    d = update_in(d, [:schemas, :clients, :fields], &(&1 ++ Map.keys(computed)))

    query = Selecto.configure(d, db, adapter: Adapter)

    assert query.config.columns["client.copy"].select ==
             {:computed_value, [:field, "client.name"]}

    assert query.config.columns["legs.client.copy"].select ==
             {:computed_value, [:field, "legs.client.name"]}

    assert query.config.columns["legs.client.tag"].select ==
             {:computed_value, [:literal, "client.name"]}

    assert query.config.columns["legs.client.flag"].select ==
             {:computed_predicate, [:eq, "legs.client.name", "client.name"]}
  end

  defp domain do
    clients = relation("ns_clients", %{id: :integer, name: :string})

    legs =
      relation("ns_legs", %{id: :integer, order_id: :integer, client_id: :integer})
      |> Map.put(:associations, %{client: assoc(:clients, :client_id, :id, :one, :client)})

    source =
      relation("ns_orders", %{id: :integer, client_id: :integer})
      |> Map.put(:associations, %{
        client: assoc(:clients, :client_id, :id, :one, :client),
        legs: assoc(:legs, :id, :order_id, :many, :legs)
      })

    %{
      name: "namespace fixture",
      source: source,
      schemas: %{clients: clients, legs: legs},
      joins: %{client: %{type: :left}, legs: %{type: :left, joins: %{client: %{type: :left}}}}
    }
  end

  defp relation(table, columns),
    do: %{
      source_table: table,
      primary_key: :id,
      fields: Map.keys(columns),
      columns: Map.new(columns, fn {id, type} -> {id, %{type: type}} end),
      associations: %{},
      redact_fields: []
    }

  defp assoc(target, owner, related, cardinality, field),
    do: %{
      queryable: target,
      owner_key: owner,
      related_key: related,
      cardinality: cardinality,
      field: field
    }
end
