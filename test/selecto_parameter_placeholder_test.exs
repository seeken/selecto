defmodule Selecto.ParameterPlaceholderTest do
  use ExUnit.Case, async: true

  alias Selecto.SQL.Params

  defmodule ExternalTypedAdapter do
    def placeholder(index), do: "$#{index}"

    def parameter_placeholder(index, %Decimal{}),
      do: ["CAST(", placeholder(index), " AS NUMERIC)"]

    def parameter_placeholder(index, _value), do: placeholder(index)
  end

  defmodule LegacyAdapter do
    def placeholder(_index), do: "?"
  end

  test "external value-aware rendering preserves values and rebinds complete placeholders" do
    params = [Decimal.new("20.2501"), "' OR 1=1 --", Decimal.new("10.5001")]

    fragments = [
      "x = ",
      {:param, Enum.at(params, 0)},
      " AND y = ",
      {:param, Enum.at(params, 1)},
      " AND z = ",
      {:param, Enum.at(params, 2)}
    ]

    {sql, ^params} = Params.finalize(fragments, adapter: ExternalTypedAdapter)
    assert sql == "x = CAST($1 AS NUMERIC) AND y = $2 AND z = CAST($3 AS NUMERIC)"
    rebound = Params.rebind_finalized(sql, params, ExternalTypedAdapter)
    assert Params.finalize(rebound, adapter: ExternalTypedAdapter) == {sql, params}

    assert Params.finalize(fragments, adapter: LegacyAdapter) ==
             {"x = ? AND y = ? AND z = ?", params}
  end

  test "rebinding skips placeholder-like text in strings, comments, quotes and dollar quotes" do
    pg = SelectoDBPostgreSQL.Adapter

    sql =
      "SELECT 'cost $1', $1 /* $1 */, \"w$1\", $$a $1$$, a$1, E'\\' $1', $1 -- $1\n, $2"

    rebound = Params.rebind_finalized(sql, [:a, :b], pg)
    assert Enum.count(rebound, &(&1 == {:param, :a})) == 2
    assert Enum.count(rebound, &(&1 == {:param, :b})) == 1

    assert IO.iodata_to_binary(Enum.map(rebound, &if(is_tuple(&1), do: "#", else: &1))) ==
             "SELECT 'cost $1', # /* $1 */, \"w$1\", $$a $1$$, a$1, E'\\' $1', # -- $1\n, #"

    for adapter <- [SelectoDBMySQL.Adapter, SelectoDBMariaDB.Adapter, SelectoDBSQLite.Adapter] do
      sql = "SELECT 'x ?', \"y ?\", `z?`, ? /* ? */ -- ?\n"
      sql = if adapter == SelectoDBSQLite.Adapter, do: sql <> ", [w?]", else: sql <> " # ?\n"
      rebound = Params.rebind_finalized(sql, [7], adapter)
      assert Enum.filter(rebound, &is_tuple/1) == [{:param, 7}], inspect(adapter)

      assert IO.iodata_to_binary(Enum.map(rebound, &if(is_tuple(&1), do: "?", else: &1))) ==
               sql
    end
  end

  test "a nested fragment whose placeholders depend on the session's backslash mode refuses" do
    ambiguous = [
      {SelectoDBPostgreSQL.Adapter, "SELECT 1 WHERE name <> 'O\\'Brien' AND id = $1"},
      {SelectoDBPostgreSQL.Adapter, "SELECT 1 WHERE name <> 'O\\'x $1' AND id = $1"},
      {SelectoDBMySQL.Adapter, "SELECT 1 WHERE path <> 'C:\\' AND id = ?"},
      {SelectoDBMariaDB.Adapter, ~S[SELECT 1 WHERE path <> "C:\" AND id = ?]}
    ]

    for {adapter, sql} <- ambiguous do
      assert_raise Selecto.Builder.ScopeRefusal, ~r/backslash/, fn ->
        Params.rebind_finalized(sql, [5], adapter)
      end
    end

    # A backslash that reads the same either way, and DuckDB's E'' escapes.
    same =
      Params.rebind_finalized(
        "SELECT 1 WHERE p <> 'C:\\x' AND id = $1 ",
        [5],
        SelectoDBPostgreSQL.Adapter
      )

    assert Enum.filter(same, &is_tuple/1) == [{:param, 5}]

    rebound = Params.rebind_finalized("SELECT E'it\\'s $1', $1", [5], SelectoDBDuckDB.Adapter)
    assert Enum.filter(rebound, &is_tuple/1) == [{:param, 5}]
    assert IO.iodata_to_binary(Enum.reject(rebound, &is_tuple/1)) == "SELECT E'it\\'s $1', "
  end

  test "a nested fragment whose placeholders its params do not match refuses typed" do
    assert_raise Selecto.Builder.ScopeRefusal, ~r/placeholder count/, fn ->
      Params.rebind_finalized("SELECT 1", [5], SelectoDBMySQL.Adapter)
    end
  end
end
