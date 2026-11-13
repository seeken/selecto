defmodule SelectoUpdato.Verification.TrustBoundarySafetyTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.Verification.TrustBoundarySafety

  test "proves adversarial inputs cannot cross the portable command boundary" do
    report = TrustBoundarySafety.verify()

    assert report.proof_level == :bounded_exhaustive
    assert report.state_count == 12
    assert report.invariant_count == 2
    assert report.check_count == 24
    assert report.proved?, inspect(report.counterexamples, pretty: true)
  end
end
