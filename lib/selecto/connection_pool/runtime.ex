defmodule Selecto.ConnectionPool.Runtime do
  @moduledoc """
  Supervision tree backing `Selecto.ConnectionPool`.

  The runtime owns `Selecto.ConnectionPool.Registry` (pool and manager names)
  and `Selecto.ConnectionPool.ManagerSupervisor` (pool managers). Selecto
  starts it lazily under its own application supervisor the first time a
  pooled connection is requested (for example `Selecto.configure/3` with
  `pool: true`).

  Hosts that prefer explicit lifecycle management can supervise it
  themselves, typically before any process that runs pooled queries:

      children = [
        MyApp.Repo,
        Selecto.ConnectionPool.Runtime,
        MyAppWeb.Endpoint
      ]

  The lazy path then reuses the host-supervised runtime.
  """

  use Supervisor

  @registry Selecto.ConnectionPool.Registry
  @manager_supervisor Selecto.ConnectionPool.ManagerSupervisor

  @ready_attempts 200
  @ready_retry_delay 5

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Child specification for supervising the runtime in a host supervision tree.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Ensures the pool runtime is running and ready, starting it on demand.

  Returns only once the registry and manager supervisor are usable. The
  runtime registers its name before its children finish starting, so a
  registered runtime alone does not mean it is ready; concurrent first
  callers wait for initialization to complete instead of racing it.
  """
  @spec ensure_started() :: {:ok, pid()} | {:error, term()}
  def ensure_started do
    ensure_ready(@ready_attempts)
  end

  @doc """
  Returns whether the runtime and all of its children are started.
  """
  @spec ready?() :: boolean()
  def ready?, do: match?({:ok, _pid}, ready_pid())

  # Children start in order and the manager supervisor is last, so its
  # registration implies the registry has finished starting.
  defp ready_pid do
    with runtime when is_pid(runtime) <- Process.whereis(__MODULE__),
         manager when is_pid(manager) <- Process.whereis(@manager_supervisor) do
      {:ok, runtime}
    else
      _ -> :error
    end
  end

  defp ensure_ready(0), do: {:error, :runtime_start_failed}

  defp ensure_ready(attempts) do
    case ready_pid() do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case Process.whereis(__MODULE__) do
          nil ->
            # Blocks until the child has finished initializing; concurrent
            # callers are serialized by Selecto.Supervisor.
            with :ok <- attach_to_app_supervisor([]) do
              ensure_ready(attempts - 1)
            end

          pid ->
            # Registered but still initializing (or restarting children).
            await_initialized(pid)
            if ready?(), do: ensure_ready(attempts), else: retry(attempts)
        end
    end
  end

  defp retry(attempts) do
    Process.sleep(@ready_retry_delay)
    ensure_ready(attempts - 1)
  end

  # A supervisor handles calls only after init/1 (and any in-progress child
  # restart) completes, so this blocks until the runtime settles.
  defp await_initialized(pid) do
    _ = Supervisor.count_children(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp attach_to_app_supervisor(opts) do
    case Supervisor.start_child(Selecto.Supervisor, child_spec(opts)) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> restart_app_child()
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:selecto_supervisor_unavailable, reason}}
  end

  defp restart_app_child do
    case Supervisor.restart_child(Selecto.Supervisor, __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
      {:error, :restarting} -> :ok
      {:error, reason} -> {:error, reason}
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
