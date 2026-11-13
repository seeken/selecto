defmodule SelectoUpdato.Verification.ActionSafetyTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.Verification.ActionSafety

  test "proves action planning and capability fail-closed behavior" do
    report = ActionSafety.verify()

    assert report.proof_level == :bounded_exhaustive
    assert report.state_count == 8
    assert report.invariant_count == 4
    assert report.check_count == 32
    assert report.proved?, inspect(report.counterexamples, pretty: true)
  end
end
