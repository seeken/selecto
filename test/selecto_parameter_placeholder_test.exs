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

  test "DuckDB nests block comments and continues E'' strings across a newline" do
    duck = SelectoDBDuckDB.Adapter

    # A placeholder after a nested comment's inner close is still inside it.
    nested = "SELECT $1 AS c0 /* /* */ ' */, $1 AS c1 --'\n"
    assert Enum.count(Params.rebind_finalized(nested, [5], duck), &is_tuple/1) == 2

    # A segment continuing E'' across a newline reads escapes: its $1 is text.
    continued = "SELECT E'a'\n'\\' $1 ' AS c0 -- '\n, $1 AS c1"
    rebound = Params.rebind_finalized(continued, [5], duck)
    assert Enum.filter(rebound, &is_tuple/1) == [{:param, 5}]

    assert IO.iodata_to_binary(Enum.map(rebound, &if(is_tuple(&1), do: "#", else: &1))) ==
             "SELECT E'a'\n'\\' $1 ' AS c0 -- '\n, # AS c1"
  end

  test "PostgreSQL continues E'' strings, so a mode-dependent continuation refuses" do
    sql = "SELECT $1::text AS c00, E'a'\n'\\' A' AS c0, 'Y\\' , $1::text AS c1 --'"

    assert_raise Selecto.Builder.ScopeRefusal, ~r/backslash/, fn ->
      Params.rebind_finalized(sql, [5], SelectoDBPostgreSQL.Adapter)
    end
  end

  test "zero-padded and underscored placeholders refuse typed" do
    for adapter <- [SelectoDBPostgreSQL.Adapter, SelectoDBDuckDB.Adapter],
        sql <- ["SELECT $1, $01", "SELECT $1, $1_0"] do
      assert_raise Selecto.Builder.ScopeRefusal, ~r/leading zero or an underscore/, fn ->
        Params.rebind_finalized(sql, [5], adapter)
      end
    end
  end

  test "$0, $00 and DuckDB's ? number the next parameter: refused typed" do
    for adapter <- [SelectoDBPostgreSQL.Adapter, SelectoDBDuckDB.Adapter],
        sql <- ["SELECT $1, $0", "SELECT $1, $00"] do
      assert_raise Selecto.Builder.ScopeRefusal, ~r/do not bind/, fn ->
        Params.rebind_finalized(sql, [5], adapter)
      end
    end

    assert_raise Selecto.Builder.ScopeRefusal, ~r/do not bind/, fn ->
      Params.rebind_finalized("SELECT $1, CAST(? AS VARCHAR)", [5], SelectoDBDuckDB.Adapter)
    end

    # On DuckDB a ? in a literal stays text.
    assert Enum.filter(
             Params.rebind_finalized("SELECT $1, 'why?'", [5], SelectoDBDuckDB.Adapter),
             &is_tuple/1
           ) == [{:param, 5}]
  end

  test "an odd placeholder any session mode reads as code refuses" do
    # Under standard_conforming_strings off, '\'' ends where `$01` is code.
    sql = "SELECT 1 WHERE n <> '\\'' AND n = $01 -- '\n AND n = $1"

    assert_raise Selecto.Builder.ScopeRefusal, fn ->
      Params.rebind_finalized(sql, ["a"], SelectoDBPostgreSQL.Adapter)
    end
  end

  test "a nested fragment's placeholder its own params do not bind refuses, params or not" do
    pg = SelectoDBPostgreSQL.Adapter
    duck = SelectoDBDuckDB.Adapter
    lite = SelectoDBSQLite.Adapter

    for {sql, params, adapter} <- [
          {"SELECT 1 WHERE CAST($1 AS text) = '1'", [], pg},
          {"SELECT 1 WHERE x = $01", [], pg},
          {"SELECT 1 WHERE x = $001", [], pg},
          {"SELECT 1 WHERE x = $1 AND y = CAST($3 AS text)", ["a"], pg},
          {"SELECT 1 WHERE x = CAST($2 AS VARCHAR)", ["a"], duck},
          {"SELECT 1 WHERE x = CAST(? AS VARCHAR)", [], duck},
          {"SELECT 1 WHERE x = CAST($0 AS VARCHAR)", [], duck},
          {"SELECT 1 WHERE x = ?1", [], lite},
          {"SELECT 1 WHERE x = ? AND y = ?2", ["a"], lite},
          {"SELECT 1 WHERE x = :name", [], lite},
          {"SELECT 1 WHERE x = ?", [], lite},
          {"SELECT 1 WHERE x = ?", [], SelectoDBMySQL.Adapter},
          {"SELECT 1 WHERE x = ?", [], SelectoDBMariaDB.Adapter}
        ] do
      assert_raise Selecto.Builder.ScopeRefusal, ~r/do not bind/, fn ->
        Params.rebind_finalized(sql, params, adapter)
      end
    end

    # Placeholder-like text in literals and comments of a fragment without
    # params stays as written.
    for {sql, adapter} <- [
          {"SELECT 1 WHERE n <> 'cost $1' /* $2 */ AND m <> $$ $1 $$ -- $3\n", pg},
          {"SELECT 1 WHERE n <> 'why? $1' /* ? */", duck},
          {"SELECT 1 WHERE n <> 'why? :x ?1' /* ? */ -- ?\n", lite},
          {"SELECT 1 WHERE n <> 'why?' /* ? */ # ?\n", SelectoDBMySQL.Adapter}
        ] do
      assert Params.rebind_finalized(sql, [], adapter) == sql
    end
  end

  test "a verbatim nested query, given without params, is checked the same way" do
    domain = %{
      name: "p",
      source: %{
        source_table: "p",
        primary_key: :id,
        fields: [:id],
        redact_fields: [],
        columns: %{id: %{type: :integer}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    query = Selecto.configure(domain, nil, validate: false) |> Selecto.select(["id"])

    for filter <- [
          {:exists, "SELECT 1 FROM p x WHERE CAST($1 AS text) = '1'"},
          {"id", {:subquery, :in, "SELECT id FROM p x WHERE CAST($1 AS text) = '1'"}},
          {"id", "=", {:subquery, :any, "SELECT id FROM p x WHERE CAST($1 AS text) = '1'"}}
        ] do
      assert_raise Selecto.Builder.ScopeRefusal, fn ->
        Selecto.to_sql(Selecto.filter(query, filter))
      end
    end

    assert {_sql, []} =
             Selecto.to_sql(
               Selecto.filter(query, {:exists, "SELECT 1 FROM p x WHERE 'c $1' <> ''"})
             )
  end

  test "a set member's and CTE body's raw $1 is rebound as its own param" do
    domain = fn table ->
      %{
        name: table,
        source: %{
          source_table: table,
          primary_key: :id,
          fields: [:id, :name],
          redact_fields: [],
          columns: %{id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        },
        schemas: %{},
        joins: %{}
      }
    end

    q = fn table -> Selecto.configure(domain.(table), nil, validate: false) end
    left = q.("p") |> Selecto.filter({"name", "L"}) |> Selecto.select(["id"])

    own =
      q.("p")
      |> Selecto.filter({"name", {:!=, "q"}})
      |> Selecto.filter({:raw_sql_filter, "CAST($1 AS text) = 'q'"})
      |> Selecto.select(["id"])

    # The member's raw $1 is its own first param, a copy of "q"; never "L".
    {sql, params} = Selecto.to_sql(Selecto.union(left, own, all: true))
    assert params == ["L", "q", "q"]
    assert sql =~ "CAST($3 AS text) = 'q'"

    {sql, params} =
      q.("c")
      |> Selecto.filter({"name", {:!=, "zz"}})
      |> Selecto.with_cte("c", fn -> own end, columns: ["id"])
      |> Selecto.select(["id"])
      |> Selecto.to_sql()

    # The body's raw $1 is the body's "q"; never the outer "zz".
    assert params == ["q", "q", "zz"]
    assert sql =~ "CAST($2 AS text) = 'q'"

    unbound =
      q.("p")
      |> Selecto.filter({:raw_sql_filter, "CAST($1 AS text) = '1'"})
      |> Selecto.select(["id"])

    assert_raise Selecto.Builder.ScopeRefusal, fn ->
      Selecto.to_sql(Selecto.union(left, unbound, all: true))
    end
  end

  test "a bare $n beside a value-aware wrapped placeholder refuses" do
    price = Decimal.new("1.25")

    # The wrapped form binds; the bare `$1` of the same param would bind a
    # value of the statement around the fragment.
    for sql <- ["x >= CAST($1 AS NUMERIC) AND $1 > 1", "$1 > 1", "CAST($1 AS NUMERIC) = $2"] do
      assert_raise Selecto.Builder.ScopeRefusal, ~r/count does not match/, fn ->
        Params.rebind_finalized(sql, [price], ExternalTypedAdapter)
      end
    end

    # A bare `$1` of a param rendered bare still binds, beside a wrapped one.
    rebound =
      Params.rebind_finalized("CAST($1 AS NUMERIC) > $2", [price, 1], ExternalTypedAdapter)

    assert Enum.filter(rebound, &is_tuple/1) == [{:param, price}, {:param, 1}]

    # A `$1` in a literal stays text.
    assert Params.rebind_finalized("CAST($1 AS NUMERIC) <> '$1'", [price], ExternalTypedAdapter)
           |> Enum.filter(&is_tuple/1) == [{:param, price}]
  end

  test "an integer element of marker iodata is read as the text it renders" do
    domain = %{
      name: "p",
      source: %{
        source_table: "p",
        primary_key: :id,
        fields: [:id],
        redact_fields: [],
        columns: %{id: %{type: :integer}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    query = Selecto.configure(domain, nil, validate: false) |> Selecto.select(["id"])
    held = ["SELECT 1 FROM p x WHERE CAST($", 1, " AS text) = ", {:param, "a"}]

    assert_raise Selecto.Builder.ScopeRefusal, ~r/do not bind/, fn ->
      Selecto.to_sql(Selecto.filter(query, {:exists, held}))
    end

    # A number that renders no placeholder stays as written.
    plain = ["SELECT 1 FROM p x WHERE x.id = ", 1, " AND x.id <> ", {:param, 2}]
    {sql, params} = Selecto.to_sql(Selecto.filter(query, {:exists, plain}))
    assert params == [2]
    assert sql =~ "x.id = 1 AND x.id <> $1"
  end

  test "an adapter's unsupported SQL shape refuses typed with its error" do
    error =
      Selecto.Error.validation_error("Adapter does not support this collection operation", %{
        unsupported_feature: :collection
      })

    refusal = catch_error(Selecto.Builder.ScopeRefusal.unsupported!(error))
    assert %Selecto.Builder.ScopeRefusal{reason: :unsupported_feature} = refusal

    assert %Selecto.Error{type: :validation_error, details: details} =
             Selecto.Error.from_reason(refusal)

    assert details.reason == :unsupported_feature
    assert details.unsupported_feature == :collection

    # A lateral the adapter cannot render refuses as every lateral refusal does.
    lateral = catch_error(Selecto.Builder.ScopeRefusal.lateral!(error))

    assert %Selecto.Error{type: :query_enforcement, details: %{reason: :lateral_unsupported}} =
             Selecto.Error.from_reason(lateral)
  end
end
