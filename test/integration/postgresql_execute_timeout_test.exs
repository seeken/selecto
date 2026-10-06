defmodule Selecto.Integration.PostgreSQLExecuteTimeoutTest do
  @moduledoc """
  `Selecto.execute/2` against a live PostgreSQL database, through the
  default task path and through the caller path an adapter selects with
  `supports?(:execute_timeout)`: the same rows, and the same timeout error
  for a query that sleeps past `:timeout`.
  """

  use ExUnit.Case, async: false

  @moduletag :requires_db

  import ExUnit.CaptureLog

  # The PostgreSQL adapter, declaring that execute/4 enforces `:timeout`
  # (Postgrex aborts the statement and returns an error when it elapses).
  defmodule TimeoutEnforcingAdapter do
    @moduledoc false
    @delegate SelectoDBPostgreSQL.Adapter

    for {function, arity} <- @delegate.__info__(:functions), function != :supports? do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(function)(unquote_splicing(args)),
        do: @delegate.unquote(function)(unquote_splicing(args))
    end

    def supports?(:execute_timeout), do: true
    def supports?(feature), do: @delegate.supports?(feature)
  end

  @adapters [SelectoDBPostgreSQL.Adapter, TimeoutEnforcingAdapter]

  setup do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: System.get_env("SELECTO_POSTGRES_HOST", "localhost"),
        port: String.to_integer(System.get_env("SELECTO_POSTGRES_PORT", "5432")),
        username: System.get_env("SELECTO_POSTGRES_USER", "postgres"),
        password: System.get_env("SELECTO_POSTGRES_PASSWORD", "password"),
        database: System.get_env("SELECTO_POSTGRES_DATABASE", "selecto_test"),
        pool_size: 1
      )

    suffix = System.unique_integer([:positive])
    items = "selecto_entry_items_#{suffix}"
    slow = "selecto_entry_slow_#{suffix}"

    Postgrex.query!(
      conn,
      "CREATE TABLE #{items} (id integer PRIMARY KEY, name text, price numeric(10,2), " <>
        "added_at timestamp)",
      []
    )

    Postgrex.query!(
      conn,
      "INSERT INTO #{items} SELECT g, 'item ' || g, g * 1.25, " <>
        "timestamp '2026-01-01' + g * interval '1 hour' FROM generate_series(1, 2000) g",
      []
    )

    # Reading the view takes at least one second.
    Postgrex.query!(
      conn,
      "CREATE VIEW #{slow} AS SELECT id, name, price, added_at FROM #{items}, " <>
        "pg_sleep(1) WHERE id <= 3",
      []
    )

    on_exit(fn ->
      {:ok, cleanup} =
        Postgrex.start_link(
          hostname: System.get_env("SELECTO_POSTGRES_HOST", "localhost"),
          port: String.to_integer(System.get_env("SELECTO_POSTGRES_PORT", "5432")),
          username: System.get_env("SELECTO_POSTGRES_USER", "postgres"),
          password: System.get_env("SELECTO_POSTGRES_PASSWORD", "password"),
          database: System.get_env("SELECTO_POSTGRES_DATABASE", "selecto_test")
        )

      Postgrex.query!(cleanup, "DROP VIEW IF EXISTS #{slow}", [])
      Postgrex.query!(cleanup, "DROP TABLE IF EXISTS #{items}", [])
      GenServer.stop(cleanup)
    end)

    {:ok, conn: conn, items: items, slow: slow}
  end

  defp query(conn, table, adapter) do
    domain = %{
      name: "Execute timeout",
      source: %{
        source_table: table,
        primary_key: :id,
        fields: [:id, :name, :price, :added_at],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          price: %{type: :decimal},
          added_at: %{type: :naive_datetime}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    Selecto.configure(domain, conn, adapter: adapter)
    |> Selecto.select(["id", "name", "price", "added_at"])
    |> Selecto.filter({"id", {:gt, 0}})
    |> Selecto.order_by(["id"])
  end

  test "both paths return the same rows", %{conn: conn, items: items} do
    [task_result, caller_result] =
      for adapter <- @adapters, do: Selecto.execute(query(conn, items, adapter))

    assert {:ok, {rows, ["id", "name", "price", "added_at"], _aliases}} = task_result
    assert length(rows) == 2000
    assert hd(rows) == [1, "item 1", Decimal.new("1.25"), ~N[2026-01-01 01:00:00.000000]]
    assert task_result == caller_result
  end

  test "a query sleeping past the timeout returns the same timeout error on both paths",
       %{conn: conn, slow: slow} do
    for adapter <- @adapters do
      started = System.monotonic_time(:millisecond)

      log =
        capture_log(fn ->
          assert {:error, %Selecto.Error{} = error} =
                   Selecto.execute(query(conn, slow, adapter), timeout: 100)

          assert error.type == :timeout_error
          assert error.message == "Query exceeded timeout of 100ms"
          assert %{timeout: 100, duration: duration} = error.details
          assert map_size(error.details) == 2
          assert duration >= 100
        end)

      # The query was abandoned, not waited for.
      assert System.monotonic_time(:millisecond) - started < 900
      assert log =~ "[Selecto] Query timeout after 100ms"

      # The connection recovers for the next query.
      assert {:ok, {[[1, "item 1", _, _] | _], _, _}} =
               eventually(fn -> Selecto.execute(query(conn, slow, adapter)) end)
    end
  end

  test "a slow query within the timeout succeeds on both paths", %{conn: conn, slow: slow} do
    for adapter <- @adapters do
      assert {:ok, {rows, _columns, _aliases}} =
               eventually(fn -> Selecto.execute(query(conn, slow, adapter), timeout: 5_000) end)

      assert length(rows) == 3
    end
  end

  # After a timeout the pool reconnects in the background.
  defp eventually(fun, attempts \\ 50) do
    case fun.() do
      {:ok, _result} = ok ->
        ok

      {:error, _error} = error when attempts <= 1 ->
        error

      {:error, _error} ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
