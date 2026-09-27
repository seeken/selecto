defmodule Selecto.ConnectionPoolRuntimeRaceTest do
  @moduledoc """
  Regression tests for the lazy pool-runtime start race.

  `Selecto.ConnectionPool.Runtime` registers its name before its children
  (the pool registry and manager supervisor) finish starting. Concurrent
  first pooled queries used to observe the runtime pid, treat it as ready,
  and then hit the half-started registry (`ArgumentError: unknown registry`
  or `not a key that exists in the table`).
  """

  use ExUnit.Case, async: false

  alias Selecto.ConnectionPool
  alias Selecto.ConnectionPool.Runtime

  @rounds 20
  @concurrency 100

  defmodule Connection do
    use GenServer

    def init(:ok), do: {:ok, %{}}
  end

  defmodule Adapter do
    def connect(_opts), do: GenServer.start(Selecto.ConnectionPoolRuntimeRaceTest.Connection, :ok)
    def execute(_conn, _query, _params, _opts), do: {:ok, %{rows: [[1]], columns: ["id"]}}
    def supports?(_feature), do: true
  end

  setup do
    detach_runtime()
    on_exit(&detach_runtime/0)
    :ok
  end

  test "concurrent first pooled queries against a fresh runtime all succeed" do
    for round <- 1..@rounds do
      detach_runtime()
      refute Process.whereis(Runtime)

      config = [database: "race_#{round}", verification_identity: make_ref()]

      results =
        1..@concurrency
        |> Enum.map(fn _ ->
          Task.async(fn ->
            try do
              with {:ok, pool_ref} <- ConnectionPool.start_pool(config, adapter: Adapter) do
                ConnectionPool.execute(pool_ref, "SELECT 1", [])
              end
            rescue
              error -> {:raised, error}
            catch
              :exit, reason -> {:exited, reason}
            end
          end)
        end)
        |> Task.await_many(30_000)

      assert Enum.frequencies_by(results, &result_kind/1) == %{ok: @concurrency},
             "round #{round}: #{inspect(Enum.reject(results, &match?({:ok, _}, &1)) |> Enum.take(3))}"
    end
  end

  test "ensure_started only returns once the registry and manager supervisor are usable" do
    for _round <- 1..@rounds do
      detach_runtime()

      results =
        1..@concurrency
        |> Enum.map(fn index ->
          Task.async(fn ->
            try do
              {:ok, _pid} = Runtime.ensure_started()
              Registry.lookup(Selecto.ConnectionPool.Registry, {:probe, index})
              DynamicSupervisor.count_children(Selecto.ConnectionPool.ManagerSupervisor)
              :ok
            rescue
              error -> {:raised, error}
            catch
              :exit, reason -> {:exited, reason}
            end
          end)
        end)
        |> Task.await_many(30_000)

      assert Enum.uniq(results) == [:ok]
    end
  end

  test "child_spec/1 lets hosts supervise the runtime explicitly" do
    assert %{id: Runtime, type: :supervisor, start: {Runtime, :start_link, [[]]}} =
             Runtime.child_spec([])

    {:ok, host} = Supervisor.start_link([Runtime], strategy: :one_for_one)

    try do
      runtime_pid = Process.whereis(Runtime)
      assert is_pid(runtime_pid)
      assert Runtime.ready?()
      # The lazy path reuses the host-supervised runtime instead of starting another.
      assert {:ok, ^runtime_pid} = Runtime.ensure_started()

      refute Enum.any?(
               Supervisor.which_children(Selecto.Supervisor),
               &match?({Runtime, _, _, _}, &1)
             )
    after
      Supervisor.stop(host)
    end
  end

  defp result_kind({:ok, _}), do: :ok
  defp result_kind({:error, reason}), do: {:error, reason}
  defp result_kind({:raised, %{__struct__: struct}}), do: {:raised, struct}
  defp result_kind({:exited, _reason}), do: :exited

  defp detach_runtime do
    _ = Supervisor.terminate_child(Selecto.Supervisor, Runtime)
    _ = Supervisor.delete_child(Selecto.Supervisor, Runtime)

    case Process.whereis(Runtime) do
      nil ->
        :ok

      pid ->
        try do
          Supervisor.stop(pid)
        catch
          :exit, _reason -> :ok
        end
    end
  end
end
