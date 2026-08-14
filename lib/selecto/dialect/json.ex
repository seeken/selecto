defmodule Selecto.Dialect.Json.Extraction do
  @moduledoc "Portable JSON path extraction presented to an adapter dialect."
  @enforce_keys [:column, :path, :as_text]
  defstruct [:column, :path, :as_text, :cast, :table_alias]

  @type t :: %__MODULE__{
          column: String.t(),
          path: [String.t()],
          as_text: boolean(),
          cast: term(),
          table_alias: String.t() | nil
        }
end

defmodule Selecto.Dialect.Json.Contains do
  @moduledoc "Portable JSON containment predicate presented to an adapter dialect."
  @enforce_keys [:column, :value]
  defstruct [:column, :value, :table_alias]
  @type t :: %__MODULE__{column: String.t(), value: term(), table_alias: String.t() | nil}
end

defmodule Selecto.Dialect.Json.KeyExists do
  @moduledoc "Portable JSON key-existence predicate presented to an adapter dialect."
  @enforce_keys [:column, :path]
  defstruct [:column, :path, :table_alias]
  @type t :: %__MODULE__{column: String.t(), path: [String.t()], table_alias: String.t() | nil}
end

defmodule Selecto.Dialect.Json.ArrayContains do
  @moduledoc "Portable JSON-array membership predicate presented to an adapter dialect."
  @enforce_keys [:column, :path, :value]
  defstruct [:column, :path, :value, :table_alias]

  @type t :: %__MODULE__{
          column: String.t(),
          path: [String.t()],
          value: term(),
          table_alias: String.t() | nil
        }
end

defmodule Selecto.Dialect.Json.ArrayContainsAll do
  @moduledoc "Portable all-values JSON-array predicate presented to an adapter dialect."
  @enforce_keys [:column, :path, :values]
  defstruct [:column, :path, :values, :table_alias]

  @type t :: %__MODULE__{
          column: String.t(),
          path: [String.t()],
          values: [term()],
          table_alias: String.t() | nil
        }
end

defmodule Selecto.Dialect.Json.Operation do
  @moduledoc "Finite portable JSON operation presented to an adapter dialect."

  @enforce_keys [:operation, :clause]
  defstruct [
    :operation,
    :clause,
    :column,
    :path,
    :value,
    :key_field,
    :value_field,
    :table_alias,
    options: %{}
  ]

  @type clause :: :select | :filter

  @type operation ::
          :json_extract
          | :json_extract_text
          | :json_extract_path
          | :json_extract_path_text
          | :json_contains
          | :json_contained
          | :json_exists
          | :json_path_exists
          | :json_agg
          | :json_object_agg
          | :json_build_object
          | :json_build_array
          | :json_empty_array
          | :json_set
          | :json_insert
          | :json_remove
          | :json_typeof
          | :json_array_length

  @type t :: %__MODULE__{
          operation: operation(),
          clause: clause(),
          column: String.t() | nil,
          path: String.t() | nil,
          value: term(),
          key_field: String.t() | nil,
          value_field: String.t() | nil,
          table_alias: String.t() | nil,
          options: map()
        }
end
