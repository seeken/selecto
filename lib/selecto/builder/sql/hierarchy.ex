defmodule Selecto.Builder.Sql.Hierarchy do
  @moduledoc """
  The adjacency-list hierarchy join (`type: :hierarchical`,
  `hierarchy_type: :adjacency_list`).

  The target relation is joined through a recursive CTE that walks it from its
  roots (rows whose `parent_field` is NULL) down `parent_field -> id_field`,
  at most `depth_limit` levels. The CTE keeps every target column and adds
  `level`, `path` and `path_array`. The association's `where` confines the
  walk (anchor and step), the step stays inside one tenant when the target
  declares `tenant_field`, and the join's ON is the association's own (key
  equality, `conditions`, scope keys, tenant pair, carried tenant).

  The recursive CTE's syntax is the adapter dialect's
  (`render_hierarchy_adjacency/2`); only PostgreSQL renders it, every other
  adapter refuses with `unsupported_feature` before any SQL is sent. The
  portable way to walk a tree is a recursive query member
  (`query_members.ctes` with `kind: :recursive`).
  """

  import Selecto.Builder.Sql.Helpers
  alias Selecto.Dialect.Hierarchy.Adjacency
  alias Selecto.Error
  alias Selecto.SQL.Params

  @doc """
  Build the hierarchy join and its recursive CTE.

  Returns: `{from_clause_iodata, params, ctes}`.
  """
  def build_hierarchy_join_with_cte(selecto, join, config, :adjacency_list, fc, p, ctes) do
    {hierarchy_cte, cte_params} = build_adjacency_list_cte(selecto, join, config)
    cte_name = hierarchy_cte_name(join, config)

    cte_join_iodata = [
      " left join ",
      cte_name,
      " ",
      build_join_string(selecto, join),
      " on ",
      Selecto.Builder.Sql.association_on(selecto, join, config)
    ]

    new_ctes = ctes ++ [{:raw_recursive_cte, hierarchy_cte, cte_params}]
    {fc ++ [cte_join_iodata], p ++ cte_params, new_ctes}
  end

  @doc """
  Build the recursive CTE of an adjacency-list join: `{cte_iodata, params}`.
  """
  def build_adjacency_list_cte(selecto, join, config) do
    quote_column = &selecto_adapter(selecto).quote_identifier(to_string(&1))

    filter =
      case Map.get(config, :hierarchy_where) do
        policy when is_map(policy) and map_size(policy) > 0 ->
          Selecto.Builder.Association.policy_conditions(
            selecto,
            "c",
            policy,
            Selecto.Builder.ExactCompare.relation_for_table(selecto, config.source)
          )

        _ ->
          []
      end

    fragment = %Adjacency{
      cte_name: hierarchy_cte_name(join, config),
      source_table: relation_identifier(selecto, config.source),
      id_field: quote_column.(Map.get(config, :id_field, config.my_key)),
      parent_field: quote_column.(Map.get(config, :parent_field, :parent_id)),
      depth_limit: Map.get(config, :hierarchy_depth, 5),
      filter: filter,
      pair_fields:
        case Map.get(config, :hierarchy_tenant_field) do
          nil -> []
          field -> [quote_column.(field)]
        end
    }

    selecto_adapter(selecto)
    |> Selecto.DialectSupport.render_hierarchy_adjacency(fragment, selecto)
    |> finalize_dialect_fragment(selecto)
  end

  defp finalize_fragment(selecto, fragment) do
    {sql, params} = Params.finalize(fragment, adapter: selecto_adapter(selecto))
    {[sql], params}
  end

  defp selecto_adapter(%{adapter: adapter}) when not is_nil(adapter), do: adapter
  defp selecto_adapter(_selecto), do: Selecto.AdapterSupport.default_adapter()

  defp finalize_dialect_fragment({:ok, {fragment, _params}}, selecto),
    do: finalize_fragment(selecto, fragment)

  defp finalize_dialect_fragment({:ok, fragment}, selecto),
    do: finalize_fragment(selecto, fragment)

  defp finalize_dialect_fragment({:error, %Error{} = error}, _selecto),
    do: Selecto.Builder.ScopeRefusal.unsupported!(error)

  defp finalize_dialect_fragment({:error, reason}, _selecto),
    do: raise(ArgumentError, "unsupported hierarchy operation: #{inspect(reason)}")

  def hierarchy_cte_name(join, config), do: Selecto.Builder.GeneratedName.hierarchy(join, config)
end
