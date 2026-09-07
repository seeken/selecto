defmodule Selecto.Write do
  @moduledoc """
  Portable write-command entrypoint.

  `Selecto.Write` deliberately contains no database dialect, driver, or ORM
  knowledge. `selecto_updato` compiles governed domain intent into these
  commands; a configured database adapter previews or executes them.
  """

  alias Selecto.Write.{Capabilities, Command, Error, Preview}

  @type command :: Command.t() | Selecto.Write.Batch.t() | Selecto.Write.Graph.t()
  @type execution_result :: Selecto.Write.Result.t() | [Selecto.Write.Result.t()]

  @spec execute(Selecto.t(), command(), keyword()) ::
          {:ok, execution_result()} | {:error, Error.t()}
  def execute(%Selecto{adapter: adapter, connection: connection}, command, opts \\ []) do
    with :ok <- validate_command(command),
         :ok <- ensure_callback(adapter, :execute_write, 3),
         {:ok, capabilities} <- adapter_capabilities(adapter, connection),
         :ok <- Capabilities.require(capabilities, command),
         :ok <- require_committed_effect_sink(capabilities, opts) do
      adapter.execute_write(connection, command, opts)
    end
  end

  @doc """
  Executes a write whose portable command must be prepared from protected
  database state inside the adapter's transaction.

  The adapter supplies the preparation function with a typed protected-state loader.
  Only adapters that explicitly report `:prepared_candidate_state` support this
  boundary.
  """
  @spec execute_prepared(Selecto.t(), Selecto.DB.WriteAdapter.prepare_fun(), keyword()) ::
          {:ok, execution_result()} | {:error, Error.t()} | {:error, term()}
  def execute_prepared(
        %Selecto{adapter: adapter, connection: connection},
        prepare_fun,
        opts \\ []
      )
      when is_function(prepare_fun, 1) do
    with :ok <- ensure_callback(adapter, :execute_prepared_write, 3),
         {:ok, capabilities} <- adapter_capabilities(adapter, connection),
         :ok <- require_prepared_candidate_state(capabilities),
         :ok <- require_committed_effect_sink(capabilities, opts) do
      adapter.execute_prepared_write(connection, prepare_fun, opts)
    end
  end

  @spec preview(Selecto.t(), command(), keyword()) :: {:ok, Preview.t()} | {:error, Error.t()}
  def preview(%Selecto{adapter: adapter, connection: connection}, command, opts \\ []) do
    with :ok <- validate_command(command),
         :ok <- ensure_callback(adapter, :preview_write, 3),
         {:ok, capabilities} <- adapter_capabilities(adapter, connection),
         :ok <- Capabilities.require(capabilities, command) do
      adapter.preview_write(connection, command, opts)
    end
  end

  @spec capabilities(Selecto.t()) :: {:ok, map()} | {:error, Error.t()}
  def capabilities(%Selecto{adapter: adapter, connection: connection}) do
    adapter_capabilities(adapter, connection)
  end

  defp adapter_capabilities(adapter, connection) do
    with :ok <- ensure_callback(adapter, :write_capabilities, 1),
         {:ok, capabilities} <- safe_capabilities(adapter, connection),
         :ok <- Capabilities.validate(capabilities) do
      {:ok, capabilities}
    end
  end

  defp safe_capabilities(adapter, connection) do
    {:ok, adapter.write_capabilities(connection)}
  rescue
    _exception -> capability_callback_error(adapter)
  catch
    _kind, _reason -> capability_callback_error(adapter)
  end

  defp capability_callback_error(adapter) do
    {:error,
     Error.new(
       :invalid_write_capabilities,
       "write adapter capability discovery failed",
       details: %{adapter: adapter}
     )}
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

  defp require_committed_effect_sink(capabilities, opts) do
    if Keyword.has_key?(opts, :committed_effect_sink) and
         not Capabilities.supported?(capabilities, :committed_effect_sink) do
      {:error,
       Error.new(
         :write_capability_missing,
         "configured adapter cannot atomically install committed effects",
         details: %{required: [:committed_effect_sink], missing: [:committed_effect_sink]}
       )}
    else
      :ok
    end
  end

  defp require_prepared_candidate_state(capabilities) do
    if Capabilities.supported?(capabilities, :prepared_candidate_state) do
      :ok
    else
      {:error,
       Error.new(
         :write_capability_missing,
         "configured adapter cannot prepare writes from protected candidate state",
         details: %{
           required: [:prepared_candidate_state],
           missing: [:prepared_candidate_state]
         }
       )}
    end
  end
end
