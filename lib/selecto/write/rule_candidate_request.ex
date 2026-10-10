defmodule Selecto.Write.RuleCandidateRequest do
  @moduledoc """
  Adapter-owned storage projection of a governed rule candidate.

  The governed consumer supplies this request only inside a prepared-write
  transaction. Values have already passed submitted-input rules; the adapter
  establishes the actual column affinity and returns canonical stored values
  before candidate or transaction rules authorize business mutations.
  """

  @enforce_keys [:operation, :relation, :values, :field_types]
  defstruct format: "selecto.rule_candidate_request",
            format_version: 1,
            operation: nil,
            relation: nil,
            values: %{},
            field_types: %{},
            context: %{}

  @type t :: %__MODULE__{
          format: String.t(),
          format_version: pos_integer(),
          operation: atom(),
          relation: atom() | String.t(),
          values: map(),
          field_types: map(),
          context: map()
        }
end
