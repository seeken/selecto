defmodule Selecto.SQL.QualifiedIdentifierTest do
  use ExUnit.Case, async: true

  alias Selecto.SQL.QualifiedIdentifier

  test "quotes every component of qualified identifiers" do
    assert {:ok, ~s("reporting"."Daily_Rollup")} =
             QualifiedIdentifier.quote("reporting.Daily_Rollup")

    assert {:ok, ~s("order_id")} = QualifiedIdentifier.quote_part(:order_id)
  end

  test "rejects fragments, pre-quoted names, and empty components" do
    invalid = [
      "reporting.rollup; DROP TABLE users; --",
      ~s(reporting."rollup"),
      "reporting..rollup",
      "9starts_with_a_digit"
    ]

    for identifier <- invalid do
      assert {:error, %{code: :invalid_sql_identifier}} =
               QualifiedIdentifier.quote(identifier)
    end

    assert {:error, %{reason: :qualified_identifier_not_allowed}} =
             QualifiedIdentifier.quote_part("reporting.rollup")
  end

  test "applies an adapter-specific identifier length policy" do
    long_identifier = String.duplicate("x", 64)

    assert {:ok, _quoted} = QualifiedIdentifier.quote(long_identifier)

    assert {:error, %{reason: :part_too_long, max_bytes: 63}} =
             QualifiedIdentifier.quote(long_identifier, max_bytes: 63)
  end
end
