defmodule Selecto.Write.RecordState do
  @moduledoc """
  Complete, protected root-record state returned for a prepared update.
  """

  @enforce_keys [:values]
  defstruct values: %{}, complete?: false, protection: :unprotected, revision: nil

  @type t :: %__MODULE__{
          values: map(),
          complete?: boolean(),
          protection: :locked | :unprotected,
          revision: map() | nil
        }
end
