defmodule Selecto.ConfigurationAdapterTest do
  use ExUnit.Case, async: true

  defmodule FakeAdapter do
    @behaviour Selecto.DB.Adapter

    @impl true
    def name, do: :fake

    @impl true
    def connect(_opts), do: {:ok, spawn(fn -> Process.sleep(:infinity) end)}

    @impl true
    def disconnect(connection) do
      Process.exit(connection, :kill)
      :ok
    end

    @impl true
    def execute(_conn, _query, _params, _opts), do: {:ok, %{rows: [[1]], columns: ["id"]}}

    @impl true
    def placeholder(_index), do: "?"

    @impl true
    def quote_identifier(identifier), do: "`#{identifier}`"

    @impl true
    def supports?(_feature), do: true
  end

  defmodule FakeRepo do
  end

  defmodule FakeSchema do
    use Ecto.Schema

    schema "widgets" do
      field(:name, :string)
    end
  end

  defp domain do
    %{
      name: "Config adapter test",
      source: %{
        source_table: "users",
        primary_key: :id,
        fields: [:id],
        redact_fields: [],
        columns: %{id: %{type: :integer}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  test "configure uses adapter direct connection when pooling is disabled" do
    selecto =
      domain()
      |> Selecto.configure([], adapter: FakeAdapter, validate: false)
      |> Selecto.select(["id"])

    assert is_pid(selecto.connection)
    assert selecto.adapter == FakeAdapter
    assert {:ok, {[[1]], ["id"], aliases}} = Selecto.execute(selecto, analyze_complexity: false)
    assert length(aliases) == 1
    assert is_binary(hd(aliases))

    Process.exit(selecto.connection, :kill)
  end

  test "from_ecto forwards the explicit adapter to configuration" do
    selecto =
      Selecto.from_ecto(FakeRepo, FakeSchema,
        adapter: FakeAdapter,
        validate: false
      )

    assert selecto.adapter == FakeAdapter
    assert is_pid(selecto.connection)

    Process.exit(selecto.connection, :kill)
  end

  test "runtime inspection does not expose the opaque connection" do
    secret = "adapter-password-must-not-be-inspected"
    runtime = Selecto.Runtime.Context.new(FakeAdapter, %{password: secret})
    selecto = %Selecto{runtime: runtime, adapter: FakeAdapter, connection: %{password: secret}}

    refute inspect(runtime) =~ secret
    refute inspect(selecto) =~ secret
  end

  test "disconnect delegates connection lifecycle to the configured adapter" do
    selecto = Selecto.configure(domain(), [], adapter: FakeAdapter, validate: false)
    connection = selecto.connection
    monitor = Process.monitor(connection)

    assert :ok = Selecto.disconnect(selecto)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :killed}
  end

  test "a tagged runtime context supplies its adapter without reconnecting" do
    runtime = Selecto.Runtime.Context.new(FakeAdapter, :compile_only, %{purpose: :compile})

    selecto = Selecto.configure(domain(), runtime, validate: false)

    assert selecto.adapter == FakeAdapter
    assert selecto.connection == :compile_only
    assert selecto.runtime == runtime
  end

  test "an explicit adapter cannot disagree with a tagged runtime context" do
    runtime = Selecto.Runtime.Context.new(FakeAdapter, :compile_only)

    assert_raise ArgumentError, ~r/does not match runtime context adapter/, fn ->
      Selecto.configure(domain(), runtime, adapter: String, validate: false)
    end
  end

  test "configure reuses pooled adapter reference for non-postgresql adapters" do
    selecto =
      domain()
      |> Selecto.configure([], adapter: FakeAdapter, pool: true, validate: false)
      |> Selecto.select(["id"])

    assert %{adapter: FakeAdapter, connection: connection, manager: _manager} = selecto.connection
    assert is_pid(connection)

    assert {:ok, {[[1]], ["id"], aliases}} = Selecto.execute(selecto, analyze_complexity: false)
    assert length(aliases) == 1
    assert is_binary(hd(aliases))
    assert :ok = Selecto.ConnectionPool.stop_pool(selecto.connection)
  end
end
