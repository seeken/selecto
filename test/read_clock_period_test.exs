defmodule Selecto.ReadClockPeriodTest do
  use ExUnit.Case, async: true
  alias Selecto.{ReadClock, TemporalPeriod}

  test "clock binding is immutable and refuses malformed or impossible inputs" do
    original = %Selecto{set: %{}}
    bound = Selecto.as_of(original, "2026-03-15")
    assert bound.set.as_of == "2026-03-15"
    refute Map.has_key?(original.set, :as_of)

    for value <- [nil, [], %{}, "now", "2026-02-29", "2026-03-15 12:00:00"] do
      assert_raise Selecto.Builder.ScopeRefusal, fn -> ReadClock.bind(original, value) end
    end
  end

  test "outer compile clock reaches nested contexts and is restored after exceptions" do
    outer = %Selecto{set: %{as_of: "2026-03-15"}}
    child = %Selecto{set: %{as_of: "1999-01-01"}}

    assert_raise RuntimeError, fn ->
      ReadClock.with_context(outer, fn ->
        ReadClock.with_context(child, fn ->
          assert ReadClock.context(child).as_of == "2026-03-15"
          raise "stop"
        end)
      end)
    end

    assert ReadClock.context(child).as_of == "1999-01-01"
  end

  test "calendar bounds cross DST days, gaps and folded minutes exactly" do
    ranges = &TemporalPeriod.instant_ranges(&1, &2, "America/Denver")
    assert [{a, b}] = ranges.(~N[2026-03-08 00:00:00], ~N[2026-03-09 00:00:00])
    assert DateTime.diff(b, a) == 23 * 3600
    assert [{a, b}] = ranges.(~N[2026-11-01 00:00:00], ~N[2026-11-02 00:00:00])
    assert DateTime.diff(b, a) == 25 * 3600
    assert ranges.(~N[2026-03-08 02:00:00], ~N[2026-03-08 03:00:00]) == []

    assert [
             {~U[2026-11-01 07:30:00Z], ~U[2026-11-01 07:31:00Z]},
             {~U[2026-11-01 08:30:00Z], ~U[2026-11-01 08:31:00Z]}
           ] =
             ranges.(~N[2026-11-01 01:30:00], ~N[2026-11-01 01:31:00])
  end

  test "period parsing refuses excess precision and invalid calendar values" do
    for value <- [2026, "2026-02-30", "2026-13", "2026-01-01T24", "2026-01-01T10:30:00"] do
      assert_raise Selecto.Builder.ScopeRefusal, fn -> TemporalPeriod.bounds!(value) end
    end
  end
end
