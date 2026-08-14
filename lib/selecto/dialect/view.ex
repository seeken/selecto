defmodule Selecto.Dialect.View.Definition do
  @moduledoc "Portable view-definition request presented to an adapter dialect."
  @enforce_keys [:kind, :database_name, :query_sql]
  defstruct [:kind, :database_name, :query_sql]

  @type t :: %__MODULE__{
          kind: :view | :materialized_view,
          database_name: String.t(),
          query_sql: String.t()
        }
end

defmodule Selecto.Dialect.View.Refresh do
  @moduledoc "Portable materialized-view refresh request presented to an adapter dialect."
  @enforce_keys [:database_name]
  defstruct [:database_name, concurrently: false]

  @type t :: %__MODULE__{database_name: String.t(), concurrently: boolean()}
end

defmodule Selecto.Dialect.View.Index do
  @moduledoc "Portable view-index request presented to an adapter dialect."
  @enforce_keys [:database_name, :index_name, :columns]
  defstruct [:database_name, :index_name, :columns, unique: false, concurrently: false]

  @type t :: %__MODULE__{
          database_name: String.t(),
          index_name: String.t(),
          columns: [String.t()],
          unique: boolean(),
          concurrently: boolean()
        }
end
