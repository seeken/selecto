defmodule Selecto.Write.Result do
  @moduledoc "Normalized result of a successful portable write."

  @type t :: %__MODULE__{
          operation: atom(),
          affected_rows: non_neg_integer(),
          rows: [map()],
          metadata: map()
        }

  @enforce_keys [:operation, :affected_rows]
  defstruct [:operation, :affected_rows, rows: [], metadata: %{}]
end
