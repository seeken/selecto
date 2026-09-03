# Driver-backed fixtures for the core's opt-in live SQL smoke tests.
# Keep these separate from the compiler stubs: their execute callbacks must
# query a real server. Production adapter certification lives in the siblings.
defmodule Selecto.TestLiveAdapter.MySQL do
  @behaviour Selecto.DB.Adapter

  def name, do: :mysql
  def connect(connection) when is_pid(connection), do: {:ok, connection}
  def connect(opts), do: MyXQL.start_link(opts)

  def execute(connection, query, params, opts) do
    case MyXQL.query(connection, IO.iodata_to_binary(query), params, opts) do
      {:ok, result} -> {:ok, %{rows: result.rows || [], columns: result.columns || []}}
      {:error, reason} -> {:error, reason}
    end
  end

  defdelegate placeholder(index), to: SelectoDBMySQL.Adapter
  defdelegate quote_identifier(identifier), to: SelectoDBMySQL.Adapter
  defdelegate format_datetime(expression, format), to: SelectoDBMySQL.Adapter
  defdelegate dialect(), to: SelectoDBMySQL.Adapter
  def supports?(_feature), do: false
end

defmodule Selecto.TestLiveAdapter.MariaDB do
  @behaviour Selecto.DB.Adapter

  def name, do: :mariadb
  defdelegate connect(opts), to: Selecto.TestLiveAdapter.MySQL
  defdelegate execute(connection, query, params, opts), to: Selecto.TestLiveAdapter.MySQL
  defdelegate placeholder(index), to: SelectoDBMariaDB.Adapter
  defdelegate quote_identifier(identifier), to: SelectoDBMariaDB.Adapter
  defdelegate format_datetime(expression, format), to: SelectoDBMariaDB.Adapter
  defdelegate dialect(), to: SelectoDBMariaDB.Adapter
  def supports?(_feature), do: false
end

defmodule Selecto.TestLiveAdapter.MSSQL do
  @behaviour Selecto.DB.Adapter

  def name, do: :mssql
  def connect(connection) when is_pid(connection), do: {:ok, connection}
  def connect(opts), do: Tds.start_link(opts)

  def execute(connection, query, params, opts) do
    case Tds.query(connection, IO.iodata_to_binary(query), params, opts) do
      {:ok, result} -> {:ok, %{rows: result.rows || [], columns: result.columns || []}}
      {:error, reason} -> {:error, reason}
    end
  end

  defdelegate placeholder(index), to: SelectoDBMSSQL.Adapter
  defdelegate quote_identifier(identifier), to: SelectoDBMSSQL.Adapter
  defdelegate format_datetime(expression, format), to: SelectoDBMSSQL.Adapter
  defdelegate dialect(), to: SelectoDBMSSQL.Adapter
  def supports?(_feature), do: false
end
