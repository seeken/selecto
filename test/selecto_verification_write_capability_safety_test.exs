defmodule Selecto.Verification.WriteCapabilitySafetyTest do
  use ExUnit.Case, async: true

  alias Selecto.Verification.WriteCapabilitySafety

  test "proves the finite write capability preflight model" do
    report = WriteCapabilitySafety.verify()

    assert report.proved?
    assert report.proof_level == :bounded_exhaustive
    assert report.state_count == 30
    assert report.invariant_count == 3
    assert report.check_count == 90
    assert report.counterexamples == []
  end
end
