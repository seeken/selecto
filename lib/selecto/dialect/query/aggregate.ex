defmodule Selecto.Dialect.Query.Aggregate do
  @moduledoc "Compiler-owned aggregate fragments for optional dialect lowering."
  @enforce_keys [:function, :arguments, :filter]
  defstruct [:function, :arguments, :filter, :fallback, distinct: false]

  @type t :: %__MODULE__{
          function: String.t(),
          arguments: [iodata()],
          filter: iodata(),
          fallback: iodata() | nil,
          distinct: boolean()
        }
end
