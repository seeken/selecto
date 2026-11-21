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
  @moduledoc """
  Finite portable bucket expression presented to an adapter dialect.

  Range kinds label a number derived from the field: `:numeric_ranges` the
  value itself, `:year_ranges` its year, `:elapsed_days_ranges` the days since
  its date, `:month_ranges` the calendar months ago of its month (0 is the
  current month, 1 the month before, so `{3, 5, label}` covers the three
  months from five to three months ago) and `:date_relative_ranges` days
  relative to today. Bounds are inclusive; a value outside every range is
  `Other`.
  """

  @kinds [
    :numeric_ranges,
    :numeric_increment,
    :date_relative_ranges,
    :elapsed_days_ranges,
    :year_increment,
    :year_ranges,
    :month_ranges,
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
