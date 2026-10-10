defmodule Selecto.Dialect.ComputedValue do
  @moduledoc """
  Finite computed-value fragments whose SQL varies by adapter.

  `:cast` carries one of the canonical computed-value cast types. `:json_text`
  carries a compiled JSON expression and a non-empty list of bound path markers.
  Expressions and markers come from Core's governed compiler; domain data never
  supplies SQL. A renderer preserves their order and parameter markers.

  `:divide` carries the two compiled operands of decimal division. SQLite uses
  this finite port to promote operands before division, preserving fractions
  when NUMERIC affinity stores both values as integers.

  The optional `c:Selecto.DB.Dialect.render_computed_value/2` callback is required
  only when an expression uses a cast or JSON text extraction. Field references,
  arithmetic without casts, case expressions, coalesce, lower and upper continue
  to use generic SQL composition.
  """

  @enforce_keys [:operation, :expression]
  defstruct [:operation, :expression, :type, path: []]

  @type t :: %__MODULE__{
          operation: :cast | :json_text | :divide,
          expression: term(),
          type: String.t() | nil,
          path: [{:param, String.t()}]
        }
end
