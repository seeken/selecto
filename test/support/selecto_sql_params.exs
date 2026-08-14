defmodule Selecto.TestSQLParams do
  @moduledoc false

  def finalize(fragments, opts \\ []) do
    Selecto.SQL.Params.finalize(
      fragments,
      Keyword.put_new(opts, :adapter, SelectoDBPostgreSQL.Adapter)
    )
  end

  def finalize_with_ctes(fragments, opts \\ []) do
    Selecto.SQL.Params.finalize_with_ctes(
      fragments,
      Keyword.put_new(opts, :adapter, SelectoDBPostgreSQL.Adapter)
    )
  end
end
