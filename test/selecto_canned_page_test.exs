defmodule Selecto.CannedPageTest do
  use ExUnit.Case, async: true
  alias Selecto.CannedPage
  alias Selecto.Expr, as: X

  defp base do
    fields = [:id, :name, :category, :supplier, :price, :active]
    types = [:integer, :string, :string, :integer, :decimal, :boolean]

    domain = %{
      name: "Products",
      source: %{
        source_table: "products",
        primary_key: :id,
        fields: fields,
        redact_fields: [],
        associations: %{},
        columns: Map.new(Enum.zip(fields, types), fn {f, t} -> {f, %{type: t}} end)
      },
      schemas: %{},
      joins: %{},
      required_filters: [{"active", true}]
    }

    Selecto.configure(domain, :mock_connection)
  end

  defp page(base) do
    CannedPage.new!(Selecto.filter(base, X.gte("price", 1)),
      id: "products",
      views: [
        %{id: "detail", kind: :detail, query: Selecto.select(base, ["id", "name"])},
        %{
          id: "categories",
          kind: :aggregate,
          query:
            base
            |> Selecto.select(["category", X.as(X.count_distinct("id"), "products")])
            |> Selecto.group_by(["category"])
        }
      ],
      controls: [
        %{id: "category", kind: :facet, field: "category", searchable: true, limit: 2},
        %{id: "supplier", kind: :facet, field: "supplier"},
        %{id: "price", kind: :range, field: "price"},
        %{id: "name", kind: :text, field: "name"}
      ],
      initial_state: %{"filters" => %{"category" => ["food"]}}
    )
  end

  test "closed state, explicit clearing, typed ranges and literal prefixes" do
    assert Selecto.CannedPage.State.typed!(:float, "1.25") === 1.25
    assert Selecto.CannedPage.State.typed!(:float, 1.0e-10) === 1.0e-10
    assert Selecto.CannedPage.State.typed!(:decimal, "1.250") == Decimal.new("1.25")
    page = page(base())

    assert {:ok, %{"filters" => %{"category" => ["food"]}}} =
             CannedPage.normalize_state(page, %{})

    assert {:ok, %{"filters" => %{}}} = CannedPage.normalize_state(page, %{"filters" => %{}})

    for input <- [
          %{"selected" => ["secret"]},
          %{"filters" => %{"secret" => 1}},
          %{"view" => "missing"},
          %{"limit" => "25<script>"},
          %{"version" => 2},
          %{"filters" => %{"supplier" => ["not-integer"]}},
          %{"facet_search" => %{"supplier" => "x"}}
        ] do
      assert {:error, :invalid_canned_page_state} = CannedPage.normalize_state(page, input)
    end

    assert {:ok, state} =
             CannedPage.normalize_state(page, %{
               "filters" => %{"price" => %{"min" => "1.25", "max" => ""}}
             })

    assert state["filters"]["price"]["min"] == Decimal.new("1.25")
    assert {:ok, plan} = CannedPage.plan(page, base(), %{"filters" => %{"name" => "A%_!"}})
    {sql, params} = Selecto.to_sql(plan.query)
    assert sql =~ "LIKE"
    assert "A!%!_!!%" in params
  end

  test "exclude-self keeps request, fixed, required and drilldown filters" do
    base = base()
    page = page(base)
    authorized = Selecto.filter(base, X.lte("id", 10))

    input = %{
      "filters" => %{"category" => ["food", "drink"], "supplier" => ["4"]},
      "drilldown" => %{"view" => "categories", "values" => ["food"]}
    }

    assert {:ok, plan} = CannedPage.plan(page, authorized, input)
    assert plan.query.set.limit == 26

    for query <- [
          plan.query,
          plan.total_query,
          plan.facets["category"].options,
          plan.facets["category"].selected
        ] do
      assert {"active", true} in query.set.filtered
      assert {"price", {:gte, 1}} in query.set.filtered
      assert {"id", {:lte, 10}} in query.set.filtered
      assert {"category", "food"} in query.set.filtered
    end

    refute {"category", {:in, ["food", "drink"]}} in plan.facets["category"].options.set.filtered
    assert {"supplier", {:in, [4]}} in plan.facets["category"].options.set.filtered
    assert {"category", {:in, ["food", "drink"]}} in plan.facets["supplier"].options.set.filtered

    for query <- [plan.query, plan.total_query, plan.facets["category"].options] do
      {sql, _} = Selecto.to_sql(query)
      assert String.downcase(sql) =~ "select"
    end
  end

  test "definitions reject unsupported aggregate math and base pagination" do
    base = base()

    assert_raise ArgumentError, fn ->
      CannedPage.new!(Selecto.limit(base, 5), id: "bad", views: [])
    end

    assert_raise ArgumentError, fn ->
      CannedPage.new!(base,
        id: "bad",
        views: [
          %{
            id: "sum",
            kind: :aggregate,
            query:
              base
              |> Selecto.select(["category", X.as(X.sum("price"), "total")])
              |> Selecto.group_by(["category"])
          }
        ]
      )
    end
  end

  test "tenant authorization survives every derived query" do
    base = base()
    domain = base.domain
    domain = put_in(domain, [:source, :fields], domain.source.fields ++ [:tenant_id])
    domain = put_in(domain, [:source, :columns, :tenant_id], %{type: :string})
    query = Selecto.configure(domain, :mock_connection)
    page = page(query)

    authorized =
      query
      |> Selecto.with_tenant(%{tenant_id: "acme", required: true})
      |> Selecto.apply_tenant_scope()

    assert {:ok, plan} = CannedPage.plan(page, authorized, %{})

    queries =
      [plan.query, plan.total_query] ++
        Enum.flat_map(plan.facets, fn {_, facet} ->
          Enum.reject([facet.options, facet.selected], &is_nil/1)
        end)

    for derived <- queries do
      assert derived.tenant == authorized.tenant
      assert {"tenant_id", "acme"} in Selecto.required_filters(derived)
      {_, params} = Selecto.to_sql(derived)
      assert "acme" in params
    end
  end
end
