defmodule Selecto.ConnectionPool.Runtime do
  @moduledoc false

  use Supervisor

  @registry Selecto.ConnectionPool.Registry
  @manager_supervisor Selecto.ConnectionPool.ManagerSupervisor

  @register_attempts 200
  @register_retry_delay 5

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures the pool runtime is running, starting it on demand if needed.

  Safe under concurrency: simultaneous first callers converge on the same
  running runtime instead of racing each other. The runtime is attached to
  Selecto's application supervisor as a dynamic permanent child, so normal
  application shutdown reclaims it and crashes are restarted. Hosts that
  prefer their own lifecycle management may add this module to their own
  supervision tree via `start_link/1` instead.
  """
  @spec ensure_started() :: {:ok, pid()} | {:error, term()}
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        # Blocks until the child has finished initializing, so concurrent
        # callers need no polling of each other; losers observe an already
        # running runtime through the registration wait below.
        case attach_to_app_supervisor([]) do
          :ok ->
            await_registered(@register_attempts)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp attach_to_app_supervisor(opts) do
    case Supervisor.start_child(Selecto.Supervisor, child_spec(opts)) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:selecto_supervisor_unavailable, reason}}
  end

  defp child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  defp await_registered(0), do: {:error, :runtime_start_failed}

  defp await_registered(attempts) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        # A concurrent attach may still be initializing.
        Process.sleep(@register_retry_delay)
        await_registered(attempts - 1)
    end
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @manager_supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
