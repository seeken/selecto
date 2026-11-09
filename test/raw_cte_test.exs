defmodule Selecto.Builder.RawCteTest do
  use ExUnit.Case, async: true

  alias Selecto.Builder.RawCte

  test "reads every name of plain definitions" do
    assert RawCte.names("r AS (SELECT 1)") == {:ok, ["r"]}
    assert RawCte.names("x13 AS (SELECT 1 AS v), r AS (SELECT 2)") == {:ok, ["x13", "r"]}
    assert RawCte.names("r(id, v) AS (SELECT 1, 2)") == {:ok, ["r"]}
    assert RawCte.names("r AS NOT MATERIALIZED (SELECT 1)") == {:ok, ["r"]}
    assert RawCte.names("R AS materialized (SELECT 1)") == {:ok, ["R"]}
  end

  test "tells quoted names from unquoted ones" do
    assert RawCte.entries(~S[KU AS (SELECT 1), "Kq" AS (SELECT 2)]) ==
             {:ok, [{"KU", false}, {"Kq", true}]}
  end

  test "reads names past comments and quoted names" do
    assert RawCte.names("/* c */ r AS (SELECT 1)") == {:ok, ["r"]}
    assert RawCte.names("-- c\n r AS (SELECT 1) -- end") == {:ok, ["r"]}
    assert RawCte.names("/* a /* nested */ b */ r AS (SELECT 1)") == {:ok, ["r"]}
    assert RawCte.names(~S["R""x" AS (SELECT 1)]) == {:ok, [~S[R"x]]}
    assert RawCte.names("`r` AS (SELECT 1), [p] AS (SELECT 2)") == {:ok, ["r", "p"]}
    assert RawCte.names("x AS (SELECT 1) /* c */ , /* d */ r AS (SELECT 2)") == {:ok, ["x", "r"]}
  end

  test "balances a body past strings, quoted names, dollar quotes and comments" do
    body = ~S[SELECT '), z AS (' AS a, "q)" AS b, $t$ ) $t$ AS c, $1 AS d /* ) */ -- )
    FROM t]

    assert RawCte.names("r AS (#{body}), s AS (SELECT 1)") == {:ok, ["r", "s"]}
  end

  test "refuses text it cannot read" do
    for text <- [
          "SELECT 1",
          "r AS (SELECT 1",
          "r AS (SELECT 1) junk",
          ~S[r AS (SELECT 'a\'), q AS (SELECT 1')],
          "r (SELECT 1)",
          "/* open r AS (SELECT 1)",
          ~S["" AS (SELECT 1)],
          "é AS (SELECT 1)"
        ] do
      assert RawCte.names(text) == :error, text
    end
  end
end
