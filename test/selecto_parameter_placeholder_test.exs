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
end
