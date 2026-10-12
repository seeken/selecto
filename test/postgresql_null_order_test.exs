defmodule Selecto.PostgreSQLNullOrderTest do
  use ExUnit.Case, async: true

  # MySQL and MariaDB sort NULLs first ascending and last descending; adapters
  # declaring `:postgresql_null_order` follow PostgreSQL instead.
  defmodule NullOrderAdapter do
    def connect(connection), do: {:ok, connection}
    def supports?(:postgresql_null_order), do: true
    def supports?(_feature), do: false
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: to_string(identifier)
    def rollup_sql(grouped_clauses), do: [grouped_clauses, " WITH ROLLUP"]
  end

  defmodule NativeOrderAdapter do
    defdelegate connect(connection), to: NullOrderAdapter
    defdelegate placeholder(index), to: NullOrderAdapter
    defdelegate quote_identifier(identifier), to: NullOrderAdapter
    def supports?(_feature), do: false
  end

  defp query(adapter) do
    %{
      name: "people",
      source: %{
        source_table: "people",
        primary_key: :id,
        fields: [:id, :name, :score],
        redact_fields: [],
        columns: %{id: %{type: :integer}, name: %{type: :string}, score: %{type: :integer}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
    |> Selecto.configure(:mock_connection, adapter: adapter, validate: false)
  end

  defp order_sql(selecto) do
    {sql, _aliases, params} = Selecto.gen_sql(selecto, [])
    [_, order] = String.split(sql, "order by", parts: 2)
    {String.trim(order), params}
  end

  test "an unqualified direction places NULLs as PostgreSQL does" do
    {order, []} =
      NullOrderAdapter
      |> query()
      |> Selecto.select(["id"])
      |> Selecto.order_by([{"name", :asc}, {"score", :desc}])
      |> order_sql()

    assert order ==
             "CASE WHEN selecto_root.name IS NULL THEN 1 ELSE 0 END asc, selecto_root.name asc, " <>
               "CASE WHEN selecto_root.score IS NULL THEN 0 ELSE 1 END asc, selecto_root.score desc"
  end

  test "a selected column is tested by expression, never by its position" do
    {order, []} =
      NullOrderAdapter
      |> query()
      |> Selecto.select(["name"])
      |> Selecto.order_by([{"name", :asc}])
      |> order_sql()

    assert order ==
             "CASE WHEN selecto_root.name IS NULL THEN 1 ELSE 0 END asc, selecto_root.name asc"
  end

  test "explicit NULL placement wins" do
    {order, []} =
      NullOrderAdapter
      |> query()
      |> Selecto.select(["id"])
      |> Selecto.order_by([{"name", :asc_nulls_first}, {"score", :desc_nulls_last}])
      |> order_sql()

    assert order == "selecto_root.name asc, selecto_root.score desc"
  end

  test "a grouped column is tested through MIN and sorted by its position" do
    {order, []} =
      NullOrderAdapter
      |> query()
      |> Selecto.select(["name", {:count, "*"}])
      |> Selecto.group_by(["name"])
      |> Selecto.order_by([{"name", :desc}])
      |> order_sql()

    assert order == "CASE WHEN MIN(selecto_root.name) IS NULL THEN 0 ELSE 1 END asc, 1 desc"
  end

  # MySQL's ONLY_FULL_GROUP_BY rejects a repeated computed grouped expression
  # (ERROR 1055) but admits an aggregate of it.
  test "computed grouped keys are tested through MIN, never repeated bare" do
    for {key, function, bound} <- [
          {{:upper, "name"}, "upper", []},
          {{:coalesce, ["name", {:literal, "zz"}]}, "coalesce", []},
          {{:extract, "score", "year"}, "extract", []}
        ] do
      {sql, _aliases, params} =
        NullOrderAdapter
        |> query()
        |> Selecto.select([key, {:count, "*"}])
        |> Selecto.group_by([key])
        |> Selecto.order_by([{key, :asc}])
        |> Selecto.gen_sql([])

      [_, order] = String.split(sql, "order by", parts: 2)

      assert String.trim(order) =~
               ~r/\ACASE WHEN MIN\(#{function}\(.*selecto_root\.\w+.*\)\) IS NULL THEN 1 ELSE 0 END asc, 1 asc\z/i

      assert params == bound
    end
  end

  test "grouped positions and aggregates keep valid terms" do
    {order, []} =
      NullOrderAdapter
      |> query()
      |> Selecto.select([{:upper, "name"}, {:count, "*"}])
      |> Selecto.group_by([{:upper, "name"}])
      |> Selecto.order_by([{{:literal_position, 1}, :desc}, {{:count, "*"}, :asc}])
      |> order_sql()

    assert order ==
             "CASE WHEN MIN(upper(selecto_root.name)) IS NULL THEN 0 ELSE 1 END asc, 1 desc, " <>
               "CASE WHEN count(*) IS NULL THEN 1 ELSE 0 END asc, 2 asc"
  end

  test "a computed ROLLUP key cannot be placed and is refused" do
    query =
      NullOrderAdapter
      |> query()
      |> Selecto.select([{:upper, "name"}, {:count, "*"}])
      |> Selecto.group_by(Selecto.Expr.rollup([{:upper, "name"}]))
      |> Selecto.order_by([{{:upper, "name"}, :asc}])

    assert_raise RuntimeError, ~r/NULL placement cannot be expressed/, fn ->
      Selecto.gen_sql(query, [])
    end
  end

  test "adapters without the declaration keep native placement" do
    {order, []} =
      NativeOrderAdapter
      |> query()
      |> Selecto.select(["id"])
      |> Selecto.order_by([{"name", :asc}])
      |> order_sql()

    assert order == "selecto_root.name asc"
  end

  test "window ORDER BY places NULLs as PostgreSQL does" do
    {sql, _aliases, []} =
      NullOrderAdapter
      |> query()
      |> Selecto.select(["id"])
      |> Selecto.window_function(:row_number, [], over: [order_by: [{"score", :desc}]], as: "rn")
      |> Selecto.gen_sql([])

    assert sql =~
             "ORDER BY CASE WHEN selecto_root.score IS NULL THEN 0 ELSE 1 END ASC, selecto_root.score DESC"
  end

  test "a set-operation ORDER BY tests the operands' projections by collision-free names" do
    base = query(NullOrderAdapter)

    {sql, _aliases, []} =
      Selecto.union(Selecto.select(base, ["name"]), Selecto.select(base, ["name"]), all: true)
      |> Selecto.order_by([{"name", :asc}])
      |> Selecto.gen_sql([])

    assert sql =~ "select selecto_root.name AS selecto_projection_1"
    refute sql =~ "selecto_root.name IS NULL"

    assert sql =~
             "ORDER BY CASE WHEN selecto_projection_1 IS NULL THEN 1 ELSE 0 END asc, 1 asc"
  end

  defmodule AliasingAdapter do
    defdelegate connect(connection), to: NullOrderAdapter
    defdelegate placeholder(index), to: NullOrderAdapter
    defdelegate quote_identifier(identifier), to: NullOrderAdapter
    def supports?(:lateral_projection_aliases), do: true
    def supports?(_feature), do: false
  end

  test "a lateral output alias holding a placeholder is refused before SQL" do
    child = fn _parent ->
      AliasingAdapter
      |> query()
      |> Selecto.select([Selecto.Expr.as("id", "a?b")])
      |> Selecto.filter({"id", {:ref, "selecto_root.id"}})
    end

    query =
      AliasingAdapter
      |> query()
      |> Selecto.lateral_join(:left, child, "matched")
      |> Selecto.select(["id"])

    assert_raise RuntimeError, ~r/cannot contain '\?'/, fn -> Selecto.gen_sql(query, []) end
  end
end
