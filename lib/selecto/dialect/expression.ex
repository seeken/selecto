defmodule Selecto.Dialect.Text.Normalization do
  @moduledoc "Portable text normalization presented to an adapter dialect."

  @enforce_keys [:expression]
  defstruct [:expression, exclude_articles: [], ignore_case: true]

  @type t :: %__MODULE__{
          expression: iodata(),
          exclude_articles: [String.t()],
          ignore_case: boolean()
        }
end

defmodule Selecto.Dialect.Predicate.Comparison do
  @moduledoc "Portable comparison whose SQL operator or implementation varies by dialect."

  @operations [:case_insensitive_like, :case_insensitive_not_like]

  @enforce_keys [:operation, :left, :right]
  defstruct [:operation, :left, :right]

  @type t :: %__MODULE__{
          operation: :case_insensitive_like | :case_insensitive_not_like,
          left: iodata(),
          right: iodata()
        }

  @spec operations() :: [atom()]
  def operations, do: @operations
end

defmodule Selecto.Dialect.Bucket.Expression do
  @moduledoc "Finite portable bucket expression presented to an adapter dialect."

  @kinds [
    :numeric_ranges,
    :numeric_increment,
    :date_relative_ranges,
    :elapsed_days_ranges,
    :year_increment,
    :year_ranges,
    :text_prefix
  ]

  @enforce_keys [:kind, :expression]
  defstruct [
    :kind,
    :expression,
    :increment,
    ranges: [],
    prefix_length: 2,
    exclude_articles: [],
    ignore_case: true,
    temporal_options: %{}
  ]

  @type range_boundary :: integer() | :infinity | :negative_infinity | String.t()
  @type range :: {range_boundary(), range_boundary(), String.t()}

  @type t :: %__MODULE__{
          kind: atom(),
          expression: iodata(),
          increment: pos_integer() | nil,
          ranges: [range()],
          prefix_length: pos_integer(),
          exclude_articles: [String.t()],
          ignore_case: boolean(),
          temporal_options: map()
        }

  @spec kinds() :: [atom()]
  def kinds, do: @kinds
end
