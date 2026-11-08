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

  test "a nested query cannot rename a selected field" do
    for selector <- [{:field, "id", "x"}, {:field, "id", as: "x"}] do
      inner = configure("reviews", [:id, :product_id]) |> Selecto.select([selector, "product_id"])

      assert_raise ArgumentError, ~r/cannot rename a selected field/, fn ->
        configure("products", [:id])
        |> Selecto.DynamicJoin.join_subquery(:best, inner, on: [%{left: "id", right: "x"}])
      end

      cte =
        configure("products", [:id])
        |> Selecto.with_cte("best", fn -> inner end)
        |> Selecto.select(["id"])

      assert_raise ArgumentError, ~r/cannot rename a selected field/, fn ->
        Selecto.to_sql(cte)
      end
    end
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
