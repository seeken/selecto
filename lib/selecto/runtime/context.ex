defmodule Selecto.Runtime.Context do
  @moduledoc """
  Adapter-neutral runtime context for query and write execution.

  The adapter owns the connection handle. Selecto stores it opaquely and never
  infers a database or driver from the handle's shape.
  """

  @enforce_keys [:adapter, :connection]
  @derive {Inspect, only: [:adapter, :metadata]}
  defstruct [:adapter, :connection, metadata: %{}]

  @type t :: %__MODULE__{
          adapter: module(),
          connection: term(),
          metadata: map()
        }

  @spec new(module(), term(), map()) :: t()
  def new(adapter, connection, metadata \\ %{})

  def new(adapter, connection, metadata)
      when is_atom(adapter) and not is_nil(adapter) and is_map(metadata) do
    %__MODULE__{adapter: adapter, connection: connection, metadata: metadata}
  end

  def new(adapter, _connection, _metadata) do
    raise ArgumentError, "expected an explicit database adapter, got: #{inspect(adapter)}"
  end

  @spec adapter(t() | map()) :: module() | nil
  def adapter(%__MODULE__{adapter: adapter}), do: adapter
  def adapter(%{adapter: adapter}) when is_atom(adapter) and not is_nil(adapter), do: adapter
  def adapter(%{runtime: %__MODULE__{adapter: adapter}}), do: adapter
  def adapter(_), do: nil

  @spec connection(t() | map()) :: term()
  def connection(%__MODULE__{connection: connection}), do: connection
  def connection(%{connection: connection}) when not is_nil(connection), do: connection
  def connection(%{runtime: %__MODULE__{connection: connection}}), do: connection
  def connection(%{connection: nil}), do: nil
  def connection(_), do: nil
end
