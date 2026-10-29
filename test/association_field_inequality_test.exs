defmodule Selecto.AssociationFieldInequalityTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.Adapter

  test "flat joins and collections exclude self rows and preserve type and tenant boundaries" do
    {:ok, db} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(db) end)

    for statement <- [
          "CREATE TABLE loads (id INTEGER, tenant_id INTEGER, parent_id INTEGER, type TEXT)",
          "INSERT INTO loads VALUES (4,7,4,'Y'),(5,7,4,'Y'),(6,7,4,'Y'),(7,7,4,'X'),(5,8,4,'Y'),(1,7,NULL,NULL),(9,7,1,'Y'),(10,7,NULL,'Y')"
        ],
        do: :ok = Exqlite.Sqlite3.execute(db, statement)

    base =
      domain()
      |> Selecto.configure(db, adapter: Adapter)
      |> Selecto.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
      |> Selecto.filter({"id", 4})

    flat = base |> Selecto.select(["id", "legs.id"]) |> Selecto.order_by(["legs.id"])
    assert {:ok, {[[4, 5], [4, 6]], _, _}} = Selecto.execute(flat)

    count =
      base
      |> Selecto.select(["id"])
      |> Selecto.subselect([
        %{target_schema: :legs, fields: ["id"], join_path: [:legs], format: :count, alias: "legs"}
      ])

    assert {:ok, {[[4, 2]], _, _}} = Selecto.execute(count)
    {sql, params} = Selecto.to_sql(count)
    assert sql =~ "NOT ("
    assert "Y" in params

    other =
      domain()
      |> Selecto.configure(db, adapter: Adapter)
      |> Selecto.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
      |> Selecto.filter({"id", 1})
      |> Selecto.select(["id", "legs.id"])

    assert {:ok, {[[1, nil]], _, _}} = Selecto.execute(other)
  end

  test "inequality refuses undeclared, computed, and non-local operands" do
    target = domain().schemas.legs
    selecto = %{adapter: Adapter, domain: domain()}

    for other <- ["missing", "legs.parent_id", "parent_id) OR TRUE"] do
      assert_raise ArgumentError, fn ->
        Selecto.Builder.Association.policy_conditions(
          selecto,
          "child",
          %{id: {:ne, {:field, other}}},
          target
        )
      end
    end

    computed =
      put_in(target, [:columns, :parent_id, :computed], %{
        kind: :expression,
        expression: {:field, :id}
      })

    assert_raise ArgumentError, fn ->
      Selecto.Builder.Association.policy_conditions(
        selecto,
        "child",
        %{id: {:ne, {:field, :parent_id}}},
        computed
      )
    end
  end

  defp domain do
    relation = %{
      source_table: "loads",
      primary_key: :id,
      tenant_field: :tenant_id,
      fields: [:id, :tenant_id, :parent_id, :type],
      redact_fields: [],
      associations: %{},
      columns: %{
        id: %{type: :integer},
        tenant_id: %{type: :integer},
        parent_id: %{type: :integer},
        type: %{type: :string}
      }
    }

    association = %{
      queryable: :legs,
      field: :legs,
      owner_key: :id,
      related_key: :parent_id,
      cardinality: :many,
      source_scope_key: :type,
      target_scope_key: :type,
      where: %{type: "Y", id: {:ne, {:field, :parent_id}}}
    }

    %{
      name: "split legs",
      tenant_required: true,
      source: put_in(relation, [:associations, :legs], association),
      schemas: %{legs: relation},
      joins: %{legs: %{type: :left}}
    }
  end
end
