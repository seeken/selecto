defmodule Selecto.Dialect.Hierarchy.Adjacency do
  @moduledoc """
  Portable adjacency-list hierarchy request presented to an adapter dialect.

  The dialect renders `<cte_name> AS (...)`: a recursive CTE over
  `source_table` aliased `c` that keeps every column (`c.*`) and adds `level`
  (0 at the roots), `path` (the ids joined by `/`) and `path_array`. The
  anchor reads the roots (`c.<parent_field> IS NULL`), the step joins
  `c.<parent_field> = h.<id_field>` and each `pair_fields` column
  (`c.<f> = h.<f>`) while `h.level < depth_limit`; `filter` (conditions on
  `c`, which may hold `{:param, value}` markers) is ANDed into both. Every
  identifier is already quoted.
  """

  @enforce_keys [:cte_name, :source_table, :id_field, :parent_field, :depth_limit]
  defstruct [
    :cte_name,
    :source_table,
    :id_field,
    :parent_field,
    :depth_limit,
    filter: [],
    pair_fields: []
  ]

  @type t :: %__MODULE__{
          cte_name: String.t(),
          source_table: iodata(),
          id_field: String.t(),
          parent_field: String.t(),
          depth_limit: pos_integer(),
          filter: [iodata()],
          pair_fields: [String.t()]
        }
end
