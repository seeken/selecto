defmodule Selecto.Write do
  @moduledoc """
  Portable write-command entrypoint.

  `Selecto.Write` deliberately contains no database dialect, driver, or ORM
  knowledge. `selecto_updato` compiles governed domain intent into these
  commands; a configured database adapter previews or executes them.
  """

  alias Selecto.Write.{Command, Error, Preview}

  @type command :: Command.t() | Selecto.Write.Batch.t() | Selecto.Write.Graph.t()

  @spec execute(Selecto.t(), command(), keyword()) ::
          {:ok, Selecto.Write.Result.t()} | {:error, Error.t()}
  def execute(%Selecto{adapter: adapter, connection: connection}, command, opts \\ []) do
    with :ok <- validate_command(command),
         :ok <- ensure_callback(adapter, :execute_write, 3) do
      adapter.execute_write(connection, command, opts)
    end
  end

  @spec preview(Selecto.t(), command(), keyword()) :: {:ok, Preview.t()} | {:error, Error.t()}
  def preview(%Selecto{adapter: adapter, connection: connection}, command, opts \\ []) do
    with :ok <- validate_command(command),
         :ok <- ensure_callback(adapter, :preview_write, 3) do
      adapter.preview_write(connection, command, opts)
    end
  end

  @spec capabilities(Selecto.t()) :: {:ok, map()} | {:error, Error.t()}
  def capabilities(%Selecto{adapter: adapter, connection: connection}) do
    with :ok <- ensure_callback(adapter, :write_capabilities, 1) do
      {:ok, adapter.write_capabilities(connection)}
    end
  end

  defp validate_command(%Command{} = command), do: Command.validate(command)
  defp validate_command(%Selecto.Write.Batch{} = batch), do: Selecto.Write.Batch.validate(batch)
  defp validate_command(%Selecto.Write.Graph{} = graph), do: Selecto.Write.Graph.validate(graph)

  defp validate_command(other) do
    {:error,
     Error.new(:invalid_command, "expected a portable Selecto write command, batch, or graph",
       details: %{actual: other}
     )}
  end

  defp ensure_callback(adapter, callback, arity) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, callback, arity) do
      :ok
    else
      {:error,
       Error.new(:write_not_supported, "configured adapter does not support portable writes",
         details: %{adapter: adapter, callback: {callback, arity}}
       )}
    end
  end

  defp ensure_callback(adapter, callback, arity) do
    {:error,
     Error.new(:write_not_supported, "configured Selecto value has no write-capable adapter",
       details: %{adapter: adapter, callback: {callback, arity}}
     )}
  end
end
