defmodule Selecto.ParamValuesTest do
  use ExUnit.Case, async: true

  alias Selecto.SQL.ParamValues

  @mysql [decimal: :mysql, years: true, float_atoms: true]
  @double [decimal: :double, years: true, float_atoms: true]

  defmodule OperandAdapter do
    @moduledoc false
    def placeholder(index), do: "$#{index}"
    def comparison_operand(param, :equality), do: ["EQ(", param, ")"]
    def comparison_operand(param, :inequality), do: ["NE(", param, ")"]
    def comparison_operand(param, :range), do: ["RANGE(", param, ")"]
  end

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

  test "dialect rules refuse only values the database gets wrong" do
    assert {:error, _, :decimal_non_finite} = ParamValues.check(Decimal.new("NaN"), @mysql)
    assert {:error, _, :decimal_non_finite} = ParamValues.check(Decimal.new("-Infinity"), @double)

    assert {:error, _, :decimal_non_finite} =
             ParamValues.check(Decimal.new("NaN"), decimal: :finite)

    # MySQL and MariaDB read a decimal into nine 9-digit words; one needing
    # more compares as another number. Decimal.div results and the like fit.
    digits = fn scale ->
      coef =
        String.to_integer(String.duplicate("1", 30) <> String.duplicate("0", scale - 1) <> "4")

      %Decimal{sign: 1, coef: coef, exp: -scale}
    end

    over = digits.(46)

    for value <- [Decimal.new("-1e400"), Decimal.new("1.5e81"), Decimal.new("1.5e-73"), over],
        do: assert({:error, _, :decimal_range} = ParamValues.check(value, @mysql))

    fits = digits.(45)

    for value <- ["1.50", "1e-31", "-1e-50", "1e64", "1.5e-71", "0", "-99999.99"],
        do: assert(:ok = ParamValues.check(Decimal.new(value), @mysql))

    assert :ok = ParamValues.check(fits, @mysql)

    assert :ok = ParamValues.check(Decimal.div(1, 3), @mysql)
    assert :ok = ParamValues.check(Decimal.new("-1e400"), decimal: :finite)

    # SQLite: within the double range, however many digits.
    long = %Decimal{sign: 1, coef: 14_999_999_999_999_999_999_999_999_999_999_999_999, exp: -37}
    assert :ok = ParamValues.check(long, @double)

    for value <- ["1e-400", "1e400"],
        do: assert({:error, _, :decimal_range} = ParamValues.check(Decimal.new(value), @double))

    for value <- ["1.50", "1234567890123456789", "12345678901234567890.123", "1e-300", "0.000"],
        do: assert(:ok = ParamValues.check(Decimal.new(value), @double))

    assert :ok = ParamValues.check(Decimal.from_float(0.1 + 0.2), @double)

    for value <- [~D[9999-12-31], ~N[0001-01-01 00:00:00], ~D[0000-01-01]],
        do: assert(:ok = ParamValues.check(value, @mysql))

    for value <- [Date.new!(10_000, 1, 1), NaiveDateTime.new!(10_000, 1, 1, 0, 0, 0)],
        do: assert({:error, _, :date_range} = ParamValues.check(value, @mysql))

    for value <- [:nan, :inf, :"-inf"],
        do: assert({:error, _, :float_non_finite} = ParamValues.check(value, @double))

    assert :ok = ParamValues.check(Decimal.new("NaN"), [])
    assert :ok = ParamValues.check(nil, @mysql)
    assert :ok = ParamValues.check(true, @mysql)
  end

  test "SQLite refuses only a Decimal its 19-digit read turns to an infinity or to 0" do
    max = %Decimal{sign: 1, coef: 17_976_931_348_623_157, exp: 292}

    # SQLite keeps 19 significant digits, cut: everything below
    # 1.797693134862315808e308 stores the largest double (measured live).
    band = %Decimal{
      sign: 1,
      coef: 1_797_693_134_862_315_807_999_999_999_999_999_999_999_999_999_999_999,
      exp: 257
    }

    first_over = %Decimal{sign: 1, coef: 1_797_693_134_862_315_808, exp: 290}
    long_over = %Decimal{sign: 1, coef: 17_976_931_348_623_158_080_000_001, exp: 283}
    min = %Decimal{sign: 1, coef: 49, exp: -325}
    first_kept = %Decimal{sign: 1, coef: 2_470_328_229_206_232_721, exp: -342}
    # Cut to 2.470328229206232720e-324, which SQLite reads as 0.0.
    last_zero = %Decimal{sign: 1, coef: 2_470_328_229_206_232_720_999, exp: -345}

    for value <- [
          Decimal.new("1e308"),
          max,
          band,
          %Decimal{band | sign: -1},
          Decimal.negate(max),
          Decimal.new("1e-308"),
          min,
          first_kept,
          Decimal.negate(min),
          Decimal.new("0E-400")
        ],
        do: assert(:ok = ParamValues.check(value, @double), inspect(value))

    for value <- [
          first_over,
          long_over,
          Decimal.new("1.7976931348623159e308"),
          %Decimal{first_over | sign: -1},
          last_zero,
          %Decimal{sign: 1, coef: 2_470_328_229_206_232_720_882_538_326, exp: -351},
          Decimal.new("2.4e-324"),
          Decimal.new("-1e-400")
        ],
        do:
          assert(
            {:error, _, :decimal_range} = ParamValues.check(value, @double),
            inspect(value)
          )
  end

  test "text written to a :uuid field must read as a UUID" do
    command = fn value, metadata ->
      {:ok, command} =
        Selecto.Write.Command.new(%{
          operation: :insert,
          relation: "p",
          assignments: [%{field: :uid, value: {:literal, value}}],
          metadata: metadata
        })

      command
    end

    types = %{field_types: %{uid: :uuid}}
    rules = [uuid_text: true]

    for value <- [
          "{9a3c1f7e-2b4d-4e8a-9c1b-7d2e3f4a5b6c}",
          " 9a3c1f7e-2b4d-4e8a-9c1b-7d2e3f4a5b6c",
          "not-a-uuid",
          "0123456789abcde",
          <<0xFF>>
        ] do
      assert {:error,
              %Selecto.Write.Error{
                type: :invalid_value,
                details: %{reason: :parameter_unbindable, unsupported_feature: :uuid_text}
              }} = ParamValues.write_refusal(command.(value, types), rules, :mysql)

      {:ok, batch} = Selecto.Write.Batch.new([command.(value, types)])
      assert {:error, %Selecto.Write.Error{}} = ParamValues.write_refusal(batch, rules, :mysql)

      # A graph row's command takes the field types of its node.
      graph = %Selecto.Write.Graph{
        root: "n",
        nodes: [
          %Selecto.Write.Graph.Node{
            id: "n",
            path: [],
            relation: "p",
            strategy: :ordered,
            field_types: %{"uid" => "uuid"},
            rows: [%Selecto.Write.Graph.Row{id: "r", path: [], command: command.(value, %{})}]
          }
        ]
      }

      assert {:error, %Selecto.Write.Error{}} = ParamValues.write_refusal(graph, rules, :sqlite)

      # Without the rule, or for a field not declared :uuid, it writes as before.
      assert :ok = ParamValues.write_refusal(command.(value, types), [], :postgresql)
      assert :ok = ParamValues.write_refusal(command.(value, %{}), rules, :mysql)
    end

    for value <- [
          "9a3c1f7e-2b4d-4e8a-9c1b-7d2e3f4a5b6c",
          "9A3C1F7E-2B4D-4E8A-9C1B-7D2E3F4A5B6C",
          "9a3c1f7e2b4d4e8a9c1b7d2e3f4a5b6c",
          "urn:uuid:9a3c1f7e-2b4d-4e8a-9c1b-7d2e3f4a5b6c",
          # 16 bytes are a raw UUID (BINARY(16) or BLOB storage).
          UUID.string_to_binary!("9a3c1f7e-2b4d-4e8a-9c1b-7d2e3f4a5b6c"),
          "0123456789abcdef"
        ],
        do: assert(:ok = ParamValues.write_refusal(command.(value, types), rules, :mysql))

    # A value from the write's context is checked as a literal is.
    {:ok, from_context} =
      Selecto.Write.Command.new(%{
        operation: :insert,
        relation: "p",
        assignments: [%{field: :uid, value: {:context, :owner}}],
        metadata: types
      })

    assert {:error, %Selecto.Write.Error{details: %{unsupported_feature: :uuid_text}}} =
             ParamValues.write_refusal(from_context, rules, :mysql,
               context: %{"owner" => "not-a-uuid"}
             )

    assert :ok =
             ParamValues.write_refusal(from_context, rules, :mysql,
               context: %{owner: "9a3c1f7e-2b4d-4e8a-9c1b-7d2e3f4a5b6c"}
             )

    assert :ok = ParamValues.write_refusal(from_context, rules, :mysql)
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

    # Bound as given, as before (a TEXT column declared :decimal compares text).
    assert params == [" 1.50 "]

    {_sql, params} =
      Selecto.to_sql(query() |> Selecto.filter({"score", "1.5"}) |> Selecto.select(["id"]))

    assert params == ["1.5"]
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

  test "an adapter renders the Decimal operand of Selecto's own comparisons by operator" do
    q = %{query() | adapter: OperandAdapter}
    d = Decimal.new("1.5")

    sql = fn filter ->
      {sql, _params} = Selecto.to_sql(q |> Selecto.filter(filter) |> Selecto.select(["id"]))
      sql
    end

    assert sql.({"price", {:=, d}}) =~ ~r/price = EQ\(/
    assert sql.({"price", {:!=, d}}) =~ ~r/price (!=|<>) NE\(/

    assert sql.({"price", d}) =~ ~r/price = EQ\(/

    for op <- [:<, :<=, :>, :>=],
        do: assert(sql.({"price", {op, d}}) =~ ~r/price #{op} RANGE\(/, inspect(op))

    assert sql.({"price", {:between, d, Decimal.new(3)}}) =~ ~r/between RANGE\(.* and RANGE\(/is
    assert sql.({"price", {:in, [d, Decimal.new(3)]}}) =~ ~r/ IN \(EQ\(.*, EQ\(/s
    assert sql.({"price", {:not_in, [d, Decimal.new(3)]}}) =~ ~r/ NOT IN \(NE\(.*, NE\(/s

    # Text, integers and host fragments are never wrapped.
    refute sql.({"price", {:>=, "1.5"}}) =~ ~r/RANGE|EQ\(|NE\(/
    refute sql.({"id", {:>=, 2}}) =~ ~r/RANGE|EQ\(|NE\(/

    host = ["SELECT 1 FROM p x WHERE x.price >= ", {:param, d}, " AND x.name LIKE ", {:param, d}]
    refute sql.({:exists, host}) =~ ~r/RANGE|EQ\(|NE\(/

    assert Selecto.Builder.TypedOperator.operand(q, ">=", {:param, d}) == [
             "RANGE(",
             {:param, d},
             ")"
           ]

    assert Selecto.Builder.TypedOperator.operand(q, "LIKE", {:param, d}) == {:param, d}
    assert Selecto.Builder.TypedOperator.operand(query(), "=", {:param, d}) == {:param, d}
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
