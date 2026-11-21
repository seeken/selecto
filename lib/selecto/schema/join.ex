defmodule Selecto.Schema.Join do
  # selecto meta join can edit, add, alter this join!

  @moduledoc """
  # Join Configuration

  Turns a domain's `joins` tree into the flat join index the SQL builder
  reads. Every association join renders as one relation joined on the
  association: its key equality, its `conditions`, its scope keys and tenant
  pair, and its `where`, wherever it is joined (nested joins included).

  ## Join types

  The shared types are `:left` (the default), `:inner`, `:right`, `:full`
  and `:star_dimension`. Selecto's native spellings are the shared forms
  under another name (`Selecto.Domain.JoinRules.normalize/1`):

    * `:dimension` - a star dimension whose `dimension` key is its display
      field;
    * `:snowflake_dimension` - a star dimension; its normalized tables are
      nested `joins` (normalization lists were removed);
    * `:self_join` - an ordinary association to the same table;
    * `:full_outer_join` - `type: :full`;
    * `:tagging` - an association join (through a many-to-many bridge or a
      `through` contract) that adds a tag-list column (`<id>_list`) and a
      tag facet filter;
    * `:hierarchical` with `hierarchy_type: :adjacency_list` - PostgreSQL
      only: the target joined through a recursive CTE over its own
      `parent_field` that adds `<id>_level`, `<id>_path` and
      `<id>_path_array`. Other adapters refuse it with `unsupported_feature`;
      the portable way to walk a tree is a recursive query member
      (`query_members.ctes` with `kind: :recursive`).

  `cross_join`, the raw-SQL `lateral_join` join type, `conditional_join`
  (with its `custom_sql` conditions) and the `materialized_path` and
  `closure_table` hierarchies were removed; any other type refuses
  (`invalid_domain`) rather than joining LEFT.

  ## Star dimensions

  ```elixir
  joins: %{customer: %{type: :star_dimension, display_field: :full_name}}
  ```

  A star dimension is a LEFT association join that adds the display column
  `<id>_display` and a facet filter. `dimension_key`, when given, must be the
  association's owner key.
  """

  alias Selecto.Domain.JoinRules

  ### source - a schema name such as SelectoTest.Store.Film
  ### joins - the joins map from this join structure

  # we consume the join tree (atom/list) to a flat map of joins then into a map
  @spec recurse_joins(Selecto.Types.source(), Selecto.Types.domain()) :: %{
          atom() => Selecto.Types.processed_join()
        }
  def recurse_joins(source, domain) do
    joins = Map.get(domain, :joins, %{})
    validate_join_aliases!(joins)

    normalize_joins(source, joins, :selecto_root, domain)
    |> List.flatten()
    |> Selecto.Schema.JoinNamespaces.normalize()
    |> Enum.reduce(%{}, fn j, acc -> Map.put(acc, j.id, j) end)
  end

  # joins.*.alias (Selecto.Domain.JoinRules): an identifier outside
  # Selecto's generated names, unique across the join tree ignoring case.
  defp validate_join_aliases!(joins) do
    case JoinRules.alias_problems(joins) do
      [] ->
        :ok

      [{path, _code, message} | _] ->
        raise ArgumentError,
              "invalid_domain: join #{Enum.map_join(path, ".", &to_string/1)}: #{message}"
    end
  end

  defp invalid!(id, message),
    do: raise(ArgumentError, "invalid_domain: join #{inspect(id)}: #{message}")

  ### source, the schema module name
  ### joins, the joins map from parent,
  ### parent, the 'parent' join

  defp normalize_joins(source, joins, parent, domain) do
    Enum.reduce(joins, [], fn
      # Non-association (custom) joins - explicitly configured without an Ecto association
      {id, %{non_assoc: true} = config}, acc ->
        acc =
          acc ++ [id |> configure_non_assoc(config, parent, source, domain) |> put_alias(config)]

        case Map.get(config, :joins) do
          nil ->
            acc

          nested_joins ->
            # For non-assoc joins, we need to get the target schema from config
            target_schema = get_target_schema_for_non_assoc(config, domain)

            if target_schema do
              acc ++ normalize_nested_joins(target_schema, nested_joins, id, domain)
            else
              acc
            end
        end

      # Association joins
      {id, config}, acc ->
        config =
          case JoinRules.normalize(config) do
            {:ok, config} -> config
            {:error, message} -> invalid!(id, message)
          end

        association =
          case source |> Map.get(:associations, %{}) |> Map.get(id) do
            nil -> invalid!(id, "it is not declared as an association of its parent")
            association -> through_association!(id, association)
          end

        validate_outer_join!(id, association, config)

        case association do
          %{through: through} = assoc when is_map(through) ->
            queryable = target_relation!(id, assoc, domain)
            assoc = Map.put_new(assoc, :field, id)

            boundary =
              association_boundary!(id, assoc, source, queryable, domain)

            join =
              configure(id, assoc, config, parent, source, queryable)
              |> Map.put(:portable_association, Map.merge(assoc, boundary))
              |> put_alias(config)

            acc = acc ++ [join]

            case Map.get(config, :joins) do
              nil -> acc
              nested -> acc ++ normalize_nested_joins(queryable, nested, id, domain)
            end

          # Ecto has_many/has_one :through lists: the intermediate joins
          # are added and the last one is the join's own.
          %{through: through_path} when is_list(through_path) ->
            refuse_alias!(id, config, "a through path")
            refuse_kind!(id, config, "a through path")
            expand_through_joins(id, through_path, config, parent, source, domain, acc)

          # Direct association
          _ ->
            queryable = target_relation!(id, association, domain)

            join =
              configure(id, association, config, parent, source, queryable)
              |> attach_association_scope!(
                id,
                association,
                source,
                queryable,
                domain
              )
              |> attach_association_policy(association)
              |> put_alias(config)

            acc = acc ++ [join]

            case Map.get(config, :joins) do
              nil -> acc
              nested_joins -> acc ++ normalize_nested_joins(queryable, nested_joins, id, domain)
            end
        end
    end)
  end

  defp target_relation!(id, association, domain) do
    case Map.get(domain.schemas, association.queryable) do
      nil ->
        invalid!(
          id,
          "its association targets undeclared schema #{inspect(association.queryable)}"
        )

      queryable ->
        queryable
    end
  end

  @doc false
  # A many-to-many `join_through` association is a `through` contract: its
  # join table is the bridge, joined on the association's join_keys
  # (`[{bridge_owner_fk, owner_key}, {bridge_related_fk, related_key}]`). The
  # bridge is scoped as every `through` bridge is: `source_scope_key`,
  # `through_scope_key` and `target_scope_key` (all three or none) pair the
  # bridge and the target with the owner, and `through_where` confines the
  # bridge. The association's `where` confines the target.
  def through_association!(association_id, %{join_through: table} = association) do
    table =
      cond do
        is_binary(table) -> table
        is_atom(table) and function_exported?(table, :__schema__, 1) -> table.__schema__(:source)
        true -> nil
      end

    case Map.get(association, :join_keys) do
      [{owner_fk, owner_key}, {related_fk, related_key} | _] when is_binary(table) ->
        through =
          association
          |> Map.take([:source_scope_key, :through_scope_key, :target_scope_key, :through_where])
          |> Enum.reduce(
            %{table: table, owner_key: owner_fk, related_key: related_fk},
            fn
              {:through_where, where}, acc -> Map.put(acc, :where, where)
              {key, value}, acc -> Map.put(acc, key, value)
            end
          )

        association
        |> Map.drop([
          :join_through,
          :join_keys,
          :source_scope_key,
          :through_scope_key,
          :target_scope_key,
          :through_where
        ])
        |> Map.merge(%{owner_key: owner_key, related_key: related_key, through: through})

      _ ->
        raise ArgumentError,
              "invalid_domain: many-to-many association #{inspect(association_id)} needs a " <>
                "join table and join_keys [{bridge_owner_key, owner_key}, " <>
                "{bridge_related_key, related_key}]"
    end
  end

  def through_association!(_association_id, association), do: association

  # RIGHT and FULL joins keep the target's unmatched rows; only a direct
  # association can give them (Selecto.Domain.JoinRules).
  defp validate_outer_join!(id, association, config) do
    case JoinRules.outer_join_problem(association, config) do
      nil -> :ok
      message -> invalid!(id, message)
    end
  end

  defp put_alias(join, config) do
    case JoinRules.authored_alias(config) do
      nil -> join
      alias_name -> Map.put(join, :authored_alias, alias_name)
    end
  end

  defp refuse_alias!(id, config, kind) do
    if JoinRules.authored_alias(config) do
      raise ArgumentError,
            "invalid_domain: join #{inspect(id)} through #{kind} cannot take an alias"
    end

    :ok
  end

  # A star dimension, tagging or hierarchy join reads one association; an
  # Ecto through list expands into several joins, so it takes none of them.
  defp refuse_kind!(id, config, kind) do
    if Map.get(config, :type) in [:star_dimension, :tagging, :hierarchical] do
      invalid!(id, "a #{Map.get(config, :type)} join cannot read #{kind}")
    end

    :ok
  end

  defp normalize_nested_joins(source, joins, parent, domain) do
    source
    |> normalize_joins(joins, parent, domain)
    |> Enum.map(fn join ->
      Map.update(join, :join_path, [parent, join.id], &[parent | &1])
    end)
  end

  # Get target schema for non-assoc joins from config
  defp get_target_schema_for_non_assoc(config, domain) do
    case config do
      %{target_schema: schema_key} ->
        domain.schemas[schema_key]

      %{source: source_table} ->
        # Try to find schema by source table name
        Enum.find_value(domain.schemas, fn {_key, schema} ->
          if schema.source_table == source_table, do: schema, else: nil
        end)

      _ ->
        nil
    end
  end

  # Expand an Ecto has_many/has_one :through list into its joins: each
  # segment is an association of the relation before it, joined (and bounded)
  # as a direct association; the last carries the join's own id and config.
  # A segment that is not an association refuses the domain.
  defp expand_through_joins(id, through_path, config, parent, source, domain, acc) do
    case through_path do
      [final_assoc] ->
        final = through_segment!(id, source, final_assoc)
        final_queryable = target_relation!(id, final, domain)

        final_join =
          configure(id, final, config, parent, source, final_queryable)
          |> attach_association_scope!(id, final, source, final_queryable, domain)
          |> attach_association_policy(final)
          |> Map.put(:is_through, true)

        acc = acc ++ [final_join]

        case Map.get(config, :joins) do
          nil -> acc
          nested_joins -> acc ++ normalize_nested_joins(final_queryable, nested_joins, id, domain)
        end

      [intermediate_assoc | rest] when rest != [] ->
        intermediate = through_segment!(id, source, intermediate_assoc)
        intermediate_queryable = target_relation!(id, intermediate, domain)

        intermediate_join =
          configure(
            intermediate_assoc,
            intermediate,
            # Implicitly added for the through path
            %{implicit: true},
            parent,
            source,
            intermediate_queryable
          )
          |> attach_association_scope!(
            intermediate_assoc,
            intermediate,
            source,
            intermediate_queryable,
            domain
          )
          |> attach_association_policy(intermediate)

        expand_through_joins(
          id,
          rest,
          config,
          intermediate_assoc,
          intermediate_queryable,
          domain,
          acc ++ [intermediate_join]
        )

      _ ->
        invalid!(id, "its through path #{inspect(through_path)} names no association")
    end
  end

  defp through_segment!(id, source, segment) do
    case source |> Map.get(:associations, %{}) |> Map.get(segment) do
      %{} = association ->
        case through_association!(segment, association) do
          %{through: through} when is_list(through) ->
            invalid!(id, "through segment #{inspect(segment)} is itself a through path")

          association ->
            association
        end

      nil ->
        invalid!(
          id,
          "through segment #{inspect(segment)} is not an association of " <>
            "#{inspect(Map.get(source, :source_table))}"
        )
    end
  end

  # Configure non-association (custom) joins
  defp configure_non_assoc(id, config, parent, _from_source, _domain) do
    name = Map.get(config, :name, id)
    source_table = Map.get(config, :source, to_string(id))
    owner_key = Map.get(config, :owner_key, :id)
    related_key = Map.get(config, :related_key, :id)

    type =
      case JoinRules.custom_type(config) do
        {:ok, type} -> type
        {:error, message} -> invalid!(id, message)
      end

    %{
      config: config,
      # No Ecto source for custom joins
      from_source: nil,
      owner_key: owner_key,
      my_key: related_key,
      source: source_table,
      id: id,
      name: name,
      requires_join: parent,
      join_type: :custom,
      is_custom: true,
      type: type,
      on: Map.get(config, :on, []),
      param_filters: Map.get(config, :param_filters, %{}),
      filters: Map.get(config, :filters, %{}),
      fields: Map.get(config, :fields, %{})
    }
  end

  ### id, the id of this join in the joins map on parent
  ### association, the struct form ecto.schema that has instructions on how to join
  ### config, the map that contains config details for this join
  ### parent - atom that references the parent
  ### from_source - the association from the parent or the domain if parent is root

  ### Tagging: an association join plus a tag list column and a tag facet.
  defp configure(id, association, %{type: :tagging} = config, parent, from_source, queryable) do
    name = Map.get(config, :name, id)
    tag_field = Map.get(config, :tag_field, :name)

    unless declares_field?(queryable, tag_field) do
      invalid!(id, "tag_field #{inspect(tag_field)} is not a field of the tag relation")
    end

    config =
      config
      |> Map.put(
        :custom_columns,
        Map.get(config, :custom_columns, %{})
        |> Map.put(
          "#{id}_list",
          %{
            name: "#{name} List",
            select: {:string_agg, "#{association.field}.#{tag_field}", ", "},
            group_by_format: fn {a, _id}, _def -> a end,
            # Aggregate fields typically aren't filterable
            filterable: false
          }
        )
      )
      |> Map.put(
        :custom_filters,
        Map.get(config, :custom_filters, %{})
        |> Map.put(
          "#{id}_filter",
          %{
            name: "#{name}",
            filter_type: :multi_select,
            facet: true,
            source_table: queryable.source_table,
            source_field: tag_field
          }
        )
      )

    id
    |> std_config(association, config, parent, from_source, queryable)
    |> Map.merge(%{join_type: :tagging, tag_field: tag_field})
  end

  ### Hierarchical self-join (adjacency list pattern)
  defp configure(id, association, %{type: :hierarchical} = config, parent, from_source, queryable) do
    configure_adjacency_list(id, association, config, parent, from_source, queryable)
  end

  ### Star schema dimension: a LEFT association join plus a display column.
  defp configure(
         id,
         association,
         %{type: :star_dimension} = config,
         parent,
         from_source,
         queryable
       ) do
    name = Map.get(config, :name, id)
    display_field = Map.get(config, :display_field, :name)

    unless declares_field?(queryable, display_field) do
      invalid!(id, "star dimension display field #{inspect(display_field)} is not queryable")
    end

    case Map.get(config, :dimension_key) do
      nil ->
        :ok

      key ->
        unless to_string(key) == to_string(association.owner_key),
          do: invalid!(id, "star dimension key must match the association owner key")
    end

    config =
      config
      |> Map.put(
        :custom_columns,
        Map.get(config, :custom_columns, %{})
        |> Map.put(
          "#{id}_display",
          %{
            name: "#{name}",
            select:
              if(Map.get(config, :display_fallback) in [:dimension_key, "dimension_key"],
                do:
                  {:coalesce,
                   [
                     "#{association.field}.#{display_field}",
                     if(parent == :selecto_root,
                       do: to_string(association.owner_key),
                       else: "#{parent}.#{association.owner_key}"
                     )
                   ]},
                else: "#{association.field}.#{display_field}"
              ),
            group_by_format: fn {a, _id}, _def -> a end,
            filterable: true,
            # Mark as dimension for special handling
            is_dimension: true
          }
        )
      )
      |> Map.put(
        :custom_filters,
        Map.get(config, :custom_filters, %{})
        |> Map.put(
          "#{id}_facet",
          %{
            name: "#{name} Filter",
            filter_type: :select_facet,
            facet: true,
            source_table: queryable.source_table,
            source_field: display_field,
            is_dimension: true
          }
        )
      )

    id
    |> std_config(association, config, parent, from_source, queryable)
    |> Map.merge(%{
      join_type: :star_dimension,
      type: :left,
      display_field: display_field,
      display_fallback: Map.get(config, :display_fallback)
    })
  end

  ### Regular (catch-all clause)
  defp configure(id, association, config, parent, from_source, queryable) do
    std_config(id, association, config, parent, from_source, queryable)
  end

  # An adjacency list: the target relation joined through a recursive CTE
  # that walks it from its roots (rows whose parent_field is NULL) down
  # parent_field -> id_field, at most depth_limit levels (1..10000, default
  # 5). The CTE keeps every target column and adds level, path and
  # path_array; the association's `where` confines the walk (anchor and
  # step), the walk stays inside one tenant when the target declares
  # tenant_field, and the join's ON is the association's own (key equality,
  # conditions, scope keys, tenant pair). PostgreSQL only.
  defp configure_adjacency_list(id, association, config, parent, from_source, queryable) do
    name = Map.get(config, :name, id)
    join_alias = to_string(id)

    if Map.has_key?(association, :through) or Map.has_key?(association, :values) or
         Map.has_key?(association, :join_strategy),
       do: invalid!(id, "a hierarchical join reads a direct table association")

    id_field = Map.get(config, :id_field, association.related_key)
    parent_field = Map.get(config, :parent_field, :parent_id)
    depth_limit = Map.get(config, :depth_limit, 5)

    for {key, field} <- [id_field: id_field, parent_field: parent_field] do
      unless declares_field?(queryable, field),
        do:
          invalid!(id, "hierarchy #{key} #{inspect(field)} is not a field of the target relation")
    end

    unless is_integer(depth_limit) and depth_limit in 1..10_000,
      do: invalid!(id, "hierarchy depth_limit must be an integer from 1 to 10000")

    if Enum.any?(queryable.fields, &(to_string(&1) in ["level", "path", "path_array"])),
      do: invalid!(id, "a hierarchy target cannot declare fields named level, path or path_array")

    config =
      Map.put(
        config,
        :custom_columns,
        Map.get(config, :custom_columns, %{})
        |> Map.put(
          "#{id}_path",
          %{
            name: "#{name} Path",
            select: "#{join_alias}.path",
            group_by_format: fn {a, _id}, _def -> a end,
            filterable: false
          }
        )
        |> Map.put(
          "#{id}_level",
          %{
            name: "#{name} Level",
            select: "#{join_alias}.level",
            group_by_format: fn {a, _id}, _def -> a end,
            filterable: true
          }
        )
        |> Map.put(
          "#{id}_path_array",
          %{
            name: "#{name} Path Array",
            select: "#{join_alias}.path_array",
            group_by_format: fn {a, _id}, _def -> a end,
            filterable: false
          }
        )
      )

    id
    |> std_config(association, config, parent, from_source, queryable)
    |> Map.merge(%{
      source_schema: Map.get(queryable, :source_schema),
      join_type: :hierarchical_adjacency,
      type: :left,
      hierarchy_depth: depth_limit,
      id_field: id_field,
      parent_field: parent_field,
      hierarchy_where: Map.get(association, :where),
      hierarchy_tenant_field: Map.get(queryable, :tenant_field)
    })
  end

  defp std_config(id, association, config, parent, from_source, queryable) do
    %{
      config: config,
      from_source: from_source,
      owner_key: association.owner_key,
      my_key: association.related_key,
      source: queryable.source_table,
      id: id,
      name: Map.get(config, :name, id),
      # The join's authored type (normalized by JoinRules.normalize/1):
      # inner, right and full render as such; everything else joins LEFT.
      type: if(Map.get(config, :type) in [:inner, :right, :full], do: config.type, else: :left),
      requires_join: parent,
      filters: make_filters(config),
      fields:
        Selecto.Schema.Column.configure_columns(
          association.field,
          queryable.fields -- queryable.redact_fields,
          queryable,
          config
        )
    }
    |> put_conditions(association)
  end

  # Association `conditions` (validated by the domain contract) travel with
  # the join; the builder ANDs them after the key equality.
  defp put_conditions(join, association) do
    case map_value(association, :conditions) do
      conditions when is_list(conditions) and conditions != [] ->
        Map.put(join, :conditions, Selecto.Domain.JoinConditions.normalize(conditions))

      _ ->
        join
    end
  end

  defp attach_association_scope!(join, association_id, association, source, target, domain) do
    Map.merge(join, association_boundary!(association_id, association, source, target, domain))
  end

  @doc false
  # The relation boundary of one association edge, shared by flat joins,
  # through bridges and correlated subselects:
  #
  #   * its scope keys (authored, or inferred from the tenant pair when none
  #     are authored);
  #   * `:tenant_scope`, the tenant pair, whenever both relations declare
  #     tenant_field. Authored scope keys never replace it (lesson 41);
  #   * `:carry_tenant_field`, the target's tenant field, when the target
  #     declares tenant_field but the source does not. A scoped query carries
  #     its root's admitted tenants onto it across the shared hop (lesson 41b).
  #
  # `domain` gives the domain's tenant columns: in a two-column domain every
  # hop pairs tenant columns by name, never by position (lessons 41a, 41b).
  @spec association_boundary!(term(), map(), map(), map(), map() | nil) :: map()
  def association_boundary!(association_id, association, source, target, domain \\ nil) do
    tenant_pair = tenant_pair(association_id, source, target, domain)
    validate_through_scope!(association_id, association, source, target)

    scope =
      case association_scope_keys!(association_id, association, source, target, tenant_pair) do
        {nil, nil} -> %{}
        {source_key, target_key} -> %{source_scope_key: source_key, target_scope_key: target_key}
      end

    case {tenant_pair, map_value(source, :tenant_field), map_value(target, :tenant_field)} do
      {nil, nil, target_tenant} when not is_nil(target_tenant) ->
        validate_tenant_field!(association_id, :target, target, target_tenant)
        Map.put(scope, :carry_tenant_field, target_tenant)

      {nil, _source_tenant, _target_tenant} ->
        scope

      {{source_tenant, target_tenant} = pair, _source_tenant, _target_tenant} ->
        validate_tenant_field!(association_id, :source, source, source_tenant)
        validate_tenant_field!(association_id, :target, target, target_tenant)

        if same_key?(source_tenant, scope[:source_scope_key]) and
             same_key?(target_tenant, scope[:target_scope_key]),
           do: scope,
           else: Map.put(scope, :tenant_scope, pair)
    end
  end

  # `{source_tenant_column, target_tenant_field}` when both relations declare
  # tenant_field, otherwise nil. In a one-column domain the source's
  # tenant_field pairs with the target's, whatever their names. In a two-column
  # domain (its write scope tenant field differs from its tenant_field) every
  # hop pairs by name: the target's tenant_field must be the source's
  # tenant_field, or one of the domain's tenant columns that the source also
  # declares. Anything else is refused.
  defp tenant_pair(association_id, source, target, domain) do
    case {map_value(source, :tenant_field), map_value(target, :tenant_field)} do
      {source_tenant, target_tenant}
      when not is_nil(source_tenant) and not is_nil(target_tenant) ->
        columns = if is_map(domain), do: Selecto.Tenant.domain_tenant_columns(domain), else: []

        cond do
          length(columns) < 2 or same_key?(source_tenant, target_tenant) ->
            {source_tenant, target_tenant}

          Enum.any?(columns, &same_key?(&1, target_tenant)) and
              declares_field?(source, target_tenant) ->
            {target_tenant, target_tenant}

          true ->
            raise ArgumentError,
                  "invalid_domain: association #{inspect(association_id)} target tenant field " <>
                    "#{inspect(target_tenant)} cannot be paired by name with the tenant columns " <>
                    "#{inspect(columns)}, so the tenant pair cannot be made"
        end

      _ ->
        nil
    end
  end

  defp declares_field?(relation, field),
    do: Enum.any?(map_value(relation, :fields) || [], &same_key?(&1, field))

  defp same_key?(left, right),
    do: not is_nil(left) and not is_nil(right) and to_string(left) == to_string(right)

  defp validate_tenant_field!(association_id, side, relation, tenant_field) do
    fields = map_value(relation, :fields) || []

    unless Enum.any?(fields, &(to_string(&1) == to_string(tenant_field))) do
      raise ArgumentError,
            "invalid_domain: association #{inspect(association_id)} #{side} tenant field " <>
              "#{inspect(tenant_field)} is not declared, so the tenant pair cannot be made"
    end
  end

  defp association_scope_keys!(association_id, association, source, target, tenant_pair) do
    {source_scope_key, target_scope_key} = association_scope_keys(association, tenant_pair)

    case {source_scope_key, target_scope_key} do
      {nil, nil} ->
        {nil, nil}

      {nil, _target_scope_key} ->
        raise ArgumentError,
              "association #{inspect(association_id)} scope requires both :source_scope_key and :target_scope_key"

      {_source_scope_key, nil} ->
        raise ArgumentError,
              "association #{inspect(association_id)} scope requires both :source_scope_key and :target_scope_key"

      {source_scope_key, target_scope_key} ->
        validate_scope_field!(association_id, :source, source, source_scope_key)
        validate_scope_field!(association_id, :target, target, target_scope_key)

        {source_scope_key, target_scope_key}
    end
  end

  defp association_scope_keys(association, tenant_pair) do
    case {map_value(association, :source_scope_key), map_value(association, :target_scope_key)} do
      {nil, nil} -> tenant_pair || {nil, nil}
      authored_keys -> authored_keys
    end
  end

  defp attach_association_policy(join, association) do
    case map_value(association, :where) do
      policy when is_map(policy) and map_size(policy) > 0 ->
        # Carry the boundary resolved by attach_association_scope! (scope keys
        # and tenant pair) so the portable predicate keeps it.
        boundary =
          Map.take(join, [
            :source_scope_key,
            :target_scope_key,
            :tenant_scope,
            :carry_tenant_field
          ])

        Map.put(join, :portable_association, Map.merge(association, boundary))

      _ ->
        join
    end
  end

  # A through association's source and target scope keys must be declared
  # fields of their relations: a target scope key the target does not expose
  # cannot be correlated (a retarget would silently identify the target by
  # its key alone and read rows of other scopes).
  defp validate_through_scope!(association_id, association, source, target) do
    case map_value(association, :through) do
      through when is_map(through) ->
        source_key = map_value(through, :source_scope_key)
        target_key = map_value(through, :target_scope_key)

        if source_key, do: validate_scope_field!(association_id, :source, source, source_key)
        if target_key, do: validate_scope_field!(association_id, :target, target, target_key)
        :ok

      _ ->
        :ok
    end
  end

  defp validate_scope_field!(association_id, side, relation, scope_key) do
    fields = map_value(relation, :fields) || []

    unless Enum.any?(fields, &(to_string(&1) == to_string(scope_key))) do
      raise ArgumentError,
            "association #{inspect(association_id)} #{side} scope field #{inspect(scope_key)} is not declared"
    end
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp map_value(_map, _key), do: nil

  defp make_filters(config) do
    Map.get(config, :filters, %{})
  end
end
