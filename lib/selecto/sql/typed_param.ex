defmodule Selecto.SQL.TypedParam do
  @moduledoc """
  A bound value its comparison casts: `{:param, %TypedParam{value: v, cast: :uuid}}`
  binds `v` and asks the adapter's `parameter_placeholder/2` to render the cast
  around the placeholder (DuckDB: `CAST($n AS UUID)`). The parameter list holds
  the plain value.

  `cast: :projected` marks a value projected in a derived table's select list
  (DuckDB's Decimal IN lists): the adapter renders its own typed cast with no
  scalar subquery around it.
  """

  @enforce_keys [:value, :cast]
  defstruct [:value, :cast]

  @type t :: %__MODULE__{value: term(), cast: :uuid | :projected}
end
