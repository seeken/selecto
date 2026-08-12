defmodule Selecto.Verification.WriteAuthorityNonEscalationTest do
  use ExUnit.Case, async: true

  alias Selecto.Verification.WriteAuthorityNonEscalation

  test "proves write authority cannot escalate through the finite core lifecycle" do
    report = WriteAuthorityNonEscalation.verify()

    assert report.proof_level == :bounded_exhaustive
    assert report.initial_state_count == 768
    assert report.state_count == 3_072
    assert report.transition_count == 2_304
    assert report.max_depth == 3
    assert report.reached_depth == 3
    assert report.invariant_count == 4
    assert report.proved?, inspect(report.counterexamples, pretty: true, limit: :infinity)
  end
end
