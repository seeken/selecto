defmodule Selecto.Write.Graph.Binding do
  @moduledoc """
  A generated-value dependency between rows in a portable write graph.

  The adapter resolves `from_field` from the successful result of the source
  row and binds it to `field` on the dependent row. Inserts receive an
  assignment; updates and deletes receive an ownership predicate.
  """

  @type t :: %__MODULE__{
          field: atom() | String.t(),
          from_node: String.t(),
          from_row: String.t(),
          from_field: atom() | String.t()
        }

  @enforce_keys [:field, :from_node, :from_row, :from_field]
  defstruct [:field, :from_node, :from_row, :from_field]
end
