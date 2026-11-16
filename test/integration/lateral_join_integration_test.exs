defmodule Selecto.Integration.LateralJoinTest do
  use ExUnit.Case, async: true

  setup do
    domain = %{
      name: "film_domain",
      source: %{
        source_table: "film",
        primary_key: :film_id,
        fields: [:film_id, :title, :rating, :special_features, :line_items],
        redact_fields: [],
        columns: %{
          film_id: %{type: :integer},
          title: %{type: :string},
          rating: %{type: :string},
          special_features: %{type: :array},
          line_items: %{type: :json}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    {:ok, domain: domain}
  end

  test "adds lateral join spec to selecto set", %{domain: domain} do
    selecto =
      Selecto.configure(domain, [], validate: false)
      |> Selecto.select(["title"])
      |> Selecto.lateral_join(:inner, {:unnest, "film.special_features"}, "features")

    lateral_joins = Map.get(selecto.set, :lateral_joins, [])
    assert length(lateral_joins) == 1
  end

  test "to_sql includes lateral SQL fragment", %{domain: domain} do
    selecto =
      Selecto.configure(domain, [], validate: false)
      |> Selecto.select(["title"])
      |> Selecto.lateral_join(:left, {:function, :generate_series, [1, 10]}, "numbers")

    {sql, params} = Selecto.to_sql(selecto)
    assert sql =~ "JOIN LATERAL"
    assert sql =~ "GENERATE_SERIES"
    assert is_list(params)
  end

  test "mysql json_table helper registers qualified columns and compiles json_table", %{
    domain: domain
  } do
    query =
      Selecto.configure(domain, [], validate: false)
      |> Map.put(:adapter, SelectoDBMySQL.Adapter)
      |> Selecto.json_table("line_items",
        as: "item_rows",
        columns: [
          {"position", :for_ordinality},
          {"sku", "$.sku", :string},
          {"quantity", "$.quantity", :integer}
        ]
      )
      |> Selecto.select(["title", "item_rows.sku", "item_rows.quantity"])

    {sql, params} = Selecto.to_sql(query)

    assert params == []
    assert sql =~ "JSON_TABLE(selecto_root.line_items"
    assert sql =~ "item_rows.sku"
    assert sql =~ "item_rows.quantity"
    assert sql =~ "position FOR ORDINALITY"
    refute sql =~ "JOIN LATERAL"
  end

  test "sqlite json_rowset helper registers qualified columns and compiles json_each", %{
    domain: domain
  } do
    query =
      Selecto.configure(domain, [], validate: false)
      |> Map.put(:adapter, SelectoDBSQLite.Adapter)
      |> Selecto.json_rowset("line_items", as: "item_rows", path: "$[*]")
      |> Selecto.select(["title", "item_rows.key", "item_rows.value", "item_rows.path"])

    {sql, params} = Selecto.to_sql(query)

    assert params == ["$[*]"]
    assert sql =~ "JSON_EACH(selecto_root.line_items, ?)"
    assert sql =~ "item_rows.\"key\""
    assert sql =~ "item_rows.value"
    assert sql =~ "item_rows.path"
    refute sql =~ "JOIN LATERAL"
  end

  test "sqlite json_rowset helper supports filtering on generated value column", %{domain: domain} do
    query =
      Selecto.configure(domain, [], validate: false)
      |> Map.put(:adapter, SelectoDBSQLite.Adapter)
      |> Selecto.json_rowset("line_items", as: "item_rows", path: "$[*]")
      |> Selecto.select(["title", "item_rows.value"])
      |> Selecto.filter({"item_rows.value", "sku-123"})

    {sql, params} = Selecto.to_sql(query)

    assert params == ["$[*]", "sku-123"]
    assert sql =~ "item_rows.value"
    assert sql =~ ~r/where.*item_rows\.value\s*=\s*\?/i
  end

  test "sqlite json_rowset supports json_tree", %{domain: domain} do
    query =
      Selecto.configure(domain, [], validate: false)
      |> Map.put(:adapter, SelectoDBSQLite.Adapter)
      |> Selecto.json_rowset("line_items", as: "item_tree", function: :json_tree)
      |> Selecto.select(["title", "item_tree.fullkey", "item_tree.parent"])

    {sql, params} = Selecto.to_sql(query)

    assert params == []
    assert sql =~ "JSON_TREE(selecto_root.line_items)"
    assert sql =~ "item_tree.fullkey"
    assert sql =~ "item_tree.parent"
    refute sql =~ "JOIN LATERAL"
  end

  test "sqlite json_rowset supports filtering on generated fullkey column", %{domain: domain} do
    query =
      Selecto.configure(domain, [], validate: false)
      |> Map.put(:adapter, SelectoDBSQLite.Adapter)
      |> Selecto.json_rowset("line_items", as: "item_tree", function: :json_tree)
      |> Selecto.select(["title", "item_tree.fullkey"])
      |> Selecto.filter({"item_tree.fullkey", "$.items[0].sku"})

    {sql, params} = Selecto.to_sql(query)

    assert params == ["$.items[0].sku"]
    assert sql =~ "item_tree.fullkey"
    assert sql =~ ~r/where.*item_tree\.fullkey\s*=\s*\?/i
  end

  test "invalid reference raises correlation error", %{domain: domain} do
    assert_raise Selecto.Advanced.LateralJoin.CorrelationError, fn ->
      Selecto.configure(domain, [], validate: false)
      |> Selecto.lateral_join(:inner, {:unnest, "film.nonexistent"}, "bad")
    end
  end

  defp customer_domain do
    %{
      name: "customer_domain",
      source: %{
        source_table: "customers",
        primary_key: :customer_id,
        fields: [:customer_id, :name],
        redact_fields: [],
        columns: %{
          customer_id: %{type: :integer},
          name: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp order_domain do
    %{
      name: "order_domain",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :customer_id, :inserted_at],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          customer_id: %{type: :integer},
          inserted_at: %{type: :naive_datetime}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end
end
