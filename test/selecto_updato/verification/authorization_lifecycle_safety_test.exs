defmodule SelectoUpdato.Verification.AuthorizationLifecycleSafetyTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.Verification.AuthorizationLifecycleSafety

  test "proves the registered action authorization lifecycle" do
    report = AuthorizationLifecycleSafety.verify()

    assert report.proof_level == :bounded_exhaustive
    assert report.model == "selecto_updato.authorization_lifecycle.v1"
    assert report.initial_state_count == 960
    assert report.event_count == 17
    assert report.state_count == 13_248
    assert report.invariant_count == 6
    assert report.check_count == 79_488
    assert report.max_depth == 6
    assert report.reached_depth == 6
    assert report.proved?, inspect(report.counterexamples, pretty: true)
  end
end
