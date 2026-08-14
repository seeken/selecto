defmodule Selecto.Dialect.TableFunction.Join do
  @moduledoc "Portable table-function or lateral join presented to an adapter dialect."

  @enforce_keys [:join_type, :source_sql, :alias]
  defstruct [:join_type, :source_sql, :alias, :ordinality_alias, :source_kind, options: %{}]

  @type t :: %__MODULE__{
          join_type: :cross | :inner | :left | :right | :full,
          source_sql: iodata(),
          alias: String.t(),
          ordinality_alias: String.t() | nil,
          source_kind: :table_function | :subquery | nil,
          options: map()
        }
end
