defmodule Selecto.Verification.QuerySafetyTest do
  use ExUnit.Case, async: true

  alias Selecto.Verification.QuerySafety

  test "proves the complete built-in query scope model" do
    report = QuerySafety.verify()

    assert report.proof_level == :bounded_exhaustive
    assert report.state_count == 48
    assert report.invariant_count == 5
    assert report.check_count == 240
    assert report.proved?, inspect(report.counterexamples, pretty: true)
  end

  test "the finite model never opens a database connection" do
    assert Enum.all?(QuerySafety.states(), fn state ->
             state.query.adapter == Selecto.Verification.QuerySafety.Adapter and
               state.query.connection == :verification
           end)
  end
end
