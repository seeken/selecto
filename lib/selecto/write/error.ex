defmodule Selecto.Write.Error do
  @moduledoc "Portable structured error returned by a write adapter."

  @type t :: %__MODULE__{type: atom(), message: String.t(), details: map()}

  @enforce_keys [:type, :message]
  defstruct [:type, :message, details: %{}]

  @spec new(atom(), String.t(), keyword()) :: t()
  def new(type, message, opts \\ []) when is_atom(type) and is_binary(message) do
    %__MODULE__{type: type, message: message, details: Keyword.get(opts, :details, %{})}
  end

  @doc """
  Builds an adapter-neutral failure without retaining a driver exception,
  connection handle, SQL statement, or bound values in portable details.
  """
  @spec adapter_failure(atom(), atom(), term(), String.t()) :: t()
  def adapter_failure(type, adapter, reason, message)
      when is_atom(type) and is_atom(adapter) and is_binary(message) do
    new(type, message, details: %{adapter: adapter, reason: reason_category(reason)})
  end

  defp reason_category(%__MODULE__{type: type}), do: type
  defp reason_category(%{__struct__: module}) when is_atom(module), do: module_name(module)
  defp reason_category({kind, _details}) when is_atom(kind), do: kind
  defp reason_category({kind, _left, _right}) when is_atom(kind), do: kind
  defp reason_category(reason) when is_atom(reason), do: reason
  defp reason_category(_reason), do: :adapter_rejected

  defp module_name(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end
end
