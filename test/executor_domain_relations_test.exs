defmodule Selecto.ExecutorDomainRelationsTest do
  # The relations an adapter resolves before a read: an ad-hoc join's table and a
  # subquery join's tables count; a CTE an ad-hoc join reads does not.
  use ExUnit.Case, async: true

  defp domain(table, fields) do
    %{
      name: table,
      source: %{
        source_table: table,
        primary_key: :id,
        fields: fields,
        redact_fields: [],
        columns: Map.new(fields, &{&1, %{type: :integer}}),
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp configure(table, fields),
    do: Selecto.configure(domain(table, fields), nil, validate: false)

  test "an ad-hoc join's source is a relation of the read" do
    query =
      configure("products", [:id])
      |> Selecto.join(:reviews, source: "reviews", owner_key: :id, related_key: :product_id)

    assert Enum.sort(Selecto.Executor.domain_relations(query)) == ["products", "reviews"]
    assert Selecto.Executor.dynamic_sources(query) == ["reviews"]
  end

  test "a subquery join's relations are relations of the read, with its query" do
    inner =
      configure("reviews", [:id, :product_id])
      |> Selecto.join(:authors, source: "authors", owner_key: :id, related_key: :review_id)
      |> Selecto.select(["product_id"])

    query =
      configure("products", [:id])
      |> Selecto.DynamicJoin.join_subquery(:best, inner, on: [%{left: "id", right: "product_id"}])

    assert Enum.sort(Selecto.Executor.domain_relations(query)) == [
             "authors",
             "products",
             "reviews"
           ]

    assert length(Selecto.Executor.read_queries(query)) == 2
    assert Selecto.Executor.dynamic_sources(query) == []
  end

  test "a VALUES list an ad-hoc join reads is no relation" do
    query =
      configure("orders", [:id])
      |> Selecto.with_values([["open", "Open"]], columns: ["status", "label"], as: "labels")
      |> Selecto.join(:labels, source: "labels", owner_key: :id, related_key: :status)

    assert Selecto.Executor.dynamic_sources(query) == []
    assert Selecto.Executor.domain_relations(query) == ["orders"]
  end

  test "raw SQL in a nested query keeps its own alias" do
    raw = {:field, {:raw_sql, "COUNT(*) AS n"}, "n"}
    inner = configure("reviews", [:id, :product_id]) |> Selecto.select(["product_id", raw])

    assert %Selecto{} =
             configure("products", [:id])
             |> Selecto.DynamicJoin.join_subquery(:best, inner,
               on: [%{left: "id", right: "product_id"}]
             )
  end

  test "a nested query's renamed plain field keeps its own name" do
    # The nested SQL carries no select alias: the column is the field's own name.
    for selector <- [{:field, "id", "x"}, {:field, "id", as: "x"}, {:field, "id", as: "id"}] do
      inner = configure("reviews", [:id, :product_id]) |> Selecto.select([selector, "product_id"])

      joined =
        configure("products", [:id])
        |> Selecto.DynamicJoin.join_subquery(:best, inner,
          on: [%{left: "id", right: "product_id"}]
        )

      fields = joined.set.dynamic_joins.best.fields |> Map.keys()
      assert "best.id" in fields, inspect(selector)
      refute "best.x" in fields, inspect(selector)
    end
  end

  test "a CTE body without a column list may rename a field, as before" do
    body = fn ->
      configure("products", [:id]) |> Selecto.select([{:field, "id", "product_id"}])
    end

    query = configure("products", [:id]) |> Selecto.with_cte("cb", body) |> Selecto.select(["id"])
    assert {sql, _params} = Selecto.to_sql(query)
    assert sql =~ "cb"
  end

  test "a retarget target's VALUES named like its origin's table is a collision" do
    domain =
      domain("reviews", [:id, :product_id])
      |> put_in([:source, :associations], %{
        prod: %{queryable: :prod, field: :prod, owner_key: :product_id, related_key: :id}
      })
      |> Map.put(:schemas, %{prod: domain("products", [:id]).source})
      |> Map.put(:joins, %{prod: %{type: :left, name: "prod"}})

    query =
      Selecto.configure(domain, nil, validate: false)
      |> Selecto.retarget(:prod)
      |> Selecto.with_values([[1, 2]], columns: ["id", "product_id"], as: "reviews")

    assert Selecto.Executor.scope_collisions(query) == ["reviews"]
  end

  test "names a query defines hide tables only where they are visible" do
    member =
      configure("orders", [:id]) |> Selecto.with_values([["a"]], columns: ["c"], as: "products")

    union =
      Selecto.union(
        configure("products", [:id]) |> Selecto.select(["id"]),
        member |> Selecto.select(["id"])
      )

    assert "products" in Selecto.Executor.domain_relations(union)
  end

  test "a CTE an ad-hoc join reads is no relation" do
    query =
      configure("products", [:id])
      |> Selecto.join(:recent, source: "recent", owner_key: :id, related_key: :product_id)

    assert Selecto.Executor.dynamic_sources(query) == ["recent"]
    cte = put_in(query.set.dynamic_joins.recent[:source_kind], :cte)
    assert Selecto.Executor.dynamic_sources(cte) == []
  end
end
