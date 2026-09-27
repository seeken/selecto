defmodule Selecto.DerivedTableProjectionTest do
  @moduledoc """
  Count and projection-sum queries wrap the governed query in a derived table.
  MySQL, MariaDB and SQL Server reject a derived table whose columns share a
  name, so every projected column must get a unique alias there.
  """
  use ExUnit.Case, async: true

  alias Selecto.Executor

  defmodule RecordingAdapter do
    def name, do: :mysql
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: "`#{identifier}`"

    def execute(pid, query, params, _opts) do
      send(pid, {:executed, IO.iodata_to_binary(query), params})
      {:ok, %{rows: [[7]], columns: ["value"]}}
    end

    def supports?(:projection_sum), do: true
    def supports?(_feature), do: false
  end

  defp domain do
    %{
      name: "Derived table projection",
      source: %{
        source_table: "products",
        primary_key: :id,
        fields: [:id, :name, :category_id, :price],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          category_id: %{type: :integer},
          price: %{type: :integer}
        },
        associations: %{
          category: %{
            queryable: :categories,
            field: :category,
            owner_key: :category_id,
            related_key: :id
          }
        }
      },
      schemas: %{
        categories: %{
          source_table: "categories",
          primary_key: :id,
          fields: [:id, :name],
          redact_fields: [],
          columns: %{id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        }
      },
      joins: %{category: %{type: :left, name: "category"}}
    }
  end

  defp duplicate_name_query(adapter, connection \\ nil) do
    Selecto.configure(domain(), nil, validate: false)
    |> Map.put(:adapter, adapter)
    |> Map.put(:connection, connection)
    |> Selecto.select(["name", "category.name", {:field, "price", "total"}])
    |> Selecto.filter({"price", {:gt, 3}})
  end

  defp projected_names(sql) do
    ~r/\bAS\s+[`"\[]?(selecto_projection_\d+)/i
    |> Regex.scan(sql, capture: :all_but_first)
    |> List.flatten()
  end

  test "plain SQL generation keeps the unaliased projection" do
    {sql, aliases, _params} = Selecto.gen_sql(duplicate_name_query(SelectoDBMySQL.Adapter), [])

    assert aliases == ["name", "name", "total"]
    refute sql =~ "selecto_projection_"
  end

  for adapter <- [SelectoDBMySQL.Adapter, SelectoDBMariaDB.Adapter, SelectoDBMSSQL.Adapter] do
    test "#{inspect(adapter)} derived source names every projected column uniquely" do
      query = duplicate_name_query(unquote(adapter))

      {sql, aliases, params} = Selecto.gen_sql(query, unique_projection_aliases: true)

      assert aliases == ["name", "name", "total"]

      assert projected_names(sql) ==
               ["selecto_projection_1", "selecto_projection_2", "selecto_projection_3"]

      assert params == [3]
      refute sql =~ ~r/\b3\b/
    end
  end

  test "count wraps a derived table whose columns are uniquely named" do
    assert {:ok, 7, metadata} =
             Executor.execute_count_with_metadata(
               duplicate_name_query(RecordingAdapter, self()),
               analyze_complexity: false
             )

    assert_received {:executed, sql, [3]}
    assert sql == metadata.sql
    assert sql =~ ~r/^SELECT COUNT\(\*\) AS selecto_total_count FROM \(/
    assert sql =~ ") AS selecto_count_source"

    assert projected_names(sql) ==
             ["selecto_projection_1", "selecto_projection_2", "selecto_projection_3"]

    assert sql =~ "selecto_root.name AS selecto_projection_1"
    assert sql =~ "category.name AS selecto_projection_2"
  end

  test "grouped count keeps its GROUP BY on the source expressions" do
    grouped =
      RecordingAdapter
      |> duplicate_name_query(self())
      |> Map.update!(:set, &Map.put(&1, :selected, ["name", "category.name"]))
      |> Selecto.group_by(["name", "category.name"])

    assert {:ok, 7, _metadata} =
             Executor.execute_count_with_metadata(grouped, analyze_complexity: false)

    assert_received {:executed, sql, [3]}
    assert sql =~ ~r/group by\s+selecto_root\.name, category\.name/i
    assert projected_names(sql) == ["selecto_projection_1", "selecto_projection_2"]
  end

  test "projection sum reads the projected column through its unique alias" do
    assert {:ok, 7, metadata} =
             Selecto.execute_projection_sum_with_metadata(
               duplicate_name_query(RecordingAdapter, self()),
               "total",
               analyze_complexity: false
             )

    assert_received {:executed, sql, [3]}
    assert sql == metadata.sql
    assert sql =~ "SUM(selecto_projection_source.`selecto_projection_3`)"
    assert sql =~ "selecto_root.price AS selecto_projection_3"
  end

  test "set operations alias each operand's projection" do
    left = duplicate_name_query(SelectoDBMSSQL.Adapter)
    right = duplicate_name_query(SelectoDBMSSQL.Adapter)

    {sql, _aliases, params} =
      left
      |> Selecto.union(right, all: true)
      |> Selecto.gen_sql(unique_projection_aliases: true)

    assert length(projected_names(sql)) == 6
    assert params == [3, 3]
  end
end
