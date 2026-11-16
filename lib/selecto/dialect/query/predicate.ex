defmodule Selecto.Dialect.Query.Predicate do
  @moduledoc "Compiler-owned predicate and ordered bindings for scalar projection."
  @enforce_keys [:expression, :params]
  defstruct [:expression, :params]
  @type t :: %__MODULE__{expression: iodata(), params: list()}
end
