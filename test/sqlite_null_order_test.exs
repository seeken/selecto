defmodule Selecto.SQLiteNullOrderTest do
  use ExUnit.Case, async: true

  # SQLite sorts NULLs first ascending and last descending. Selecto places
  # them as PostgreSQL does (last ascending, first descending) unless the
  # ordering names an explicit placement. These tests execute the generated
  # SQL against an in-memory SQLite database.

  alias SelectoDBSQLite.Adapter

  # A connected SQLite provider whose reported version predates native
  # NULLS FIRST/LAST (3.30.0), or which cannot report a version at all.
  defmodule OldSQLiteAdapter do
    @moduledoc false
    for {name, arity} <- SelectoDBSQLite.Adapter.__info__(:functions),
        name != :connection_capabilities do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: SelectoDBSQLite.Adapter.unquote(name)(unquote_splicing(args))
    end

    def connection_capabilities(_connection), do: %{server_version: "3.29.0"}
  end

  defmodule UnversionedSQLiteAdapter do
    @moduledoc false
    for {name, arity} <- SelectoDBSQLite.Adapter.__info__(:functions),
        name != :connection_capabilities do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: SelectoDBSQLite.Adapter.unquote(name)(unquote_splicing(args))
    end
  end

  # bucket: 1 => "b", 2 => NULL, 3 => "a"
  @expected %{
    asc: [3, 1, 2],
    desc: [2, 1, 3],
    asc_nulls_first: [2, 3, 1],
    asc_nulls_last: [3, 1, 2],
    desc_nulls_first: [2, 1, 3],
    desc_nulls_last: [1, 3, 2]
  }

  setup do
    assert {:ok, connection} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Adapter.disconnect(connection) end)

    for sql <- [
          "CREATE TABLE items (id INTEGER PRIMARY KEY, bucket TEXT)",
          "INSERT INTO items VALUES (1, 'b'), (2, NULL), (3, 'a')"
        ] do
      assert {:ok, _} = Adapter.execute(connection, sql, [], [])
    end

    {:ok, connection: connection, base: configure(connection, Adapter)}
  end

  test "the test provider reports the connected SQLite version", %{connection: connection} do
    assert %{server_version: version} = Adapter.connection_capabilities(connection)
    assert version =~ ~r/\A\d+\.\d+\.\d+\z/
  end

  describe "top-level ORDER BY" do
    test "every direction places NULLs as PostgreSQL does", %{base: base} do
      for {dir, expected} <- @expected, selected <- [["id"], ["id", "bucket"]] do
        query = base |> Selecto.select(selected) |> Selecto.order_by([{"bucket", dir}])
        assert ids(query) == expected, "#{dir} with #{inspect(selected)}"
      end
    end

    test "a bare field keeps its NULLS FIRST meaning", %{base: base} do
      query = base |> Selecto.select(["id"]) |> Selecto.order_by(["bucket"])
      assert ids(query) == @expected.asc_nulls_first
    end

    test "unqualified directions add a leading NULL-placement term", %{base: base} do
      assert order_sql(base |> Selecto.select(["id"]) |> Selecto.order_by([{"bucket", :asc}])) ==
               "CASE WHEN selecto_root.bucket IS NULL THEN 1 ELSE 0 END asc, selecto_root.bucket asc"

      assert order_sql(base |> Selecto.select(["id"]) |> Selecto.order_by([{"bucket", :desc}])) ==
               "CASE WHEN selecto_root.bucket IS NULL THEN 0 ELSE 1 END asc, selecto_root.bucket desc"

      # SQLite's own placement already matches these two.
      assert order_sql(
               base
               |> Selecto.select(["id"])
               |> Selecto.order_by([{"bucket", :asc_nulls_first}, {"id", :desc_nulls_last}])
             ) == "selecto_root.bucket asc, selecto_root.id desc"
    end
  end

  describe "set-operation ORDER BY" do
    test "every direction places NULLs as PostgreSQL does", %{base: base} do
      for {dir, expected} <- @expected do
        query = set_query(base) |> Selecto.order_by([{"bucket", dir}])
        assert ids(query) == expected, "#{dir}"
      end
    end

    test "uses native NULLS FIRST/LAST on the projected position", %{base: base} do
      for {dir, spelled} <- [
            asc: "2 asc nulls last",
            desc: "2 desc nulls first",
            asc_nulls_last: "2 asc nulls last",
            desc_nulls_first: "2 desc nulls first",
            # SQLite's own placement already matches these two.
            asc_nulls_first: "2 asc",
            desc_nulls_last: "2 desc"
          ] do
        {sql, _params} = Selecto.to_sql(set_query(base) |> Selecto.order_by([{"bucket", dir}]))
        assert sql =~ ~r/order by\s+#{spelled}\s*$/i
        refute sql =~ ~r/CASE WHEN/i
      end
    end

    test "compile-only contexts render native placement without a version probe" do
      for connection <- [nil, :mock_connection] do
        {sql, _params} =
          domain()
          |> Selecto.configure(connection, adapter: SelectoDBPostgreSQL.Adapter, validate: false)
          |> Map.put(:adapter, UnversionedSQLiteAdapter)
          |> set_query()
          |> Selecto.order_by([{"bucket", :asc}])
          |> Selecto.to_sql()

        assert sql =~ ~r/order by\s+2 asc nulls last/i
      end
    end

    test "a connected provider older than 3.30.0 or without a version is refused", %{
      connection: connection
    } do
      for adapter <- [OldSQLiteAdapter, UnversionedSQLiteAdapter] do
        assert_raise RuntimeError,
                     "SQLite provider does not support NULL ordering for set results",
                     fn ->
                       configure(connection, adapter)
                       |> set_query()
                       |> Selecto.order_by([{"bucket", :asc}])
                       |> Selecto.to_sql()
                     end
      end
    end
  end

  # Captured from 81b89bf, before SQLite NULL ordering changed. Every SQLite
  # change is gated on the adapter name, so PostgreSQL output is identical.
  test "PostgreSQL output is unchanged" do
    base = configure(:mock_connection, SelectoDBPostgreSQL.Adapter)

    for {dir, expected} <- [
          asc: "selecto_root.bucket asc",
          desc: "selecto_root.bucket desc",
          asc_nulls_first: "selecto_root.bucket asc nulls first",
          asc_nulls_last: "selecto_root.bucket asc nulls last",
          desc_nulls_first: "selecto_root.bucket desc nulls first",
          desc_nulls_last: "selecto_root.bucket desc nulls last"
        ] do
      assert order_sql(base |> Selecto.select(["id"]) |> Selecto.order_by([{"bucket", dir}])) ==
               expected
    end

    {set_sql, _} = set_query(base) |> Selecto.order_by([{"bucket", :asc}]) |> Selecto.to_sql()
    assert set_sql =~ ~r/order by\s+2 asc\s*$/i

    {window_sql, _} =
      base
      |> Selecto.select(["id"])
      |> Selecto.window_function(:row_number, [], over: [order_by: [{"bucket", :desc}]], as: "rn")
      |> Selecto.to_sql()

    assert window_sql =~ "OVER (ORDER BY selecto_root.bucket DESC)"
  end

  defp configure(connection, adapter),
    do: Selecto.configure(domain(), connection, adapter: adapter, validate: false)

  defp set_query(base) do
    left = base |> Selecto.select(["id", "bucket"]) |> Selecto.filter({"id", {:in, [1]}})
    right = base |> Selecto.select(["id", "bucket"]) |> Selecto.filter({"id", {:in, [2, 3]}})
    Selecto.union(left, right)
  end

  defp order_sql(query) do
    {sql, _params} = Selecto.to_sql(query)
    [_, order] = String.split(sql, ~r/order by/i, parts: 2)
    String.trim(order)
  end

  defp ids(query), do: query |> rows() |> Enum.map(&hd/1)

  defp rows(query) do
    {sql, params} = Selecto.to_sql(query)
    assert {:ok, %{rows: rows}} = Adapter.execute(query.connection, sql, params, [])
    rows
  end

  defp domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :bucket],
        redact_fields: [],
        columns: %{id: %{type: :integer}, bucket: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end
end
