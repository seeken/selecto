defmodule Selecto.SQLiteSetOperationsTest do
  use ExUnit.Case, async: true

  alias SelectoDBSQLite.Adapter

  setup do
    assert {:ok, connection} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(connection) end)

    assert {:ok, _} =
             Adapter.execute(
               connection,
               "CREATE TABLE items (id INTEGER PRIMARY KEY, parent_id INTEGER, bucket TEXT)",
               [],
               []
             )

    assert {:ok, _} =
             Adapter.execute(
               connection,
               "INSERT INTO items VALUES (1, NULL, 'a'), (2, 1, 'a'), (3, 2, 'b'), (4, NULL, 'b'), (5, 4, NULL)",
               [],
               []
             )

    base = Selecto.configure(domain(), connection, adapter: Adapter, validate: false)
    query = Selecto.select(base, ["id"])

    {:ok, connection: connection, query: query, base: base}
  end

  test "native compound operators execute with SQLite duplicate semantics", %{
    query: query,
    base: base
  } do
    left = ids(base, [1, 2, 3]) |> Selecto.select(["bucket"])
    right = ids(base, [2, 3, 4]) |> Selecto.select(["bucket"])

    assert rows(Selecto.union(left, right)) |> Enum.sort() == [["a"], ["b"]]

    assert rows(Selecto.union(left, right, all: true)) |> Enum.sort() ==
             [["a"], ["a"], ["a"], ["b"], ["b"], ["b"]]

    assert rows(Selecto.intersect(left, right)) |> Enum.sort() == [["a"], ["b"]]
    assert rows(Selecto.except(left, right)) == []

    assert rows(Selecto.except(ids(query, [1, 2]), ids(query, [2, 3]))) == [[1]]
  end

  test "compound membership treats NULL as an equal set value", %{base: base} do
    left = ids(base, [1, 5]) |> Selecto.select(["bucket"])
    right = ids(base, [5]) |> Selecto.select(["bucket"])

    assert rows(Selecto.intersect(left, right)) == [[nil]]
    assert rows(Selecto.except(left, right)) == [["a"]]
  end

  test "chained operations preserve the authored left association and bind order", %{query: query} do
    result =
      ids(query, [1, 2])
      |> Selecto.union(ids(query, [2, 3]))
      |> Selecto.intersect(ids(query, [3, 4]))
      |> Selecto.except(ids(query, [4]))

    assert rows(result) == [[3]]
    assert {_sql, params} = Selecto.to_sql(result)
    assert params == [1, 2, 2, 3, 3, 4, 4]
    assert Selecto.Builder.SetOperations.extract_set_operation_params(result) == params
  end

  test "nested right operands retain their compound query", %{query: query} do
    nested = Selecto.except(ids(query, [2, 3]), ids(query, [3]))
    result = Selecto.union(ids(query, [1]), nested) |> Selecto.order_by([{"id", :asc}])

    assert rows(result) == [[1], [2]]
    assert {_sql, [1, 2, 3, 3]} = Selecto.to_sql(result)
  end

  test "paging a set before appending another operation stays on that operand", %{query: query} do
    paged =
      ids(query, [1, 2])
      |> Selecto.union(ids(query, [3]))
      |> Selecto.order_by([{"id", :desc}])
      |> Selecto.limit(1)

    result = paged |> Selecto.union(ids(query, [4])) |> Selecto.order_by([{"id", :asc}])
    assert rows(result) == [[3], [4]]
  end

  test "operand ordering and paging remain separate from outer ordering and paging", %{
    query: query
  } do
    left = query |> Selecto.order_by([{"id", :desc}]) |> Selecto.limit(2)
    right = query |> Selecto.order_by([{"id", :asc}]) |> Selecto.limit(2) |> Selecto.offset(1)

    result =
      left
      |> Selecto.union(right, all: true)
      |> Selecto.order_by([{"id", :desc}])
      |> Selecto.limit(2)
      |> Selecto.offset(1)

    assert rows(result) == [[4], [3]]
  end

  test "CTEs are scoped to each operand and bind before its main query", %{query: query} do
    left = cte_operand(query, [1, 2], {:gt, 1})
    right = cte_operand(query, [3, 4], {:lt, 4})
    result = Selecto.union(left, right) |> Selecto.order_by([{"id", :asc}])

    assert rows(result) == [[2], [3]]
    assert {_sql, [1, 2, 1, 3, 4, 4]} = Selecto.to_sql(result)
  end

  test "recursive CTE operands execute with their own bind order", %{query: query} do
    base = fn -> ids(query, [1]) end

    step = fn _reference ->
      query
      |> Selecto.join(:walk,
        source: "walk",
        type: :inner,
        owner_key: :parent_id,
        related_key: :id,
        fields: %{"id" => %{type: :integer}}
      )
    end

    recursive =
      query
      |> Selecto.with_recursive_cte("walk",
        base_query: base,
        recursive_query: step,
        columns: ["id"],
        max_depth: 5,
        join: [type: :inner, owner_key: :id, related_key: :id]
      )
      |> Selecto.filter({"id", {:gte, 2}})

    result = Selecto.union(recursive, ids(query, [4])) |> Selecto.order_by([{"id", :asc}])
    assert rows(result) == [[2], [3], [4]]
    assert {_sql, [1, 2, 4]} = Selecto.to_sql(result)
  end

  test "quoted placeholder text does not interfere with compound or CTE parameters", %{
    query: query
  } do
    left =
      cte_operand(query, [1, 2], {:gt, 1})
      |> Selecto.select(["id", {:literal, "?'$1"}])

    right = ids(query, [3]) |> Selecto.select(["id", {:literal, "?'$1"}])
    result = Selecto.union(left, right, all: true) |> Selecto.order_by([{"id", :asc}])

    assert rows(result) == [[2, "?'$1"], [3, "?'$1"]]
    assert {_sql, [1, 2, 1, 3]} = Selecto.to_sql(result)
  end

  test "offset without a finite limit executes on ordinary and compound queries", %{query: query} do
    ordinary = query |> Selecto.order_by([{"id", :asc}]) |> Selecto.offset(3)
    assert rows(ordinary) == [[4], [5]]
    assert {sql, []} = Selecto.to_sql(ordinary)
    assert sql =~ ~r/limit -1\s+offset 3/i

    compound =
      ids(query, [1, 2])
      |> Selecto.union(ids(query, [3, 4]))
      |> Selecto.order_by([{"id", :asc}])
      |> Selecto.offset(2)

    assert rows(compound) == [[3], [4]]
    assert {sql, _params} = Selecto.to_sql(compound)
    assert sql =~ ~r/limit -1\s+offset 2/i

    paged_operand = query |> Selecto.order_by([{"id", :asc}]) |> Selecto.offset(4)
    assert rows(Selecto.union(ids(query, [1]), paged_operand)) == [[1], [5]]
  end

  test "SQLite refuses unsupported ALL operators including nested and chained forms", %{
    query: query
  } do
    for {operation, name} <- [{&Selecto.intersect/3, "INTERSECT"}, {&Selecto.except/3, "EXCEPT"}] do
      unsupported = operation.(ids(query, [1]), ids(query, [1]), all: true)

      for result <- [
            unsupported,
            Selecto.union(ids(query, [2]), unsupported),
            Selecto.union(unsupported, ids(query, [2]))
          ] do
        assert_raise ArgumentError, ~r/SQLite does not support #{name} ALL/, fn ->
          Selecto.to_sql(result)
        end
      end
    end
  end

  defp cte_operand(query, selected_ids, predicate) do
    query
    |> Selecto.with_cte(
      "picked",
      fn ->
        ids(query, selected_ids) |> Selecto.select(["id", {:literal, "?"}])
      end,
      columns: ["id", "marker"],
      join: [type: :inner, owner_key: :id, related_key: :id]
    )
    |> Selecto.filter({"id", predicate})
  end

  defp ids(query, values), do: Selecto.filter(query, {"id", {:in, values}})

  defp rows(query) do
    {sql, params} = Selecto.to_sql(query)
    # Execute the generated SQL unchanged. The local adapter stand-in rewrites
    # "$1" text for legacy tests, including text inside quoted SQL literals.
    assert {:ok, statement} = Exqlite.Sqlite3.prepare(query.connection, sql)

    try do
      assert :ok = Exqlite.Sqlite3.bind(statement, params)
      fetch_rows(query.connection, statement, [])
    after
      Exqlite.Sqlite3.release(query.connection, statement)
    end
  end

  defp fetch_rows(connection, statement, acc) do
    case Exqlite.Sqlite3.step(connection, statement) do
      {:row, row} -> fetch_rows(connection, statement, [row | acc])
      :done -> Enum.reverse(acc)
      other -> flunk("SQLite execution failed: #{inspect(other)}")
    end
  end

  defp domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :parent_id, :bucket],
        columns: %{id: %{type: :integer}, parent_id: %{type: :integer}, bucket: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end
end
