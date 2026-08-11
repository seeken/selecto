defmodule Selecto.Write.Graph.Node do
  @moduledoc """
  One relation-level unit in a portable write graph.

  `:ordered` preserves row order and generated bindings. `:sync` additionally
  reconciles the owned target set identified by `sync_predicate` and
  `identity_fields`; rows missing from the submitted source are deleted only
  when `delete_missing?` is true.
  """

  alias Selecto.Write.Graph

  @type strategy :: :ordered | :sync

  @type t :: %__MODULE__{
          id: String.t(),
          path: [Graph.Row.path_segment()],
          relation: atom() | String.t(),
          strategy: strategy(),
          rows: [Graph.Row.t()],
          identity_fields: [atom() | String.t()],
          field_types: %{optional(atom() | String.t()) => atom() | String.t()},
          sync_predicate: term() | nil,
          delete_missing?: boolean(),
          metadata: map()
        }

  @enforce_keys [:id, :path, :relation, :strategy, :rows]
  defstruct [
    :id,
    :path,
    :relation,
    :strategy,
    :rows,
    identity_fields: [],
    field_types: %{},
    sync_predicate: nil,
    delete_missing?: false,
    metadata: %{}
  ]
end
