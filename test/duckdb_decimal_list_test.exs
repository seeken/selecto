defmodule Selecto.DuckDBDecimalListTest do
  # DuckDB renders a Decimal parameter as a scalar subquery that keeps its own
  # type; a couple of hundred of those in one statement overflowed DuckDB's
  # planner and killed the VM. A list of two or more members holding a Decimal
  # is one subquery over a derived table that projects each Decimal
  # (`%TypedParam{cast: :projected}`), so a long list adds no subquery per
  # value. The comparisons and their three-valued answer are unchanged.
  use ExUnit.Case, async: true

  defmodule ProjectingDuck do
    def name, do: :duckdb
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(id), do: "\"#{String.replace(to_string(id), "\"", "\"\"")}\""
    def supports?(_feature), do: false
    def connect(connection), do: {:ok, connection}
    def projected_parameters?, do: true

    def parameter_placeholder(index, %Decimal{} = value),
      do: ["(SELECT CAST(", placeholder(index), " AS DECIMAL(38,#{scale(value)})))"]

    def parameter_placeholder(index, %Selecto.SQL.TypedParam{cast: :projected, value: value}),
      do: ["CAST(", placeholder(index), " AS DECIMAL(38,#{scale(value)}))"]

    def parameter_placeholder(index, _value), do: placeholder(index)

    defp scale(value), do: max(-value.exp, 0)
  end

  defmodule PlainDuck do
    def name, do: :duckdb
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(id), do: "\"#{String.replace(to_string(id), "\"", "\"\"")}\""
    def supports?(_feature), do: false
    def connect(connection), do: {:ok, connection}

    def parameter_placeholder(index, %Decimal{}),
      do: ["(SELECT CAST(", placeholder(index), " AS DECIMAL(38,1)))"]

    def parameter_placeholder(index, _value), do: placeholder(index)
  end

  @domain %{
    name: "t",
    schemas: %{},
    joins: %{},
    source: %{
      source_table: "t",
      primary_key: :id,
      fields: [:id, :d],
      redact_fields: [],
      columns: %{id: %{type: :integer}, d: %{type: :decimal}},
      associations: %{}
    }
  }

  defp sql(adapter, filter) do
    @domain
    |> Selecto.configure(:mock_connection, adapter: adapter, validate: false)
    |> Selecto.filter(filter)
    |> Selecto.select(["id"])
    |> Selecto.to_sql()
  end

  test "a Decimal list is one subquery over its projected values" do
    list = [Decimal.new("0"), nil, 3, Decimal.new("1.5")]

    for {filter, operator, joiner} <- [
          {{"d", {:in, list}}, "=", "OR"},
          {{"d", {:not_in, list}}, "<>", "AND"}
        ] do
      {sql, params} = sql(ProjectingDuck, filter)
      # Comparisons bind first, then the projected Decimals.
      assert params == [nil, 3, Decimal.new("0"), Decimal.new("1.5")]

      assert String.replace(sql, ~r/\s+/, " ") =~
               "(SELECT ((selecto_root.d #{operator} selecto_decimal_list.selecto_decimal_1) " <>
                 "#{joiner} (selecto_root.d #{operator} $1) " <>
                 "#{joiner} (selecto_root.d #{operator} $2) " <>
                 "#{joiner} (selecto_root.d #{operator} selecto_decimal_list.selecto_decimal_2)) " <>
                 "FROM (SELECT CAST($3 AS DECIMAL(38,0)) AS selecto_decimal_1, " <>
                 "CAST($4 AS DECIMAL(38,1)) AS selecto_decimal_2) AS selecto_decimal_list)"

      # No Decimal takes a scalar subquery of its own.
      refute sql =~ ~r/\(SELECT CAST\(\$\d+ AS DECIMAL\(38,\d+\)\)\)/
    end
  end

  test "2000 Decimals add one subquery, not 2000; one Decimal adds none" do
    list = Enum.map(1..2000, &Decimal.new("#{&1}.5"))
    {sql, params} = sql(ProjectingDuck, {"d", {:in, list}})
    assert params == list
    assert length(:binary.matches(sql, "SELECT")) == 2
    assert length(:binary.matches(sql, " AS DECIMAL(38,1)) AS selecto_decimal_")) == 2000

    # A single Decimal, or an adapter that cannot project, keeps the plain
    # comparisons.
    {sql, _params} = sql(ProjectingDuck, {"d", {:in, [Decimal.new("1.5")]}})
    assert sql =~ "selecto_root.d = (SELECT CAST($1 AS DECIMAL(38,1)))"
    refute sql =~ "selecto_decimal_list"

    {sql, _params} = sql(PlainDuck, {"d", {:in, [Decimal.new("1.5"), Decimal.new("2.5")]}})
    assert sql =~ "selecto_root.d = (SELECT CAST($1 AS DECIMAL(38,1)))"
    assert sql =~ "selecto_root.d = (SELECT CAST($2 AS DECIMAL(38,1)))"
    refute sql =~ "selecto_decimal_list"
  end
end
