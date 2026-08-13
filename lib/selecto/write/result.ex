defmodule Selecto.Write.Result do
  @moduledoc """
  Normalized result of a successful portable write.

  `affected_rows` is the number of rows logically matched and authorized by the
  portable mutation. It is not necessarily the database driver's physical
  changed-row count. Adapters must normalize dialect-specific values before
  enforcing `Command.expected_cardinality` or constructing this result.
  """

  @type t :: %__MODULE__{
          operation: atom(),
          affected_rows: non_neg_integer(),
          rows: [map()],
          metadata: map()
        }

  @enforce_keys [:operation, :affected_rows]
  defstruct [:operation, :affected_rows, rows: [], metadata: %{}]
end
