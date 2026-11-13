defmodule SelectoUpdato.Verification.NestedCompositionSafetyTest do
  use ExUnit.Case, async: true

  test "all finite general-composition states satisfy the declared invariants" do
    report = SelectoUpdato.Verification.NestedCompositionSafety.verify()

    assert report.proved?
    assert report.proof_level == :bounded_exhaustive
    assert report.state_count == 20
    assert report.invariant_count == 4
    assert report.check_count == 80
    assert report.counterexamples == []
  end
end
