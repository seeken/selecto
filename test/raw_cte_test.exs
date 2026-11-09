defmodule Selecto.Builder.RawCteTest do
  use ExUnit.Case, async: true

  alias Selecto.Builder.RawCte

  @all [:postgresql, :mysql, :mariadb, :sqlite, :duckdb, :any]

  test "reads every name of plain definitions, in every dialect" do
    for d <- @all do
      assert RawCte.names("r AS (SELECT 1)", d) == {:ok, ["r"]}
      assert RawCte.names("x13 AS (SELECT 1 AS v), r AS (SELECT 2)", d) == {:ok, ["x13", "r"]}
      assert RawCte.names("r(id, v) AS (SELECT 1, 2)", d) == {:ok, ["r"]}
      assert RawCte.names("r AS NOT MATERIALIZED (SELECT 1)", d) == {:ok, ["r"]}
      assert RawCte.names("R AS materialized (SELECT 1)", d) == {:ok, ["R"]}
      assert RawCte.names("/* c */ r AS (SELECT 1)", d) == {:ok, ["r"]}
      assert RawCte.names("-- c\n r AS (SELECT 1) -- end", d) == {:ok, ["r"]}
      assert RawCte.names("`r` AS (SELECT 1)", d) == {:ok, ["r"]}

      assert RawCte.names("x AS (SELECT 1) /* c */ , /* d */ r AS (SELECT 2)", d) ==
               {:ok, ["x", "r"]}
    end
  end

  test "double quotes: names everywhere but on MySQL and MariaDB" do
    for d <- [:postgresql, :sqlite, :duckdb] do
      assert RawCte.entries(~S[KU AS (SELECT 1), "Kq" AS (SELECT 2)], d) ==
               {:ok, [{"KU", false}, {"Kq", true}]}

      assert RawCte.names(~S["R""x" AS (SELECT "a)b" FROM t)], d) == {:ok, [~S[R"x]]}
    end

    for d <- [:mysql, :mariadb, :any] do
      assert RawCte.names(~S["r" AS (SELECT 1)], d) == :error
      assert RawCte.names(~S[r AS (SELECT "a")], d) == :error
    end
  end

  test "brackets name a CTE only on SQLite" do
    assert RawCte.names("[p] AS (SELECT [a)b] FROM t)", :sqlite) == {:ok, ["p"]}
    assert RawCte.names("[p] AS (SELECT 1)", :postgresql) == :error
  end

  test "MySQL and MariaDB comments that read differently are refused" do
    for d <- [:mysql, :mariadb, :any] do
      for text <- [
            "r AS (SELECT 1) # c",
            "r AS (SELECT 1 #c\n)",
            "r AS (SELECT 1 --c\n)",
            "/*! r AS */ x AS (SELECT 1)",
            "r AS (SELECT 1) --"
          ] do
        assert RawCte.names(text, d) == :error, "#{d}: #{text}"
      end
    end

    assert RawCte.names("r AS (SELECT 1 # 2\n)", :postgresql) == {:ok, ["r"]}
    assert RawCte.names("r AS (SELECT 1 --c\n)", :sqlite) == {:ok, ["r"]}
  end

  test "block comments nest only on PostgreSQL" do
    text = "/* a /* nested */ b */ r AS (SELECT 1)"
    assert RawCte.names(text, :postgresql) == {:ok, ["r"]}

    for d <- [:mysql, :mariadb, :sqlite, :duckdb, :any] do
      assert RawCte.names(text, d) == :error
    end
  end

  test "dollar quotes: read on PostgreSQL, refused elsewhere; a $ inside a name never opens one" do
    body = ~S[SELECT ') x AS (' AS a, $t$ ) $t$ AS c, $1 AS d /* ) */ -- )
    FROM t]

    assert RawCte.names("r AS (#{body}), s AS (SELECT 1)", :postgresql) == {:ok, ["r", "s"]}

    for d <- [:mysql, :mariadb, :sqlite, :duckdb, :any] do
      assert RawCte.names("r AS (SELECT $t$ x $t$), s AS (SELECT 1)", d) == :error
    end

    # a$q$ is an identifier: the next definition is read.
    for d <- @all do
      assert RawCte.names("x AS (SELECT a$q$ FROM t), r AS (SELECT 1 AS q$)", d) ==
               {:ok, ["x", "r"]},
             inspect(d)
    end
  end

  test "iodata text with {:param, value} markers reads as text" do
    text = [
      "x14 AS (SELECT ",
      {:param, 1},
      "::int AS pid), ",
      ["r AS (SELECT ", {:param, "a"}, ")"]
    ]

    assert RawCte.names(text, :postgresql) == {:ok, ["x14", "r"]}
    assert RawCte.names(["r AS (SELECT ", {:other, 1}, ")"], :postgresql) == :error
  end

  test "refuses text it cannot read" do
    for d <- @all,
        text <- [
          "SELECT 1",
          "r AS (SELECT 1",
          "r AS (SELECT 1) junk",
          "r AS (SELECT 1),",
          ~S[r AS (SELECT 'a\'), q AS (SELECT 1')],
          "r (SELECT 1)",
          "/* open r AS (SELECT 1)",
          "é AS (SELECT 1)",
          "RECURSIVE r AS (SELECT 1)"
        ] do
      assert RawCte.names(text, d) == :error, "#{d}: #{text}"
    end
  end
end
