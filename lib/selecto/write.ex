defmodule Selecto.Write do
  @moduledoc """
  Portable write-command entrypoint.

  `Selecto.Write` deliberately contains no database dialect, driver, or ORM
  knowledge. `selecto_updato` validates domain intent against the domain's
  `writes` contract, compiles it into these portable commands, and executes
  them here with a `Selecto.Write.Authorization` for exactly that command,
  batch, or graph. A configured database adapter previews or executes them.

  Applications write through `SelectoUpdato`. `execute/3` and
  `execute_prepared/3` refuse a write that did not come from that governed
  entry point with `{:error, %Selecto.Write.Error{type: :ungoverned_write}}`.

  `execute_unsafe/3` and `execute_prepared_unsafe/3` skip domain governance.
  They exist for trusted tooling and adapter tests only; application code,
  examples, and request handlers never call them.

  `preview/3` compiles a write without executing it and needs no
  authorization; `SelectoUpdato.preview/3` previews through the same
  governance pipeline as execution.
  """

  alias Selecto.Write.{Authorization, Capabilities, Command, Error, Preview}

  @type command :: Command.t() | Selecto.Write.Batch.t() | Selecto.Write.Graph.t()
  @type execution_result :: Selecto.Write.Result.t() | [Selecto.Write.Result.t()]

  @doc """
  Executes a governed write.

  `opts` must carry the `:authorization` the governed entry point issued for
  exactly `command`; without it the write fails with `:ungoverned_write`
  before the adapter is called. The authorization is spent by this call.
  """
  @spec execute(Selecto.t(), command(), keyword()) ::
          {:ok, execution_result()} | {:error, Error.t()}
  def execute(selecto, command, opts \\ [])

  def execute(%Selecto{adapter: adapter, connection: connection}, command, opts) do
    with :ok <- Authorization.check(command, opts),
         :ok <- preflight(adapter, connection, command, :execute_write, opts) do
      adapter.execute_write(connection, command, opts)
    end
  after
    Authorization.revoke(opts)
  end

  @doc """
  Executes a write without domain governance.

  For trusted tooling and adapter tests only. It runs the same command,
  capability, and committed-effect checks as `execute/3` and dispatches to the
  adapter's `execute_write_unsafe/3`.
  """
  @spec execute_unsafe(Selecto.t(), command(), keyword()) ::
          {:ok, execution_result()} | {:error, Error.t()}
  def execute_unsafe(%Selecto{adapter: adapter, connection: connection}, command, opts \\ []) do
    with :ok <- preflight(adapter, connection, command, :execute_write_unsafe, opts) do
      adapter.execute_write_unsafe(connection, command, opts)
    end
  end

  @doc """
  Executes a governed write whose portable command must be prepared from
  protected database state inside the adapter's transaction.

  The adapter supplies the preparation function with a typed protected-state
  loader. The governed entry point's preparation returns `{:ok, write,
  context, authorization}`; a preparation that returns an unauthorized
  `{:ok, write, context}` fails with `:ungoverned_write` and the transaction
  rolls back. Only adapters that explicitly report `:prepared_candidate_state`
  support this boundary.
  """
  @spec execute_prepared(Selecto.t(), Selecto.DB.WriteAdapter.prepare_fun(), keyword()) ::
          {:ok, execution_result()} | {:error, Error.t()} | {:error, term()}
  def execute_prepared(
        %Selecto{adapter: adapter, connection: connection},
        prepare_fun,
        opts \\ []
      )
      when is_function(prepare_fun, 1) do
    with :ok <- prepared_preflight(adapter, connection, :execute_prepared_write, opts) do
      Authorization.dispatch_prepared(prepare_fun, fn checked ->
        adapter.execute_prepared_write(connection, checked, opts)
      end)
    end
  end

  @doc """
  Executes a prepared write without domain governance.

  For trusted tooling and adapter tests only. The preparation returns
  `{:ok, write, context}` and the adapter's
  `execute_prepared_write_unsafe/3` executes it.
  """
  @spec execute_prepared_unsafe(
          Selecto.t(),
          Selecto.DB.WriteAdapter.unsafe_prepare_fun(),
          keyword()
        ) ::
          {:ok, execution_result()} | {:error, Error.t()} | {:error, term()}
  def execute_prepared_unsafe(
        %Selecto{adapter: adapter, connection: connection},
        prepare_fun,
        opts \\ []
      )
      when is_function(prepare_fun, 1) do
    with :ok <- prepared_preflight(adapter, connection, :execute_prepared_write_unsafe, opts) do
      adapter.execute_prepared_write_unsafe(connection, prepare_fun, opts)
    end
  end

  defp preflight(adapter, connection, command, callback, opts) do
    with :ok <- validate_command(command),
         :ok <- ensure_callback(adapter, callback, 3),
         {:ok, capabilities} <- adapter_capabilities(adapter, connection),
         :ok <- Capabilities.require(capabilities, command) do
      require_committed_effect_sink(capabilities, opts)
    end
  end

  defp prepared_preflight(adapter, connection, callback, opts) do
    with :ok <- ensure_callback(adapter, callback, 3),
         {:ok, capabilities} <- adapter_capabilities(adapter, connection),
         :ok <- require_prepared_candidate_state(capabilities) do
      require_committed_effect_sink(capabilities, opts)
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
