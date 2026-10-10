defmodule Selecto.Write.UpsertCandidateState do
  @moduledoc """
  Canonical final-row state for one protected native upsert branch.

  `complete?` means that every requested dependency is genuinely available.
  Unknown, unconsumed insert defaults need not appear in `values`; they must
  never be invented as NULL. `prior_values` is the protected conflict row, or
  an empty map for the insert branch. The adapter privately binds `receipt` to
  the exact command, context, transaction, native arbiter and physical witness.
  """

  @enforce_keys [:values, :branch, :effect, :receipt]
  defstruct format: "selecto.upsert_candidate_state",
            format_version: 1,
            values: %{},
            prior_values: %{},
            branch: nil,
            effect: nil,
            complete?: false,
            protection: :unprotected,
            receipt: nil

  @type t :: %__MODULE__{
          format: String.t(),
          format_version: pos_integer(),
          values: map(),
          prior_values: map(),
          branch: :insert | :conflict,
          effect: :insert | :update | :nothing,
          complete?: boolean(),
          protection: :locked | :serializable | :unprotected,
          receipt: term()
        }
end
