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

  # Each case maps every dialect to the names the database reads, or :error
  # where the text is refused.
  @adversarial [
    # a10, a11: a non-ASCII byte is an identifier character, so the `$` after
    # it continues the name and opens no dollar quote.
    {"ca AS (SELECT 1 AS ä$$), za AS (SELECT 2 AS v), cb AS (SELECT 3 AS ö$$)",
     all: {:ok, ["ca", "za", "cb"]}},
    {"ca AS (SELECT 1 AS ä$t$), za AS (SELECT 2 AS v), cb AS (SELECT 3 AS ö$t$)",
     all: {:ok, ["ca", "za", "cb"]}},
    # a13, a14: a -- comment ends at a carriage return on PostgreSQL and DuckDB
    # only; :any cannot tell, so it refuses.
    {"ca AS (SELECT 1 AS v) -- c\r, za AS (SELECT 1 AS v) -- e\n",
     postgresql: {:ok, ["ca", "za"]},
     duckdb: {:ok, ["ca", "za"]},
     mysql: {:ok, ["ca"]},
     mariadb: {:ok, ["ca"]},
     sqlite: {:ok, ["ca"]},
     any: :error},
    {"ca AS (SELECT 1 AS v -- c\r), za AS (SELECT 1 AS v -- e\n)",
     postgresql: {:ok, ["ca", "za"]},
     duckdb: {:ok, ["ca", "za"]},
     mysql: {:ok, ["ca"]},
     mariadb: {:ok, ["ca"]},
     sqlite: {:ok, ["ca"]},
     any: :error},
    # a15, a16: MariaDB runs /*M! comments; refused on MySQL and MariaDB.
    {"ca AS (SELECT 1 AS v) /*M! , za AS (SELECT 1 AS v) */",
     postgresql: {:ok, ["ca"]},
     duckdb: {:ok, ["ca"]},
     sqlite: {:ok, ["ca"]},
     mysql: :error,
     mariadb: :error,
     any: :error},
    {"ca AS (SELECT 1 AS v) /*M!100100 , za AS (SELECT 1 AS v) */",
     postgresql: {:ok, ["ca"]},
     duckdb: {:ok, ["ca"]},
     sqlite: {:ok, ["ca"]},
     mysql: :error,
     mariadb: :error,
     any: :error},
    # a17-a19: SQLite reads $x(...), @x(...) and :x(...) as one parameter
    # token; refused on SQLite and :any.
    {"ca AS (SELECT $x(') AS v), za AS (SELECT 2 AS v), cb AS (SELECT $y(') AS w)",
     postgresql: {:ok, ["ca"]},
     duckdb: {:ok, ["ca"]},
     mysql: {:ok, ["ca"]},
     mariadb: {:ok, ["ca"]},
     sqlite: :error,
     any: :error},
    {"ca AS (SELECT @x(') AS v), za AS (SELECT 2 AS v), cb AS (SELECT @y(') AS w)",
     postgresql: {:ok, ["ca"]},
     duckdb: {:ok, ["ca"]},
     mysql: {:ok, ["ca"]},
     mariadb: {:ok, ["ca"]},
     sqlite: :error,
     any: :error},
    {"ca AS (SELECT :x(') AS v), za AS (SELECT 2 AS v), cb AS (SELECT :y(') AS w)",
     postgresql: {:ok, ["ca"]},
     duckdb: {:ok, ["ca"]},
     mysql: {:ok, ["ca"]},
     mariadb: {:ok, ["ca"]},
     sqlite: :error,
     any: :error}
  ]

  test "adversarial texts read as each database reads them, or are refused" do
    for {text, expected} <- @adversarial, d <- @all do
      want = Keyword.get(expected, :all) || Keyword.fetch!(expected, d)
      assert RawCte.names(text, d) == want, "#{d}: #{inspect(text)}"
    end
  end

  test "SQLite refuses only Tcl-style name(...) parameters" do
    for text <- [
          "ca AS (SELECT #x(') AS v), za AS (SELECT 2 AS v), cb AS (SELECT #y(') AS w)",
          "ca AS (SELECT $a::b(') AS v), za AS (SELECT 2 AS v), cb AS (SELECT $y(') AS w)"
        ] do
      assert RawCte.names(text, :sqlite) == :error, text
    end

    assert RawCte.names("ca AS (SELECT :a AS v), za AS (SELECT @b, $c, ?1 AS v)", :sqlite) ==
             {:ok, ["ca", "za"]}

    assert RawCte.names("ca AS (SELECT CAST(:a AS INT) AS v), za AS (SELECT 2)", :sqlite) ==
             {:ok, ["ca", "za"]}
  end

  test "a non-ASCII byte before $ opens no dollar quote; one inside a tag is read" do
    assert RawCte.names("ca AS (SELECT 1 AS \xe4$$), za AS (SELECT 2 AS v)", :postgresql) ==
             {:ok, ["ca", "za"]}

    assert RawCte.names("ca AS (SELECT $ä$ ) $ä$ AS v), za AS (SELECT 2 AS v)", :postgresql) ==
             {:ok, ["ca", "za"]}
  end
end
