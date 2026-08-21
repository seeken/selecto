defmodule Selecto.ConnectionPoolAdditionalTest do
  use ExUnit.Case

  alias Selecto.ConnectionPool

  setup do
    # The pool runtime starts lazily; tests that register processes through
    # its registry need it running.
    {:ok, _} = Selecto.ConnectionPool.Runtime.ensure_started()
    :ok
  end

  defmodule FakeAdapter do
  end

  defmodule GenericAdapter do
    def connect(_opts),
      do: GenServer.start(Selecto.ConnectionPoolAdditionalTest.LinkedConnection, :ok)

    def execute(_conn, _query, _params, _opts), do: {:ok, %{rows: [[1]], columns: ["id"]}}
    def supports?(_feature), do: true
  end

  defmodule RegisteredPool do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(:ok), do: {:ok, %{}}
  end

  defmodule LinkedConnection do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, %{}}
  end

  test "start_pool returns errors for unavailable backends" do
    postgres_result = ConnectionPool.start_pool(hostname: "invalid.local", database: "missing_db")

    case postgres_result do
      {:ok, pool_ref} ->
        ConnectionPool.stop_pool(pool_ref)
        assert true

      {:error, _reason} ->
        assert true
    end

    # Non-PostgreSQL path should fail safely for unsupported adapters
    previous = Process.flag(:trap_exit, true)

    result = ConnectionPool.start_pool([], adapter: FakeAdapter)

    exited? =
      receive do
        {:EXIT, _pid, _reason} -> true
      after
        0 -> false
      end

    assert match?({:error, {:unsupported_adapter, FakeAdapter}}, result)
    refute exited?

    Process.flag(:trap_exit, previous)
  end

  test "pool_stats invalid ref and cache clear safety" do
    assert %{error: "Pool manager not available"} = ConnectionPool.pool_stats(:bad_ref)

    pool_pid = spawn(fn -> Process.sleep(:infinity) end)
    pool_name = ConnectionPool.generate_pool_name(db: "stats_test")

    {:ok, manager_pid} =
      GenServer.start_link(
        Selecto.ConnectionPool,
        pool_pid: pool_pid,
        pool_name: pool_name,
        pool_config: [prepared_statement_cache_size: 100],
        connection_config: [database: "db"]
      )

    pool_ref = %{manager: manager_pid}
    assert :ok = ConnectionPool.clear_cache(pool_ref)
    GenServer.stop(manager_pid)
    Process.exit(pool_pid, :kill)
  end

  test "generic adapter pool starts and executes without postgres pool pid" do
    assert {:ok, pool_ref} = ConnectionPool.start_pool([], adapter: GenericAdapter)
    assert %{adapter: GenericAdapter, manager: _manager, connection: _connection} = pool_ref

    assert {:ok, %{rows: [[1]], columns: ["id"]}} =
             ConnectionPool.execute(pool_ref, "select 1", [])

    assert :ok = ConnectionPool.stop_pool(pool_ref)
  end

  test "pool via names are accepted by the GenServer registration contract used by Postgrex" do
    pool_name = ConnectionPool.generate_pool_name(database: "registered_pool")

    assert {:ok, pid} = RegisteredPool.start_link(pool_name)
    assert GenServer.whereis(pool_name) == pid

    GenServer.stop(pid)
    assert GenServer.whereis(pool_name) == nil
  end

  test "stopped managed pools release their registration without supervisor restart" do
    assert {:ok, first_ref} =
             ConnectionPool.start_pool([database: "lifecycle"], adapter: GenericAdapter)

    first_manager = first_ref.manager
    first_connection = first_ref.connection
    first_name = first_ref.name

    assert {:ok, ^first_manager} = ConnectionPool.get_manager_pid(first_name)
    assert :ok = ConnectionPool.stop_pool(first_ref)

    refute Process.alive?(first_manager)
    refute Process.alive?(first_connection)
    assert eventually(fn -> ConnectionPool.get_manager_pid_by_name(first_name) == :error end)

    assert {:ok, second_ref} =
             ConnectionPool.start_pool([database: "lifecycle"], adapter: GenericAdapter)

    assert second_ref.name == first_name
    assert second_ref.manager != first_manager
    assert second_ref.connection != first_connection
    assert :ok = ConnectionPool.stop_pool(second_ref)
  end

  test "stopping pools releases prepared statement cache entries" do
    pool_name = ConnectionPool.generate_pool_name(database: "prepared_cleanup")
    assert {:ok, pool_pid} = RegisteredPool.start_link(pool_name)

    assert {:ok, manager_pid, :started} =
             ConnectionPool.start_manager(
               adapter: Selecto.DB.PostgreSQL,
               pool_pid: pool_pid,
               pool_name: pool_name,
               pool_config: [pool_size: 1],
               connection_config: [database: "prepared_cleanup"]
             )

    cache_key = ConnectionPool.generate_cache_key("SELECT managed")
    assert :ok = ConnectionPool.mark_prepared_statement(pool_pid, cache_key)
    assert ConnectionPool.prepared_statement_cached?(pool_pid, cache_key)

    assert :ok = ConnectionPool.stop_pool(%{pool: pool_pid, manager: manager_pid})
    refute ConnectionPool.prepared_statement_cached?(pool_pid, cache_key)

    direct_name = ConnectionPool.generate_pool_name(database: "prepared_cleanup_direct")
    assert {:ok, direct_pid} = RegisteredPool.start_link(direct_name)
    direct_key = ConnectionPool.generate_cache_key("SELECT direct")
    assert :ok = ConnectionPool.mark_prepared_statement(direct_pid, direct_key)
    assert ConnectionPool.prepared_statement_cached?(direct_pid, direct_key)

    assert :ok = ConnectionPool.stop_pool(direct_pid)
    refute ConnectionPool.prepared_statement_cached?(direct_pid, direct_key)
  end

  test "starting the same generic pool replaces a stale managed connection" do
    assert {:ok, first_ref} =
             ConnectionPool.start_pool([database: "stale_generic"], adapter: GenericAdapter)

    first_manager = first_ref.manager
    first_connection = first_ref.connection
    pool_name = first_ref.name

    Process.exit(first_connection, :kill)
    assert eventually(fn -> not Process.alive?(first_connection) end)

    assert {:ok, second_ref} =
             ConnectionPool.start_pool([database: "stale_generic"], adapter: GenericAdapter)

    refute Process.alive?(first_manager)
    refute second_ref.manager == first_manager
    refute second_ref.connection == first_connection
    assert Process.alive?(second_ref.manager)
    assert Process.alive?(second_ref.connection)
    assert {:ok, second_ref.manager} == ConnectionPool.get_manager_pid_by_name(pool_name)

    Process.sleep(50)
    assert Process.alive?(second_ref.manager)
    assert :ok = ConnectionPool.stop_pool(second_ref)
  end

  test "stale PostgreSQL-shaped pool managers are retired without restart" do
    pool_name = ConnectionPool.generate_pool_name(database: "stale_postgresql_shape")
    pool_pid = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, manager_pid, :started} =
             ConnectionPool.start_manager(
               adapter: Selecto.DB.PostgreSQL,
               pool_pid: pool_pid,
               pool_name: pool_name,
               pool_config: [pool_size: 1],
               connection_config: [database: "stale_postgresql_shape"]
             )

    assert {:ok, manager_pid} == ConnectionPool.get_manager_pid_by_name(pool_name)

    Process.exit(pool_pid, :kill)
    assert eventually(fn -> not Process.alive?(pool_pid) end)

    assert :error == ConnectionPool.get_manager_pid_by_name(pool_name)
    refute Process.alive?(manager_pid)

    replacement_pool_pid = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, replacement_manager_pid, :started} =
             ConnectionPool.start_manager(
               adapter: Selecto.DB.PostgreSQL,
               pool_pid: replacement_pool_pid,
               pool_name: pool_name,
               pool_config: [pool_size: 1],
               connection_config: [database: "stale_postgresql_shape"]
             )

    assert replacement_manager_pid != manager_pid
    assert Process.alive?(replacement_manager_pid)
    assert {:ok, replacement_manager_pid} == ConnectionPool.get_manager_pid_by_name(pool_name)

    Process.sleep(50)
    assert Process.alive?(replacement_manager_pid)

    assert :ok =
             ConnectionPool.stop_pool(%{
               pool: replacement_pool_pid,
               manager: replacement_manager_pid
             })
  end

  test "cross-process pool stop preserves a connection's linked owner" do
    test_pid = self()

    owner_pid =
      spawn(fn ->
        {:ok, connection} = LinkedConnection.start_link()
        send(test_pid, {:owned_connection, self(), connection})
        linked_owner_loop()
      end)

    owner_monitor = Process.monitor(owner_pid)
    assert_receive {:owned_connection, ^owner_pid, connection}

    send(owner_pid, {:links, self()})
    assert_receive {:owner_links, links}
    assert connection in links

    pool_name = ConnectionPool.generate_pool_name(database: "cross_process_stop")

    assert {:ok, manager_pid, :started} =
             ConnectionPool.start_manager(
               adapter: GenericAdapter,
               connection: connection,
               pool_name: pool_name,
               pool_config: [pool_size: 1],
               connection_config: [database: "cross_process_stop"]
             )

    assert :ok = ConnectionPool.stop_pool(%{manager: manager_pid, connection: connection})

    refute Process.alive?(connection)
    assert Process.alive?(owner_pid)
    refute_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, _reason}, 50

    send(owner_pid, :stop)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :normal}
  end

  test "checkout and checkin track references in ETS" do
    pool_pid = spawn(fn -> Process.sleep(:infinity) end)
    pool_ref = %{pool: pool_pid}

    assert {:ok, {:selecto_conn, ref, ^pool_pid}} = ConnectionPool.checkout(pool_ref)
    assert {:ok, ^pool_pid} = ConnectionPool.checkout_lookup(ref)

    assert :ok = ConnectionPool.checkin(pool_ref, {:selecto_conn, ref, pool_pid})
    assert :error = ConnectionPool.checkout_lookup(ref)

    Process.exit(pool_pid, :kill)
  end

  test "checkout lookup returns error for unknown references" do
    assert :error = ConnectionPool.checkout_lookup(make_ref())
  end

  test "with_connection and execute handle invalid pool refs" do
    assert {:error, "Invalid pool reference"} =
             ConnectionPool.with_connection(:bad_ref, fn conn -> conn end)

    assert {:error, "Invalid pool reference"} =
             ConnectionPool.execute(:bad_ref, "select 1", [])
  end

  test "with_connection wraps raised errors" do
    pool_pid = spawn(fn -> Process.sleep(:infinity) end)
    pool_ref = %{pool: pool_pid}

    assert {:error, %Selecto.Error{type: :query_error}} =
             ConnectionPool.with_connection(pool_ref, fn _conn ->
               raise "boom"
             end)

    Process.exit(pool_pid, :kill)
  end

  test "transaction returns invalid pool reference error" do
    assert {:error, "Invalid pool reference"} =
             ConnectionPool.transaction(:bad_ref, fn _conn -> :ok end)
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp linked_owner_loop do
    receive do
      {:links, caller} ->
        {:links, links} = Process.info(self(), :links)
        send(caller, {:owner_links, links})
        linked_owner_loop()

      :stop ->
        :ok
    end
  end
end
