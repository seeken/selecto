defmodule Selecto.Dialect.Hierarchy.Adjacency do
  @moduledoc "Portable adjacency-list hierarchy request presented to an adapter dialect."

  @enforce_keys [:cte_name, :source_table, :id_field, :name_field, :parent_field, :depth_limit]
  defstruct [:cte_name, :source_table, :id_field, :name_field, :parent_field, :depth_limit]

  @type t :: %__MODULE__{
          cte_name: String.t(),
          source_table: String.t(),
          id_field: String.t(),
          name_field: String.t(),
          parent_field: String.t(),
          depth_limit: non_neg_integer()
        }
end

defmodule Selecto.Dialect.Hierarchy.MaterializedPath do
  @moduledoc "Portable materialized-path hierarchy request presented to an adapter dialect."

  @enforce_keys [:query_name, :source_table, :path_field, :path_separator, :path_pattern]
  defstruct [:query_name, :source_table, :path_field, :path_separator, :path_pattern]

  @type t :: %__MODULE__{
          query_name: String.t(),
          source_table: String.t(),
          path_field: String.t(),
          path_separator: String.t(),
          path_pattern: String.t()
        }
end
