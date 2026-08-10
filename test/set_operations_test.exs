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

  test "set operation does not inherit left query order by as outer order by", %{q1: q1, q2: q2} do
    ordered_left = q1 |> Selecto.order_by([{"title", :asc}])
    ordered_right = q2 |> Selecto.order_by([{"title", :asc}])

    result = Selecto.union(ordered_left, ordered_right, all: true)

    {sql, _params} = Selecto.to_sql(result)

    order_by_count = Regex.scan(~r/order\s+by/i, sql) |> length()
    assert order_by_count == 2
  end
end
