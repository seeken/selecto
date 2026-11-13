defmodule SelectoUpdato.Verification.PortableCommandSafetyTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.Verification.PortableCommandSafety

  test "proves the portable domain-to-command boundary" do
    report = PortableCommandSafety.verify()

    assert report.proof_level == :bounded_exhaustive
    assert report.state_count == 48
    assert report.invariant_count == 9
    assert report.check_count == 432
    assert report.proved?, inspect(report.counterexamples, pretty: true)
  end
end
