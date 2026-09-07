defmodule Selecto.Write.CandidateRequest do
  @moduledoc """
  Portable request for the complete prior state of a governed collection.

  A database adapter receives this value inside its prepared-write transaction.
  The parent command identifies and scopes the owning row; the remaining fields
  describe the bounded child collection that must be loaded and protected.
  """

  alias Selecto.Write.Command

  @enforce_keys [
    :operation,
    :representation,
    :relationship,
    :path,
    :parent_command,
    :parent_key,
    :child_relation,
    :child_key,
    :identity_fields,
    :fields,
    :max_rows
  ]
  defstruct format: "selecto.candidate_state_request",
            format_version: 1,
            operation: nil,
            representation: nil,
            relationship: nil,
            path: [],
            parent_command: nil,
            parent_key: nil,
            child_relation: nil,
            child_key: nil,
            context: %{},
            identity_fields: [],
            fields: [],
            max_rows: 1_000

  @type t :: %__MODULE__{
          format: String.t(),
          format_version: pos_integer(),
          operation: atom() | String.t(),
          representation: atom() | String.t(),
          relationship: String.t(),
          path: [term()],
          parent_command: Command.t(),
          parent_key: atom() | String.t(),
          child_relation: atom() | String.t(),
          child_key: atom() | String.t(),
          context: map(),
          identity_fields: [String.t()],
          fields: [String.t()],
          max_rows: pos_integer()
        }
end
