defmodule Selecto.Verification.BoundedModel do
  @moduledoc """
  Deterministic, exhaustive checking over an explicitly bounded state space.

  This is a small model-checking kernel used by Selecto's verification suites.
  It is deliberately dependency-free so verification is available to package
  consumers and Mix tasks, not only to the test environment.

  A successful report proves that every invariant held for every supplied
  state. The proof is bounded by the caller's finite model; the report records
  the exact model size and never presents the result as an unbounded theorem.
  """

  alias Selecto.Verification.PortableTerm

  @type invariant ::
          {String.t() | atom(), (term() -> :ok | true | {:error, term()} | false)}

  @type report :: %{
          format: String.t(),
          format_version: pos_integer(),
          proof_level: :bounded_exhaustive,
          model: String.t(),
          state_count: non_neg_integer(),
          invariant_count: non_neg_integer(),
          check_count: non_neg_integer(),
          proved?: boolean(),
          counterexamples: [map()]
        }

  @doc """
  Checks every invariant against every state and returns a stable proof report.

  Invariants should return `:ok` or `true` when satisfied. `{:error, reason}`,
  `false`, exceptions, and throws are captured as reproducible
  counterexamples.
  """
  @spec check(String.t() | atom(), Enumerable.t(), [invariant()]) :: report()
  def check(model, states, invariants) when is_list(invariants) do
    states = Enum.to_list(states)

    counterexamples =
      for {state, state_index} <- Enum.with_index(states),
          {invariant, invariant_index} <- Enum.with_index(invariants),
          counterexample <-
            check_invariant(state, state_index, invariant, invariant_index),
          do: counterexample

    %{
      format: "selecto.formal_verification",
      format_version: 1,
      proof_level: :bounded_exhaustive,
      model: to_string(model),
      state_count: length(states),
      invariant_count: length(invariants),
      check_count: length(states) * length(invariants),
      proved?: counterexamples == [],
      counterexamples: counterexamples
    }
  end

  defp check_invariant(state, state_index, {name, invariant}, invariant_index)
       when is_function(invariant, 1) do
    result =
      try do
        invariant.(state)
      rescue
        exception -> {:exception, exception.__struct__, Exception.message(exception)}
      catch
        kind, reason -> {:caught, kind, reason}
      end

    case result do
      :ok ->
        []

      true ->
        []

      {:exception, _module, _message} = reason ->
        [counterexample(state, state_index, name, invariant_index, reason)]

      {:caught, _kind, _value} = reason ->
        [counterexample(state, state_index, name, invariant_index, reason)]

      {:error, reason} ->
        [counterexample(state, state_index, name, invariant_index, reason)]

      false ->
        [counterexample(state, state_index, name, invariant_index, :returned_false)]

      other ->
        [
          counterexample(
            state,
            state_index,
            name,
            invariant_index,
            {:invalid_invariant_result, other}
          )
        ]
    end
  end

  defp counterexample(state, state_index, name, invariant_index, reason) do
    %{
      invariant: to_string(name),
      invariant_index: invariant_index,
      state_index: state_index,
      state: PortableTerm.encode(state),
      reason: PortableTerm.encode(reason)
    }
  end
end
