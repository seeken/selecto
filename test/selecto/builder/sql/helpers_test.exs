defmodule Selecto.Builder.Sql.HelpersTest do
  use ExUnit.Case, async: true

  alias Selecto.Builder.Sql.Helpers

  test "maybe_quote_identifier escapes embedded ANSI identifier quotes" do
    assert Helpers.maybe_quote_identifier(~s(report"name)) == ~s("report""name")
  end

  test "quote_identifier delegates escaping to the configured adapter" do
    selecto = %{adapter: Selecto.DB.PostgreSQL}

    assert Helpers.quote_identifier(selecto, "Report Name") == ~s("Report Name")
  end

  test "plain_name? quotes a word reserved in any supported dialect, in any case" do
    for name <- ~w(With Desc Window To Lateral Rank Rows Groups WITH rank qualify pivot glob) do
      refute Helpers.plain_name?(name), name
      assert Helpers.list_identifier(nil, name) == ~s("#{name}")
    end

    for name <- ~w(orders MixK x13 ca _t) do
      assert Helpers.plain_name?(name), name
      assert Helpers.list_identifier(nil, name) == name
    end
  end

  test "on PostgreSQL a reserved-only plain name is quoted folded; elsewhere as written" do
    pg = SelectoDBPostgreSQL.Adapter

    for name <- ~w(Rank RANK First Query Plan Action Position Rows Json With) do
      assert Helpers.list_identifier(pg, name) == ~s("#{String.downcase(name)}"), name
      assert Helpers.raw_identifier(pg, name) == ~s("#{String.downcase(name)}"), name
      assert Helpers.list_identifier(nil, name) == ~s("#{name}"), name
    end

    # Names outside the plain pattern keep their case; plain ones stay bare.
    assert Helpers.list_identifier(pg, "Mix K") == ~s("Mix K")
    assert Helpers.list_identifier(pg, "MixK") == "MixK"
    assert Helpers.raw_identifier(pg, "Ca$x") == ~s("ca$x")
  end
end
