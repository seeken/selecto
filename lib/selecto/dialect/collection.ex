defmodule Selecto.Dialect.Collection.Operation do
  @moduledoc "Finite portable collection operation presented to an adapter dialect."

  @enforce_keys [:operation, :clause]
  defstruct [
    :operation,
    :clause,
    :column,
    :dimension,
    :value,
    :distinct,
    :order_by,
    options: %{}
  ]

  @type t :: %__MODULE__{
          operation: atom(),
          clause: :select | :filter | :table,
          column: iodata() | nil,
          dimension: pos_integer() | nil,
          value: term(),
          distinct: boolean() | nil,
          order_by: [{iodata(), :asc | :desc}],
          options: map()
        }
end
