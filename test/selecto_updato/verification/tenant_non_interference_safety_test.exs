defmodule SelectoUpdato.Verification.TenantNonInterferenceSafetyTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.Verification.TenantNonInterferenceSafety

  test "proves tenant non-interference across flat, nested, and batched writes" do
    report = TenantNonInterferenceSafety.verify()

    assert report.proof_level == :bounded_exhaustive
    assert report.model == "selecto_updato.tenant_non_interference.v1"
    assert report.state_count == 5_832
    assert report.invariant_count == 6
    assert report.check_count == 34_992
    assert report.proved?, inspect(report.counterexamples, pretty: true)
  end
end
