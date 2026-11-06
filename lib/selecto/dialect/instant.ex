defmodule Selecto.Dialect.Instant.Comparison do
  @moduledoc "Exact instant comparison with a separately bound decimal epoch operand."
  @enforce_keys [:operation, :expression, :value, :source_type]
  defstruct [:operation, :expression, :value, :source_type, storage: nil]

  @type t :: %__MODULE__{
          operation: :eq | :ne | :gt | :gte | :lt | :lte,
          expression: iodata(),
          value: {:param, String.t()},
          source_type: :utc_datetime | :timestamptz | :epoch_datetime,
          storage: nil | :naive_utc
        }
end
