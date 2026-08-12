defmodule SetOperationsTest do
  use ExUnit.Case, async: true

  setup do
    domain = %{
      source: %{
        source_table: "film",
        primary_key: :film_id,
        fields: [:film_id, :title, :rental_rate, :rating],
        redact_fields: [],
        columns: %{
          film_id: %{type: :integer},
          title: %{type: :string},
          rental_rate: %{type: :decimal},
          rating: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    q1 =
      Selecto.configure(domain, [], validate: false)
      |> Selecto.select(["title", "rental_rate"])
      |> Selecto.filter([{"rating", "PG"}])

    q2 =
      Selecto.configure(domain, [], validate: false)
      |> Selecto.select(["title", "rental_rate"])
      |> Selecto.filter([{"rating", "G"}])

    {:ok, q1: q1, q2: q2, domain: domain}
  end

  test "creates union operation", %{q1: q1, q2: q2} do
    result = Selecto.union(q1, q2)
    [op] = Map.get(result.set, :set_operations, [])
    assert op.operation == :union
  end

  test "supports chained set operations", %{q1: q1, q2: q2, domain: domain} do
    q3 =
      Selecto.configure(domain, [], validate: false)
      |> Selecto.select(["title", "rental_rate"])
      |> Selecto.filter([{"rating", "R"}])

    result = q1 |> Selecto.union(q2) |> Selecto.intersect(q3)
    assert length(Map.get(result.set, :set_operations, [])) == 2
  end

  test "generates SQL for union", %{q1: q1, q2: q2} do
    result = Selecto.union(q1, q2)
    {sql, params} = Selecto.to_sql(result)
    assert sql =~ "UNION"
    assert sql =~ ~r/select/i
    assert sql =~ "selecto_root.rating = $1"
    assert sql =~ "selecto_root.rating = $2"
    assert params == ["PG", "G"]
  end

  test "gen_sql returns list-shaped alias metadata for set operations", %{q1: q1, q2: q2} do
    {_sql, aliases, params} = q1 |> Selecto.union(q2) |> Selecto.gen_sql([])

    assert aliases == []
    assert is_list(aliases)
    assert params == ["PG", "G"]
  end

  test "renumbers parameters across chained operands", %{q1: q1, q2: q2, domain: domain} do
    q3 =
      Selecto.configure(domain, [], validate: false)
      |> Selecto.select(["title", "rental_rate"])
      |> Selecto.filter([{"rating", "R"}])

    {sql, params} = q1 |> Selecto.union(q2) |> Selecto.intersect(q3) |> Selecto.to_sql()

    assert sql =~ "selecto_root.rating = $1"
    assert sql =~ "selecto_root.rating = $2"
    assert sql =~ "selecto_root.rating = $3"
    assert params == ["PG", "G", "R"]
  end

  test "preserves parameter order for question-mark adapters", %{domain: domain} do
    left =
      Selecto.configure(domain, [], adapter: SelectoDBSQLite.Adapter, validate: false)
      |> Selecto.select(["title"])
      |> Selecto.filter({"rating", "PG"})

    right =
      Selecto.configure(domain, [], adapter: SelectoDBSQLite.Adapter, validate: false)
      |> Selecto.select(["title"])
      |> Selecto.filter({"rating", "G"})

    {sql, params} = Selecto.union(left, right) |> Selecto.to_sql()

    assert Regex.scan(~r/\?/, sql) |> length() == 2
    assert params == ["PG", "G"]
  end

  test "order by works with set operations", %{q1: q1, q2: q2} do
    result = q1 |> Selecto.union(q2) |> Selecto.order_by([{"title", :asc}])
    {sql, _params} = Selecto.to_sql(result)
    assert sql =~ "ORDER BY"
    assert sql =~ "ORDER BY 1 asc"
    refute sql =~ "ORDER BY selecto_root.title"
  end

  test "outer order by rejects fields that are absent from the set projection", %{q1: q1, q2: q2} do
    result = q1 |> Selecto.union(q2) |> Selecto.order_by([{"film_id", :asc}])

    assert_raise ArgumentError, ~r/must reference a selected output column/, fn ->
      Selecto.to_sql(result)
    end
  end

  test "outer limit/offset apply to set operation result", %{q1: q1, q2: q2} do
    result =
      q1
      |> Selecto.union(q2, all: true)
      |> Selecto.order_by([{"title", :asc}])
      |> Selecto.limit(5)
      |> Selecto.offset(10)

    {sql, _params} = Selecto.to_sql(result)

    assert sql =~ ~r/ORDER BY/i
    assert sql =~ ~r/LIMIT\s+5/i
    assert sql =~ ~r/OFFSET\s+10/i
  end

  test "structural query mutations fail closed after a set operation", %{q1: q1, q2: q2} do
    set_result = Selecto.union(q1, q2)

    mutations = [
      select: &Selecto.select(&1, "film_id"),
      filter: &Selecto.filter(&1, {"rating", "R"}),
      pre_retarget_filter: &Selecto.pre_retarget_filter(&1, {"rating", "R"}),
      post_retarget_filter: &Selecto.post_retarget_filter(&1, {"rating", "R"}),
      group_by: &Selecto.group_by(&1, "title"),
      select_shape: &Selecto.select_shape(&1, ["title"]),
      join: &Selecto.join(&1, :missing_join),
      join_parameterize: &Selecto.join_parameterize(&1, :missing_join, :variant),
      join_subquery: &Selecto.join_subquery(&1, :nested, q2),
      with_cte: &Selecto.with_cte(&1, :missing_cte),
      with_recursive_cte: &Selecto.with_recursive_cte(&1, "tree", []),
      with_ctes: &Selecto.with_ctes(&1, []),
      with_subquery: &Selecto.with_subquery(&1, :missing_subquery),
      retarget: &Selecto.retarget(&1, :missing_schema),
      reset_retarget: &Selecto.Retarget.reset_retarget/1,
      subselect: &Selecto.subselect(&1, ["title"]),
      clear_subselects: &Selecto.Subselect.clear_subselects/1,
      with_tenant: &Selecto.with_tenant(&1, %{tenant_id: "tenant-a"}),
      apply_tenant_scope: &Selecto.apply_tenant_scope(&1, tenant_id: "tenant-a"),
      require_tenant_filter: &Selecto.require_tenant_filter(&1, "tenant_id", "tenant-a"),
      unnest: &Selecto.unnest(&1, "tags"),
      with_unnest: &Selecto.with_unnest(&1, :missing_unnest),
      lateral_join:
        &Selecto.lateral_join(&1, :inner, {:function, :generate_series, [1, 2]}, "series"),
      with_lateral:
        &Selecto.with_lateral(&1, {:function, :generate_series, [1, 2]}, as: "series"),
      with_values: &Selecto.with_values(&1, [["PG"]], columns: ["rating"], as: "ratings"),
      json_table: &Selecto.json_table(&1, "metadata", as: "items", columns: []),
      json_rowset: &Selecto.json_rowset(&1, "metadata", as: "items"),
      window_function: &Selecto.window_function(&1, :row_number, [], over: []),
      text_search_rank: &Selecto.text_search_rank(&1, ["title"], query: "film"),
      json_select: &Selecto.json_select(&1, {:json_extract, "metadata", "$.name"}),
      json_filter: &Selecto.json_filter(&1, {:json_exists, "metadata", "$.name"}),
      json_order_by: &Selecto.json_order_by(&1, {:json_extract, "metadata", "$.name", :asc}),
      array_select: &Selecto.array_select(&1, {:array_agg, "title", []}),
      array_filter: &Selecto.array_filter(&1, {:array_contains, "tags", ["featured"]}),
      array_manipulate: &Selecto.array_manipulate(&1, {:array_append, "tags", "new", []})
    ]

    for {operation, mutate} <- mutations do
      assert_raise ArgumentError,
                   ~r/^#{operation} cannot be applied after a set operation/,
                   fn -> mutate.(set_result) end
    end
  end

  test "SQL generation rejects unsupported set-result mutation even if an API guard is bypassed",
       %{
         q1: q1,
         q2: q2
       } do
    set_result = Selecto.union(q1, q2)
    tampered_set = put_in(set_result.set.selected, set_result.set.selected ++ ["film_id"])

    assert_raise ArgumentError, ~r/unsupported post-set mutations in set.selected/, fn ->
      Selecto.to_sql(tampered_set)
    end

    tampered_tenant = %{set_result | tenant: %{tenant_id: "tenant-a"}}

    assert_raise ArgumentError, ~r/unsupported post-set mutations in tenant/, fn ->
      Selecto.to_sql(tampered_tenant)
    end

    tampered_config = %{set_result | config: Map.put(set_result.config, :source_table, "other")}

    assert_raise ArgumentError, ~r/unsupported post-set mutations in config/, fn ->
      Selecto.to_sql(tampered_config)
    end

    tampered_policy = %{set_result | policy: %{set_result.policy | mode: :strict}}

    assert_raise ArgumentError, ~r/unsupported post-set mutations in policy/, fn ->
      Selecto.to_sql(tampered_policy)
    end
  end

  test "set operation does not inherit left query order by as outer order by", %{q1: q1, q2: q2} do
    ordered_left = q1 |> Selecto.order_by([{"title", :asc}])
    ordered_right = q2 |> Selecto.order_by([{"title", :asc}])

    result = Selecto.union(ordered_left, ordered_right, all: true)

    {sql, _params} = Selecto.to_sql(result)

    order_by_count = Regex.scan(~r/order\s+by/i, sql) |> length()
    assert order_by_count == 2
  end
end
