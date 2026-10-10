defmodule Selecto.Write.UpsertCandidateRequest do
  @moduledoc """
  Adapter-owned branch and storage projection for a governed upsert.

  The command carries the actual conflict target and conflict-update field
  whitelist. The compiler creates `subject` once per preparation. A later
  projection supplies the prior opaque receipt to prove that normalized
  assignments still address the same protected branch. Neither the subject nor
  a receipt is execution authority outside the adapter's prepared transaction.
  """

  @enforce_keys [:command, :field_types, :dependencies, :subject]
  defstruct format: "selecto.upsert_candidate_request",
            format_version: 1,
            command: nil,
            field_types: %{},
            dependencies: [],
            context: %{},
            prior: nil,
            subject: nil

  @type t :: %__MODULE__{
          format: String.t(),
          format_version: pos_integer(),
          command: Selecto.Write.Command.t(),
          field_types: map(),
          dependencies: [String.t()] | :all,
          context: map(),
          prior: term(),
          subject: reference()
        }
end
