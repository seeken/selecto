defmodule Selecto.LateralProjectionAliasTest do
  use ExUnit.Case, async: true

  alias Selecto.Expr, as: X

  defmodule AliasingAdapter do
    def name, do: :mysql
    def connect(connection), do: {:ok, connection}
    def dialect, do: Selecto.TestDialect.PostgreSQL
    def placeholder(_position), do: "?"
    def quote_identifier(name), do: "`" <> String.replace(to_string(name), "`", "``") <> "`"
    def supports?(:lateral_projection_aliases), do: true
    def supports?(_feature), do: false
  end

  defp base(adapter) do
    domain = %{
      name: "Lateral projections",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :status, :total],
        redact_fields: [],
        associations: %{},
        columns: %{id: %{type: :integer}, status: %{type: :string}, total: %{type: :integer}}
      },
      schemas: %{},
      joins: %{}
    }

    Selecto.configure(domain, :mock_connection, adapter: adapter, validate: false)
  end

  defp lateral(selectors, adapter \\ AliasingAdapter) do
    child = base(adapter) |> Selecto.select(selectors) |> Selecto.filter({"status", "delivered"})

    base(adapter)
    |> Selecto.select(["id"])
    |> Selecto.lateral_join(:left, fn _ -> child end, "stats")
  end

  test "an anonymous count publishes the stable column the outer query addresses" do
    query = lateral([X.count()])
    {sql, params} = Selecto.to_sql(query)
    assert {sql, params} == Selecto.to_sql(query)
    assert sql =~ "count(*) AS count"
    assert params == ["delivered"]
  end

  test "anonymous aggregate names agree across tuple and function forms" do
    query = lateral([{:sum, "total"}, X.func("AVG", ["total"]), {:func, :max, ["total"], []}])
    {sql, params} = Selecto.to_sql(query)
    assert {sql, params} == Selecto.to_sql(query)

    assert sql =~ "sum(selecto_root.total) AS sum" or
             sql =~ "sum(subq_root_orders.total) AS sum"

    assert sql =~ "AS avg"
    assert sql =~ "AS max"
  end

  test "authored aliases, including UUID-shaped names, stay intact" do
    uuid = "12345678-1234-4234-8234-123456789abc"
    query = lateral([X.as(X.count(), uuid), {:func, :sum, ["total"], [as: "authored_sum"]}])
    {sql, params} = Selecto.to_sql(query)
    assert {sql, params} == Selecto.to_sql(query)
    assert sql =~ "AS `#{uuid}`"
    assert sql =~ "AS authored_sum"
  end

  test "anonymous non-function expressions have stable positional names" do
    query = lateral([X.lit(1), X.lit(2)])
    {sql, params} = Selecto.to_sql(query)
    assert {sql, params} == Selecto.to_sql(query)
    assert sql =~ "1 AS selecto_projection_1"
    assert sql =~ "2 AS selecto_projection_2"
  end

  test "two anonymous counts require explicit distinct output names" do
    assert_raise Selecto.Builder.ScopeRefusal, ~r/output aliases must be unique/, fn ->
      lateral([X.count(), X.count("id")]) |> Selecto.to_sql()
    end
  end

  test "a generated name cannot shadow an authored alias, including MySQL case folding" do
    assert_raise Selecto.Builder.ScopeRefusal, ~r/output aliases must be unique/, fn ->
      lateral([X.count(), X.as({:sum, "total"}, "COUNT")]) |> Selecto.to_sql()
    end
  end

  test "distinct authored count names resolve a collision" do
    query = lateral([X.as(X.count(), "all_rows"), X.as(X.count("id"), "identified_rows")])
    {sql, _params} = Selecto.to_sql(query)
    assert sql =~ "AS all_rows"
    assert sql =~ "AS identified_rows"
  end

  test "ordinary PostgreSQL laterals keep their native aggregate column name" do
    {sql, ["delivered"]} = lateral([X.count()], SelectoDBPostgreSQL.Adapter) |> Selecto.to_sql()
    assert sql =~ "select count(*)"
    refute sql =~ ~r/count\(\*\) AS/i
  end
end
