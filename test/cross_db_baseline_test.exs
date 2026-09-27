Code.require_file("support/cross_db_live_adapters.exs", __DIR__)

defmodule Selecto.CrossDBBaselineTest do
  use ExUnit.Case, async: false

  alias Selecto.TestLiveAdapter.{MySQL, MariaDB, MSSQL}

  @moduletag :requires_db
  @moduletag timeout: 120_000

  @tag :postgres
  test "postgres adapter executes baseline query" do
    assert {:ok, conn} =
             connect_with_retry(fn -> SelectoDBPostgreSQL.Adapter.connect(postgres_opts()) end)

    on_exit(fn ->
      close_connection(conn)
    end)

    assert_single_value_query(SelectoDBPostgreSQL.Adapter, conn, "SELECT 1 AS value")
    assert_query_shape_suite(SelectoDBPostgreSQL.Adapter, conn)
    assert_duplicate_column_name_count(SelectoDBPostgreSQL.Adapter, conn)
  end

  @tag :mysql
  test "mysql adapter executes baseline query" do
    assert {:ok, conn} =
             connect_with_retry(fn -> MySQL.connect(mysql_opts()) end)

    on_exit(fn ->
      close_connection(conn)
    end)

    assert_single_value_query(MySQL, conn, "SELECT 1 AS value")
    assert_query_shape_suite(MySQL, conn)
    assert_duplicate_column_name_count(MySQL, conn)
    assert_stream_capability_error(MySQL, conn)
  end

  @tag :mariadb
  test "mariadb adapter executes baseline query" do
    assert {:ok, conn} =
             connect_with_retry(fn -> MariaDB.connect(mariadb_opts()) end)

    on_exit(fn ->
      close_connection(conn)
    end)

    assert_single_value_query(MariaDB, conn, "SELECT 1 AS value")
    assert_query_shape_suite(MariaDB, conn)
    assert_duplicate_column_name_count(MariaDB, conn)
    assert_stream_capability_error(MariaDB, conn)
  end

  @tag :mssql
  test "mssql adapter executes baseline query" do
    assert {:ok, conn} =
             connect_with_retry(fn -> MSSQL.connect(mssql_opts()) end)

    on_exit(fn ->
      close_connection(conn)
    end)

    assert_single_value_query(MSSQL, conn, "SELECT CAST(1 AS INT) AS value")
    assert_query_shape_suite(MSSQL, conn)
    assert_duplicate_column_name_count(MSSQL, conn)
    assert_stream_capability_error(MSSQL, conn)
  end

  @tag :sqlite
  test "sqlite adapter executes baseline query" do
    assert {:ok, conn} = SelectoDBSQLite.Adapter.connect(sqlite_opts())

    on_exit(fn ->
      close_connection(conn)
    end)

    assert_single_value_query(SelectoDBSQLite.Adapter, conn, "SELECT 1 AS value")
    assert_query_shape_suite(SelectoDBSQLite.Adapter, conn)
    assert_duplicate_column_name_count(SelectoDBSQLite.Adapter, conn)
    assert_stream_capability_error(SelectoDBSQLite.Adapter, conn)
  end

  defp assert_single_value_query(adapter, conn, sql) do
    assert {:ok, %{rows: rows, columns: columns}} = adapter.execute(conn, sql, [], [])
    assert [[value]] = rows
    assert normalize_scalar(value) == "1"
    assert [column] = columns
    assert String.downcase(to_string(column)) == "value"
  end

  defp assert_query_shape_suite(adapter, conn) do
    assert {:ok, %{rows: rows, columns: columns}} =
             adapter.execute(conn, query_shape_sql(adapter), [], [])

    assert normalize_columns(columns) == ["id", "name", "bucket"]
    assert [row] = rows

    assert row
           |> Enum.at(0)
           |> normalize_scalar() == "2"

    assert row
           |> Enum.at(1)
           |> normalize_scalar() == "alpha"

    assert row
           |> Enum.at(2)
           |> normalize_scalar() == "x"

    assert {:ok, %{rows: grouped_rows, columns: grouped_columns}} =
             adapter.execute(conn, grouped_shape_sql(), [], [])

    assert normalize_columns(grouped_columns) == ["bucket", "row_count"]

    grouped_result =
      grouped_rows
      |> Enum.map(fn [bucket, count] -> {normalize_scalar(bucket), normalize_scalar(count)} end)
      |> Enum.sort()

    assert grouped_result == [{"x", "2"}, {"y", "1"}]
  end

  # Count and projection-sum wrap the query in a derived table. MySQL, MariaDB
  # and SQL Server reject duplicate derived-table column names, so selecting
  # both `name` and `category.name` must still count correctly everywhere.
  defp assert_duplicate_column_name_count(adapter, conn) do
    suffix = System.unique_integer([:positive])
    products = "selecto_dup_products_#{suffix}"
    categories = "selecto_dup_categories_#{suffix}"

    ddl = [
      "CREATE TABLE #{categories} (id INT PRIMARY KEY, name VARCHAR(40))",
      "CREATE TABLE #{products} (id INT PRIMARY KEY, name VARCHAR(40), category_id INT, price INT)",
      "INSERT INTO #{categories} (id, name) VALUES (1, 'tools'), (2, 'toys')",
      "INSERT INTO #{products} (id, name, category_id, price) VALUES " <>
        "(1, 'hammer', 1, 5), (2, 'saw', 1, 10), (3, 'ball', 2, 2), (4, 'hammer', 1, 7)"
    ]

    try do
      Enum.each(ddl, fn sql -> assert {:ok, _} = adapter.execute(conn, sql, [], []) end)

      query =
        products
        |> duplicate_name_domain(categories)
        |> Selecto.configure(conn, adapter: adapter, validate: false)
        |> Selecto.select(["name", "category.name", {:field, "price", "total"}])
        |> Selecto.filter({"price", {:gt, 3}})

      assert {:ok, 3, count} =
               Selecto.Executor.execute_count_with_metadata(query, analyze_complexity: false)

      assert count.params == [3]

      grouped =
        query
        |> Map.update!(:set, &Map.put(&1, :selected, ["name", "category.name"]))
        |> Selecto.group_by(["name", "category.name"])

      assert {:ok, 2, _grouped} =
               Selecto.Executor.execute_count_with_metadata(grouped, analyze_complexity: false)

      assert {:ok, total, _sum} =
               Selecto.Executor.execute_projection_sum_with_metadata(
                 %{query | adapter: sum_adapter(adapter)},
                 "total",
                 analyze_complexity: false
               )

      assert normalize_scalar(total) == "22"
    after
      Enum.each([products, categories], fn table ->
        adapter.execute(conn, "DROP TABLE #{table}", [], [])
      end)
    end
  end

  defmodule ProjectionSumAdapter do
    @moduledoc false
    # Wraps a live fixture adapter to advertise :projection_sum.
    def wrap(adapter) do
      module = Module.concat(__MODULE__, adapter)

      unless Code.ensure_loaded?(module) do
        Module.create(
          module,
          quote do
            def name, do: unquote(adapter).name()
            defdelegate connect(opts), to: unquote(adapter)
            defdelegate execute(conn, query, params, opts), to: unquote(adapter)
            defdelegate placeholder(index), to: unquote(adapter)
            defdelegate quote_identifier(identifier), to: unquote(adapter)
            defdelegate dialect(), to: unquote(adapter)
            def supports?(:projection_sum), do: true
            def supports?(feature), do: unquote(adapter).supports?(feature)
          end,
          Macro.Env.location(__ENV__)
        )
      end

      module
    end
  end

  defp sum_adapter(adapter) do
    if adapter.supports?(:projection_sum), do: adapter, else: ProjectionSumAdapter.wrap(adapter)
  end

  defp duplicate_name_domain(products, categories) do
    %{
      name: "CrossDB duplicate column names",
      source: %{
        source_table: products,
        primary_key: :id,
        fields: [:id, :name, :category_id, :price],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          category_id: %{type: :integer},
          price: %{type: :integer}
        },
        associations: %{
          category: %{
            queryable: :categories,
            field: :category,
            owner_key: :category_id,
            related_key: :id
          }
        }
      },
      schemas: %{
        categories: %{
          source_table: categories,
          primary_key: :id,
          fields: [:id, :name],
          redact_fields: [],
          columns: %{id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        }
      },
      joins: %{category: %{type: :left, name: "category"}}
    }
  end

  defp assert_stream_capability_error(adapter, conn) do
    stream_probe =
      stream_probe_domain()
      |> Selecto.configure(conn, adapter: adapter, validate: false)
      |> Selecto.select(["id"])

    assert {:error, %Selecto.Error{type: :validation_error, details: details}} =
             Selecto.execute_stream(stream_probe, analyze_complexity: false)

    assert details[:unsupported_feature] == :stream
    assert details[:adapter_contract] == :supports_stream
  end

  defp query_shape_sql(MSSQL) do
    """
    SELECT id, name, bucket
    FROM (
      SELECT 1 AS id, 'bravo' AS name, 'x' AS bucket
      UNION ALL SELECT 2 AS id, 'alpha' AS name, 'x' AS bucket
      UNION ALL SELECT 3 AS id, 'charlie' AS name, 'y' AS bucket
    ) AS sample
    WHERE id >= 2
    ORDER BY name ASC
    OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY
    """
  end

  defp query_shape_sql(_adapter) do
    """
    SELECT id, name, bucket
    FROM (
      SELECT 1 AS id, 'bravo' AS name, 'x' AS bucket
      UNION ALL SELECT 2 AS id, 'alpha' AS name, 'x' AS bucket
      UNION ALL SELECT 3 AS id, 'charlie' AS name, 'y' AS bucket
    ) AS sample
    WHERE id >= 2
    ORDER BY name ASC
    LIMIT 1 OFFSET 0
    """
  end

  defp grouped_shape_sql do
    """
    SELECT bucket, COUNT(*) AS row_count
    FROM (
      SELECT 'x' AS bucket
      UNION ALL SELECT 'x' AS bucket
      UNION ALL SELECT 'y' AS bucket
    ) AS sample
    GROUP BY bucket
    ORDER BY bucket ASC
    """
  end

  defp normalize_columns(columns) do
    Enum.map(columns, fn col -> col |> to_string() |> String.downcase() end)
  end

  defp stream_probe_domain do
    %{
      name: "CrossDB Stream Probe",
      source: %{
        source_table: "stream_probe_source",
        primary_key: :id,
        fields: [:id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp connect_with_retry(fun, attempts \\ 60)

  defp connect_with_retry(fun, attempts) when attempts > 1 do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, _reason} ->
        Process.sleep(1_000)
        connect_with_retry(fun, attempts - 1)
    end
  end

  defp connect_with_retry(fun, 1), do: fun.()

  defp close_connection(conn) when is_pid(conn) do
    if Process.alive?(conn) do
      Process.exit(conn, :normal)
    end

    :ok
  end

  defp close_connection(conn) when is_reference(conn) do
    if Code.ensure_loaded?(Exqlite.Sqlite3) and function_exported?(Exqlite.Sqlite3, :close, 1) do
      _ = Exqlite.Sqlite3.close(conn)
    end

    :ok
  end

  defp close_connection(_), do: :ok

  defp normalize_scalar(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp normalize_scalar(value) when is_binary(value), do: value
  defp normalize_scalar(value), do: to_string(value)

  defp postgres_opts do
    [
      hostname: env("SELECTO_POSTGRES_HOST", "localhost"),
      port: env_int("SELECTO_POSTGRES_PORT", 5432),
      username: env("SELECTO_POSTGRES_USER", "postgres"),
      password: env("SELECTO_POSTGRES_PASSWORD", "postgres"),
      database: env("SELECTO_POSTGRES_DATABASE", "selecto_test")
    ]
  end

  defp mysql_opts do
    [
      hostname: env("SELECTO_MYSQL_HOST", "localhost"),
      port: env_int("SELECTO_MYSQL_PORT", 3306),
      username: env("SELECTO_MYSQL_USER", "root"),
      password: env("SELECTO_MYSQL_PASSWORD", "root"),
      database: env("SELECTO_MYSQL_DATABASE", "selecto_test")
    ]
  end

  defp mariadb_opts do
    [
      hostname: env("SELECTO_MARIADB_HOST", "localhost"),
      port: env_int("SELECTO_MARIADB_PORT", 3306),
      username: env("SELECTO_MARIADB_USER", "root"),
      password: env("SELECTO_MARIADB_PASSWORD", "root"),
      database: env("SELECTO_MARIADB_DATABASE", "selecto_test")
    ]
  end

  defp mssql_opts do
    [
      hostname: env("SELECTO_MSSQL_HOST", "localhost"),
      port: env_int("SELECTO_MSSQL_PORT", 1433),
      username: env("SELECTO_MSSQL_USER", "sa"),
      password: env("SELECTO_MSSQL_PASSWORD", "StrongPass123!"),
      database: env("SELECTO_MSSQL_DATABASE", "master"),
      ssl: false
    ]
  end

  defp sqlite_opts do
    [
      database: env("SELECTO_SQLITE_DATABASE", ":memory:")
    ]
  end

  defp env(name, default), do: System.get_env(name, default)

  defp env_int(name, default) do
    name
    |> env(Integer.to_string(default))
    |> String.to_integer()
  end
end
