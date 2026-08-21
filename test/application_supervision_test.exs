defmodule Selecto.ApplicationSupervisionTest do
  use ExUnit.Case, async: false

  test "application boots the core runtime supervisor" do
    assert is_pid(Process.whereis(Selecto.Supervisor))
    assert is_pid(Process.whereis(Selecto.TaskSupervisor))
  end

  test "connection pool runtime starts lazily on demand and survives its caller" do
    # Another test may have started it already; detach to exercise lazy start.
    detach_connection_pool_runtime()

    refute is_pid(Process.whereis(Selecto.ConnectionPool.Runtime))

    assert {:ok, runtime_pid} = Selecto.ConnectionPool.Runtime.ensure_started()
    assert Process.whereis(Selecto.ConnectionPool.Runtime) == runtime_pid

    :ok =
      Task.async(fn ->
        {:ok, _} = Selecto.ConnectionPool.Runtime.ensure_started()
        :ok
      end)
      |> Task.await()

    assert Process.alive?(runtime_pid)
  after
    detach_connection_pool_runtime()
  end

  test "concurrent lazy starters all converge on the running runtime" do
    detach_connection_pool_runtime()

    results =
      1..200
      |> Task.async_stream(
        fn _item -> Selecto.ConnectionPool.Runtime.ensure_started() end,
        max_concurrency: 200,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(results) == 200
    assert Enum.all?(results, &match?({:ok, pid} when is_pid(pid), &1))

    pids = Enum.map(results, fn {:ok, pid} -> pid end)
    assert length(Enum.uniq(pids)) == 1
  after
    detach_connection_pool_runtime()
  end

  test "query cache starts lazily on first use" do
    detach_query_cache()

    if is_pid(Process.whereis(Selecto.Performance.QueryCache)) do
      :ok
    else
      assert Selecto.Performance.QueryCache.stats() == %{status: :not_started}
    end

    assert {:ok, cache_pid} = Selecto.Performance.QueryCache.ensure_started()
    assert is_pid(cache_pid)

    assert :miss == Selecto.Performance.QueryCache.get("lazy-start-probe")
    assert :ok == Selecto.Performance.QueryCache.put("lazy-start-probe", %{value: 1})
    assert {:ok, %{value: 1}} = Selecto.Performance.QueryCache.get("lazy-start-probe")
  after
    Selecto.Performance.QueryCache.clear()
    detach_query_cache()
  end

  defp detach_connection_pool_runtime do
    detach_child(Selecto.ConnectionPool.Runtime, :supervisor)
  end

  defp detach_query_cache do
    detach_child(Selecto.Performance.QueryCache, :genserver)
  end

  defp detach_child(module, kind) do
    # Terminate by child id: the pid-based terminate_child/2 form does not
    # resolve dynamically attached children.
    _ = Supervisor.terminate_child(Selecto.Supervisor, module)
    _ = Supervisor.delete_child(Selecto.Supervisor, module)

    case Process.whereis(module) do
      nil ->
        :ok

      alive_pid ->
        # Not managed by the app supervisor; stop it directly.
        case kind do
          :supervisor -> Supervisor.stop(alive_pid)
          :genserver -> GenServer.stop(alive_pid)
        end
    end
  end

  test "task helpers preserve supervised execution semantics" do
    task = Selecto.TaskSupervisor.async(fn -> :ok end)
    assert {:ok, :ok} = Task.yield(task)

    assert {:ok, pid} = Selecto.TaskSupervisor.start_child(fn -> :ok end)
    assert is_pid(pid)
  end
end
