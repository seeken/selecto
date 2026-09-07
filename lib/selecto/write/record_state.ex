defmodule Selecto.Write.RecordState do
  @moduledoc """
  Complete, protected root-record state returned for a prepared update or
  upsert branch decision.
  """

  @enforce_keys [:values]
  defstruct values: %{}, complete?: false, protection: :unprotected, revision: nil, exists?: true

  @type t :: %__MODULE__{
          values: map(),
          complete?: boolean(),
          protection: :locked | :serializable | :unprotected,
          revision: map() | nil,
          exists?: boolean()
        }
end
