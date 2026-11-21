defmodule Selecto.GroupByPositionStrategyTest do
  use ExUnit.Case, async: true

  defmodule ExpressionDialect do
    def query_strategy(:group_by_position, _selecto), do: :expression
    def query_strategy(_strategy, _selecto), do: :not_implemented
  end

  defmodule ExpressionAdapter do
    def name, do: :sqlite
    def dialect, do: ExpressionDialect
    defdelegate placeholder(index), to: SelectoDBSQLite.Adapter
    defdelegate quote_identifier(identifier), to: SelectoDBSQLite.Adapter
  end

  defp domain do
    %{
      name: "Sales",
      source: %{
        source_table: "sales",
        primary_key: :id,
        fields: [:id, :region, :amount],
        redact_fields: [],
        columns: %{id: %{type: :integer}, region: %{type: :string}, amount: %{type: :decimal}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp grouped_sql(adapter, group_by) do
    query =
      domain()
      |> Selecto.configure(:compile_only)
      |> Selecto.select([{:field, "region", "k0"}, {:field, {:count, "id"}, "a0"}])
      |> Selecto.group_by(group_by)

    {sql, _aliases, _params} = Selecto.gen_sql(%{query | adapter: adapter}, [])

    sql |> String.replace(~r/\s+/, " ") |> String.downcase()
  end

  test "a positional group_by stays positional by default" do
    assert grouped_sql(SelectoDBSQLite.Adapter, [{:literal_position, 1}]) =~ "group by 1"
  end

  test "an expression dialect groups a position by the selected expression" do
    sql = grouped_sql(ExpressionAdapter, [{:literal_position, 1}])

    assert sql =~ "group by selecto_root.region"
    refute sql =~ ~r/group by \d/
  end

  test "an expression dialect refuses a position outside the selection" do
    assert_raise ArgumentError, ~r/position 3/, fn ->
      grouped_sql(ExpressionAdapter, [{:literal_position, 3}])
    end
  end
end
