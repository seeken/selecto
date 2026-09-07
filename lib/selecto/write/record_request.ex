defmodule Selecto.Write.RecordRequest do
  @moduledoc """
  Portable request for one protected root record used to form an update candidate.

  The request is supplied only inside a prepared-write transaction. Its command
  carries the scoped predicate and its field list names the record values the
  consumer needs to merge with submitted assignments before candidate rules run.
  """

  @enforce_keys [:operation, :relation, :predicate, :fields]
  defstruct format: "selecto.record_state_request",
            format_version: 1,
            operation: nil,
            relation: nil,
            predicate: nil,
            context: %{},
            fields: []

  @type t :: %__MODULE__{
          format: String.t(),
          format_version: pos_integer(),
          operation: :update | String.t(),
          relation: atom() | String.t(),
          predicate: term(),
          context: map(),
          fields: [String.t()]
        }
end
