defmodule Selecto.Verification.WriteRegistrySafetyTest do
  use ExUnit.Case, async: true

  alias Selecto.Verification.WriteRegistrySafety

  test "proves normalized canonical write registry ids fail closed" do
    report = WriteRegistrySafety.verify()

    assert report.state_count == 24
    assert report.invariant_count == 2
    assert report.check_count == 48
    assert report.proved?, inspect(report.counterexamples, pretty: true)
  end
end
