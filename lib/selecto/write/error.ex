defmodule Selecto.Write.Error do
  @moduledoc "Portable structured error returned by a write adapter."

  @type t :: %__MODULE__{type: atom(), message: String.t(), details: map()}

  @enforce_keys [:type, :message]
  defstruct [:type, :message, details: %{}]

  @spec new(atom(), String.t(), keyword()) :: t()
  def new(type, message, opts \\ []) when is_atom(type) and is_binary(message) do
    %__MODULE__{type: type, message: message, details: Keyword.get(opts, :details, %{})}
  end
end
