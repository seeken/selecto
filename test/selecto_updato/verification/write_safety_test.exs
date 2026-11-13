defmodule SelectoUpdato.Verification.WriteSafetyTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.Verification.WriteSafety

  test "proves the complete built-in write scope model" do
    report = WriteSafety.verify()

    assert report.proof_level == :bounded_exhaustive
    assert report.state_count == 16
    assert report.invariant_count == 5
    assert report.check_count == 80
    assert report.proved?, inspect(report.counterexamples, pretty: true)
  end
end
