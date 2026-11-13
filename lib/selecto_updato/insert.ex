defmodule SelectoUpdato.Insert do
  @moduledoc """
  Insert operation building for SelectoUpdato.
  """

  alias SelectoUpdato.Operation

  @doc """
  Set up an insert operation with the given attributes.
  """
  @spec insert(Operation.t(), map()) :: Operation.t()
  def insert(%Operation{} = op, attrs) when is_map(attrs) do
    %{op | type: :insert, attrs: attrs}
  end
end
