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

  test "a grouped column places NULLs first descending" do
    {order, []} =
      NullOrderAdapter
      |> query()
      |> Selecto.select(["name", {:count, "*"}])
      |> Selecto.group_by(["name"])
      |> Selecto.order_by([{"name", :desc}])
      |> order_sql()

    assert order ==
             "CASE WHEN selecto_root.name IS NULL THEN 0 ELSE 1 END asc, selecto_root.name desc"
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
end
