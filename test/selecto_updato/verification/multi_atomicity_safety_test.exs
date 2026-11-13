defmodule SelectoUpdato.Verification.MultiAtomicitySafetyTest do
  use ExUnit.Case, async: false

  alias SelectoUpdato.Verification.MultiAtomicitySafety

  test "proves portable Multi atomicity and result-name bijection" do
    report = MultiAtomicitySafety.verify()

    assert report.proof_level == :bounded_exhaustive
    assert report.model == "selecto_updato.multi_atomicity.v1"
    assert report.state_count == 60
    assert report.invariant_count == 5
    assert report.check_count == 300
    assert report.proved?, inspect(report.counterexamples, pretty: true)
  end
end
