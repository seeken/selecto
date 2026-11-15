defmodule Selecto.NativeBuilderCompositionTest do
  use ExUnit.Case, async: true
  alias Selecto.Expr, as: X
  alias SelectoDBSQLite.Adapter

  defp domain do
    %{
      name: "Composition",
      source: %{
        source_table: "compose_spec_people",
        primary_key: :id,
        tenant_field: :tenant_id,
        fields: [:id, :tenant_id, :active, :name],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          active: %{type: :integer},
          name: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      required_filters: [{"active", 1}]
    }
  end

  defp base,
    do:
      Selecto.configure(domain(), Selecto.Runtime.Context.new(Adapter, :not_connected),
        adapter: Adapter,
        validate: false
      )

  test "selections append in order including repeated fields and expressions; resets are explicit" do
    original = Selecto.select(base(), "id")
    expression = X.as("name", "label")
    query = original |> Selecto.select(["name", "id"]) |> Selecto.select([expression, expression])
    assert query.set.selected == ["id", "name", "id", expression, expression]
    assert original.set.selected == ["id"]
    assert Selecto.select(query, []) == query
    assert Selecto.replace_select(query, "name").set.selected == ["name"]
    assert Selecto.clear_select(query).set.selected == base().set.selected
    assert Selecto.replace_select(query, []).set.selected == base().set.selected
    assert (query |> Selecto.clear_select() |> Selecto.select("name")).set.selected == ["name"]
    {sql, [1]} = query |> Selecto.clear_filter() |> Selecto.to_sql()

    assert sql =~
             "selecto_root.id, selecto_root.name, selecto_root.id, selecto_root.name, selecto_root.name"
  end

  test "filters retain ordered conjunctions, OR grouping and parameter repetitions" do
    a = X.gte("id", 1)
    b = X.compact_or([X.eq("name", "A"), X.eq("name", "B")])

    query =
      base()
      |> Selecto.select("id")
      |> Selecto.filter(a)
      |> Selecto.filter(b)
      |> Selecto.filter(a)

    assert query.set.filtered == [a, b, a, {"active", 1}]
    assert Selecto.filter(query, []) == query
    {sql, params} = Selecto.to_sql(query)
    assert sql =~ "and"
    assert sql =~ "or"
    assert params == [1, 1, "A", "B", 1]
    assert Selecto.replace_filter(query, X.eq("id", 4)).set.filtered == [{"id", 4}, {"active", 1}]
    assert Selecto.replace_filter(query, []).set.filtered == [{"active", 1}]
    assert Selecto.clear_filter(query).set.filtered == [{"active", 1}]
    assert base().set.filtered == []
  end

  test "every reset combination retains required filters, trusted tenant and recorded host scope" do
    {:ok, db} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(db) end)

    for sql <- [
          "CREATE TABLE compose_spec_people (id INTEGER, tenant_id INTEGER, active INTEGER, name TEXT)",
          "INSERT INTO compose_spec_people VALUES (1,7,1,'A'),(2,8,1,'B'),(3,7,0,'B'),(4,7,1,'B')"
        ],
        do: :ok = Exqlite.Sqlite3.execute(db, sql)

    original =
      domain()
      |> Selecto.configure(db, adapter: Adapter, validate: false)
      |> Selecto.with_tenant(7)

    for filter_mode <- [:compose, :replace, :clear, :empty_replace],
        select_mode <- [:compose, :replace, :clear, :empty_replace] do
      query =
        original
        |> Selecto.select("id")
        |> Selecto.filter(X.gte("id", 1))
        |> Selecto.filter(X.compact_or([X.eq("id", 1), X.gte("id", 2)]))

      query =
        case filter_mode do
          :compose -> query
          :replace -> Selecto.replace_filter(query, X.gte("id", 1))
          :clear -> Selecto.clear_filter(query)
          :empty_replace -> Selecto.replace_filter(query, [])
        end

      query =
        case select_mode do
          :compose -> Selecto.select(query, "id")
          :replace -> Selecto.replace_select(query, "id")
          :clear -> query |> Selecto.clear_select() |> Selecto.select("id")
          :empty_replace -> query |> Selecto.replace_select([]) |> Selecto.select("id")
        end

      assert {:ok, {rows, _, _}} =
               query |> Selecto.order_by("id") |> Selecto.execute(analyze_complexity: false)

      expected = if select_mode == :compose, do: [[1, 1], [4, 4]], else: [[1], [4]]
      assert rows == expected, "#{filter_mode}/#{select_mode}"
    end

    aliased =
      original
      |> Selecto.select(X.as("id", "left_id"))
      |> Selecto.select(X.as("id", "right_id"))
      |> Selecto.order_by("id")

    assert {:ok, {[[1, 1], [4, 4]], _, ["left_id", "right_id"]}} =
             Selecto.execute(aliased, analyze_complexity: false)

    host =
      original |> Selecto.Tenant.host_filter(X.eq("name", "A")) |> Selecto.filter(X.gte("id", 0))

    for query <- [Selecto.clear_filter(host), Selecto.replace_filter(host, X.gte("id", 0))] do
      assert {:ok, {[[1]], _, _}} =
               query |> Selecto.replace_select("id") |> Selecto.execute(analyze_complexity: false)
    end

    required =
      domain()
      |> Map.put(:tenant_required, true)
      |> Selecto.configure(db, adapter: Adapter, validate: false)

    assert {:error, _} =
             required
             |> Selecto.clear_filter()
             |> Selecto.select("id")
             |> Selecto.execute(analyze_complexity: false)
  end

  test "explicit resets retain set-query mutation restrictions" do
    query = Selecto.select(base(), "id")
    compound = Selecto.union(query, query)

    for reset <- [
          &Selecto.clear_select/1,
          &Selecto.clear_filter/1,
          &Selecto.replace_select(&1, "name"),
          &Selecto.replace_filter(&1, {"id", 1})
        ] do
      assert_raise ArgumentError, fn -> reset.(compound) end
    end
  end

  test "clear selection restores configured initial fields" do
    configured =
      domain()
      |> Map.put(:required_selected, ["name"])
      |> Selecto.configure(Selecto.Runtime.Context.new(Adapter, :not_connected),
        adapter: Adapter,
        validate: false
      )

    assert (configured |> Selecto.select("id") |> Selecto.clear_select()).set.selected == ["name"]
  end
end
