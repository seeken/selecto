defmodule Selecto.Write.CandidateState do
  @moduledoc """
  Complete prior collection state returned by a trusted candidate loader.

  `protection` records how the loader prevents the state from changing before
  the prepared write commits.
  """

  @enforce_keys [:rows, :complete?, :protection]
  defstruct rows: [], complete?: false, protection: :snapshot, revision: nil

  @type protection :: :snapshot | :locked | :serializable | :native_constraint
  @type t :: %__MODULE__{
          rows: [map()],
          complete?: boolean(),
          protection: protection(),
          revision: term()
        }
end
