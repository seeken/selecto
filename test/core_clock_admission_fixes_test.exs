defmodule Selecto.CoreClockAdmissionFixesTest do
  use ExUnit.Case, async: true
  alias Selecto.ReadClock

  test "as_of accepts optional offset and rejects invalid grammar and year zero" do
    assert ReadClock.validate!("2026-03-15T23:30:00") == "2026-03-15T23:30:00"
    assert ReadClock.instant("2026-03-15T23:30:00", "Asia/Tokyo") == ~U[2026-03-15 23:30:00Z]
    assert ReadClock.validate!("2026-03-15T23:30:00.123456789Z")

    for value <- [
          "0000-01-01",
          "0000-01-01T00:00:00Z",
          "2026-03-15T23:30:00.1234567890Z",
          String.duplicate("x", 46),
          "2026-03-15T23:30Z",
          "2026-03-15T23:30:00+24:00"
        ] do
      assert_raise Selecto.Builder.ScopeRefusal, fn -> ReadClock.validate!(value) end
    end
  end
end
