defmodule Selecto.Dialect.Query.Collection do
  @moduledoc """
  Governed correlated collection query with compiled expressions and bindings.
  Core owns field resolution, correlation, guards and parameter ordering; the
  dialect only renders the enclosing collection syntax.
  """
  @enforce_keys [:format, :fields, :table, :table_alias, :where, :params]
  defstruct [:format, :fields, :table, :table_alias, :where, :params]

  @type t :: %__MODULE__{
          format: :json_agg | :array_agg,
          fields: [{iodata(), iodata()}],
          table: iodata(),
          table_alias: iodata(),
          where: iodata(),
          params: list()
        }
end
