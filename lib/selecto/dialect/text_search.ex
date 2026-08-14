defmodule Selecto.Dialect.TextSearch.Predicate do
  @moduledoc """
  Portable text-search predicate presented to an adapter dialect.

  `selectors` are already validated and qualified by core. `fields` retain
  normalized domain metadata so a dialect can require an indexed/native search
  document without teaching core its database-specific type name.
  """

  @enforce_keys [:fields, :selectors, :query, :mode]
  defstruct [:fields, :selectors, :query, :mode]

  @type field :: %{required(:name) => String.t(), required(:config) => map()}
  @type t :: %__MODULE__{
          fields: [field()],
          selectors: [iodata()],
          query: term(),
          mode: atom() | nil
        }
end

defmodule Selecto.Dialect.TextSearch.Rank do
  @moduledoc "Portable text-search ranking intent presented to an adapter dialect."

  @enforce_keys [:fields, :alias, :mode, :weights]
  defstruct [:fields, :query, :alias, :mode, :weights]

  @type t :: %__MODULE__{
          fields: [String.t()],
          query: term(),
          alias: String.t(),
          mode: atom() | nil,
          weights: [number()]
        }
end
