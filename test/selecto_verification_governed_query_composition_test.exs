defmodule Selecto.Verification.GovernedQueryCompositionTest do
  use ExUnit.Case, async: true

  alias Selecto.Verification.GovernedQueryComposition

  test "proves governed closure across the supported finite composition traces" do
    report = GovernedQueryComposition.verify()

    assert report.proof_level == :bounded_exhaustive
    assert report.initial_state_count == 6
    assert report.max_depth == 2
    assert report.reached_depth == 2
    assert report.event_count == 16
    assert report.state_count == 220
    assert report.transition_count == 214
    assert report.invariant_count == 6

    for member <- ["named_cte", "named_subquery", "named_lateral"] do
      assert [member] in report.trace_coverage
    end

    for left <- ["named_cte", "named_subquery"],
        right <- ["declared_join", "named_cte", "named_subquery", "named_lateral", "union"] do
      if left != right do
        assert [left, right] in report.trace_coverage
      end
    end

    for set_operation <- ["union", "intersect", "except"],
        terminal_mutation <- ["declared_join", "named_cte", "named_subquery", "named_lateral"] do
      assert [set_operation, terminal_mutation] in report.trace_coverage
    end

    assert report.proved?, inspect(report.counterexamples, pretty: true, limit: :infinity)
  end
end
