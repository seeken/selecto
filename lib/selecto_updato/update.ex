defmodule SelectoUpdato.Update do
  @moduledoc """
  Portable update operation building for SelectoUpdato.

  Values are literal data or closed `SelectoUpdato.Mutation` expressions.
  The governed compiler checks root-field ownership and types; write adapters
  bind operands and evaluate expressions natively.
  """

  alias SelectoUpdato.Operation

  @doc """
  Set up an update operation with the given changes.

  ## Example

      |> SelectoUpdato.update(%{status: "shipped"})
  """
  @spec update(Operation.t(), map()) :: Operation.t()
  def update(%Operation{} = op, changes) when is_map(changes) do
    %{op | type: :update, changes: changes}
  end
end
