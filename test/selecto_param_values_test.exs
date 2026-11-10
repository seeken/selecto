defmodule Selecto.ParamValuesTest do
  use ExUnit.Case, async: true

  alias Selecto.SQL.ParamValues

  @mysql [decimal: :mysql, years: true, float_atoms: true]
  @double [decimal: :double, years: true, float_atoms: true]

  defp domain do
    %{
      name: "p",
      source: %{
        source_table: "p",
        primary_key: :id,
        fields: [:id, :name, :price, :score, :ts, :d],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          price: %{type: :decimal},
          score: %{type: :float},
          ts: %{type: :naive_datetime},
          d: %{type: :date}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp query(opts \\ []),
    do: Selecto.configure(domain(), nil, Keyword.put(opts, :validate, false))

  defp refusal(filter, opts \\ []) do
    refusal =
      assert_raise Selecto.Builder.ScopeRefusal, fn ->
        Selecto.to_sql(query(opts) |> Selecto.filter(filter) |> Selecto.select(["id"]))
      end

    {refusal.reason, Selecto.Error.from_reason(refusal)}
  end

  test "dialect rules: non-finite, out-of-range and over-precise decimals, years, float atoms" do
    assert {:error, _, :decimal_non_finite} = ParamValues.check(Decimal.new("NaN"), @mysql)
    assert {:error, _, :decimal_non_finite} = ParamValues.check(Decimal.new("-Infinity"), @double)

    # DECIMAL(65,30): -1e400 has 401 digits, 1e-31 and -1e-50 too many after the point.
    for value <- ["-1e400", "1e-31", "-1e-50"],
        do: assert({:error, _, :decimal_range} = ParamValues.check(Decimal.new(value), @mysql))

    for value <- ["1.50", "1e-30", "1e64", "0", "-99999.99"],
        do: assert(:ok = ParamValues.check(Decimal.new(value), @mysql))

    # A double: fifteen significant digits, within its range.
    long = %Decimal{sign: 1, coef: 14_999_999_999_999_999_999_999_999_999_999_999_999, exp: -37}
    assert {:error, _, :decimal_range} = ParamValues.check(long, @double)

    for value <- ["1e-400", "1e400"],
        do: assert({:error, _, :decimal_range} = ParamValues.check(Decimal.new(value), @double))

    for value <- ["1.50", "123456789012345", "1e-300", "0.000"],
        do: assert(:ok = ParamValues.check(Decimal.new(value), @double))

    for value <- [~D[9999-12-31], ~N[0001-01-01 00:00:00]],
        do: assert(:ok = ParamValues.check(value, @mysql))

    for value <- [Date.new!(10_000, 1, 1), NaiveDateTime.new!(10_000, 1, 1, 0, 0, 0)],
        do: assert({:error, _, :date_range} = ParamValues.check(value, @mysql))

    for value <- [:nan, :inf, :"-inf"],
        do: assert({:error, _, :float_non_finite} = ParamValues.check(value, @double))

    assert :ok = ParamValues.check(Decimal.new("NaN"), [])
    assert :ok = ParamValues.check(nil, @mysql)
    assert :ok = ParamValues.check(true, @mysql)
  end

  test "a write's first unbindable value refuses as a write error" do
    {:ok, command} =
      Selecto.Write.Command.new(%{
        operation: :insert,
        relation: "p",
        assignments: [
          %{field: :id, value: {:literal, 1}},
          %{field: :price, value: {:literal, Decimal.new("NaN")}}
        ]
      })

    assert {:error,
            %Selecto.Write.Error{
              type: :invalid_value,
              details: %{reason: :parameter_unbindable, unsupported_feature: :decimal_non_finite}
            }} = ParamValues.write_refusal(command, @mysql, :mysql)

    assert :ok = ParamValues.write_refusal(command, [], :postgresql)
  end

  test "a decimal or float field's text value must be a finite number" do
    for value <- ["NaN", "Infinity", "-inf", "abc", "1.5x", "", <<0xFF>>, %{a: 1}, {1, 2}] do
      assert {:invalid_filter_value, %Selecto.Error{details: %{type: :decimal}}} =
               refusal({"price", {:>=, value}})
    end

    assert {:invalid_filter_value, _} = refusal({"score", "NaN"})

    {_sql, params} =
      Selecto.to_sql(
        query()
        |> Selecto.filter({"price", {:>=, " 1.50 "}})
        |> Selecto.select(["id"])
      )

    assert params == [Decimal.new("1.50")]

    {_sql, params} =
      Selecto.to_sql(query() |> Selecto.filter({"score", "1.5"}) |> Selecto.select(["id"]))

    assert params == [1.5]
  end

  test "a Decimal compared with a float field must be a double" do
    for value <- ["1e-400", "-1e400"],
        do: assert({:invalid_filter_value, _} = refusal({"score", Decimal.new(value)}))

    {_sql, params} =
      Selecto.to_sql(
        query()
        |> Selecto.filter({"score", Decimal.new("1.5")})
        |> Selecto.select(["id"])
      )

    assert params == [Decimal.new("1.5")]
  end

  test "a text field's value must be valid text without NUL" do
    for value <- ["b" <> <<0>>, <<0xFF, 0xFE>>],
        do: assert({:invalid_filter_value, _} = refusal({"name", value}))
  end

  test "unparseable date and datetime text refuses typed, naming no value" do
    for {field, value} <- [{"ts", "abc secret"}, {"d", "2024-13-45 secret"}] do
      assert {:invalid_filter_value, %Selecto.Error{message: message}} =
               refusal({field, {:>=, value}})

      refute message =~ "secret"
    end
  end

  test "marker iodata holding an element with no SQL text form refuses typed" do
    for element <- [%{a: 1}, {1, 2}, self()] do
      fragment = ["SELECT 1 FROM p x WHERE x.id = ", element, " AND x.name <> ", {:param, "zz"}]

      assert_raise Selecto.Builder.ScopeRefusal, ~r/no SQL text form/, fn ->
        Selecto.to_sql(query() |> Selecto.filter({:exists, fragment}) |> Selecto.select(["id"]))
      end
    end
  end

  test "DuckDB compares each Decimal of an IN list as = and <> compare it" do
    duck = %{query() | adapter: SelectoDBDuckDB.Adapter}
    values = [Decimal.new("1e-31"), Decimal.new(99)]

    {sql, params} =
      Selecto.to_sql(duck |> Selecto.filter({"price", {:in, values}}) |> Selecto.select(["id"]))

    assert params == values
    refute sql =~ " IN ("
    assert sql =~ ~r/selecto_root\.price = .* OR .*selecto_root\.price = /s

    {sql, _params} =
      Selecto.to_sql(
        duck
        |> Selecto.filter({"price", {:not_in, values}})
        |> Selecto.select(["id"])
      )

    assert sql =~ ~r/selecto_root\.price <> .* AND .*selecto_root\.price <> /s

    # Other adapters, and non-Decimal lists, keep IN.
    {sql, _params} =
      Selecto.to_sql(
        query()
        |> Selecto.filter({"price", {:in, values}})
        |> Selecto.select(["id"])
      )

    assert sql =~ "price = ANY" or sql =~ " IN ("
  end
end
