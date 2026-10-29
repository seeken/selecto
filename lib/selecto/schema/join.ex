defmodule Selecto.Schema.Join do
  # selecto meta join can edit, add, alter this join!

  # import Selecto.Types - removed to avoid circular dependency

  @moduledoc """
  # Join Configuration and Patterns

  This module handles join configuration for various database join patterns,
  providing simplified configuration helpers for common scenarios.

  ## Available Join Types

  ### :dimension (Existing)
  Basic dimension table join with ID filtering and name display.
  - `dimension`: Field to use for display (required)
  - `name`: Display name for the join (optional)

  ### :tagging (New)
  Many-to-many relationship through a join table (e.g., posts <-> tags).
  - `tag_field`: Field to display from tag table (default: :name)
  - `name`: Display name for the join (optional)
  Creates custom columns for tag aggregation and faceted filtering.

  ### :hierarchical (New)
  Self-referencing hierarchical relationships with multiple implementation patterns:
  - `hierarchy_type`: :adjacency_list, :materialized_path, or :closure_table
  - `depth_limit`: Maximum recursion depth for adjacency lists (default: 5)
  - `path_field`: Field containing path for materialized path pattern (default: :path)
  - `path_separator`: Separator used in path field (default: "/")
  - `closure_table`: Name of closure table for closure table pattern
  - `ancestor_field`, `descendant_field`, `depth_field`: Closure table field names

  ### :star_dimension (New)
  Optimized for OLAP star schema dimensions.
  - `display_field`: Field to use for dimension display (default: :name)
  - `name`: Display name for the dimension (optional)
  Creates faceted filters optimized for aggregation queries.

  ### :snowflake_dimension (New)
  Normalized dimension tables requiring additional joins.
  - `display_field`: Field to use for dimension display (default: :name)
  - `normalization_joins`: List of additional joins needed for full context
  - `name`: Display name for the dimension (optional)

  ## Standard Join Types (Default behavior)
  - one_to_one - Standard lookup with all columns available
  - one_to_many - Treated like one-to-one
  - belongs_to - Treated like one-to-one

  ## Configuration Examples

  ```elixir
  joins: %{
    # Many-to-many tagging
    tags: %{type: :tagging, tag_field: :name},

    # Hierarchical adjacency list
    manager: %{type: :hierarchical, hierarchy_type: :adjacency_list, depth_limit: 5},

    # Star schema dimension
    customer: %{type: :star_dimension, display_field: :full_name},

    # Snowflake dimension with normalization
    category: %{
      type: :snowflake_dimension,
      display_field: :name,
      normalization_joins: [%{table: "category_groups", alias: "cg"}]
    }
  }
  ```
  """

  ### source - a schema name such as SelectoTest.Store.Film
  ### joins - the joins map from this join structure

  # we consume the join tree (atom/list) to a flat map of joins then into a map
  @spec recurse_joins(Selecto.Types.source(), Selecto.Types.domain()) :: %{
          atom() => Selecto.Types.processed_join()
        }
  def recurse_joins(source, domain) do
    joins = Map.get(domain, :joins, %{})

    normalize_joins(source, joins, :selecto_root, domain)
    |> List.flatten()
    |> Selecto.Schema.JoinNamespaces.normalize()
    |> Enum.reduce(%{}, fn j, acc -> Map.put(acc, j.id, j) end)
  end

  ### source, the schema module name
  ### joins, the joins map from parent,
  ### parent, the 'parent' join

  defp normalize_joins(source, joins, parent, domain) do
    Enum.reduce(joins, [], fn
      # Non-association (custom) joins - explicitly configured without an Ecto association
      {id, %{non_assoc: true} = config}, acc ->
        acc = acc ++ [configure_non_assoc(id, config, parent, source, domain)]

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

      # Standard association-based joins
      {id, config}, acc ->
        association = source.associations[id]

        case association do
          %{through: through} = assoc when is_map(through) ->
            queryable = domain.schemas[assoc.queryable]
            assoc = Map.put_new(assoc, :field, id)

            boundary =
              association_boundary!(id, assoc, source, queryable, domain)

            join =
              configure(id, assoc, config, parent, source, queryable)
              |> Map.put(:portable_association, Map.merge(assoc, boundary))

            acc = acc ++ [join]

            case Map.get(config, :joins) do
              nil -> acc
              nested -> acc ++ normalize_nested_joins(queryable, nested, id, domain)
            end

          # Handle through associations by expanding the intermediate joins
          %{through: through_path} ->
            expand_through_joins(id, through_path, config, parent, source, domain, acc)

          # Handle many-to-many associations (join_through table)
          %{join_through: _join_through} = assoc ->
            queryable = domain.schemas[assoc.queryable]

            acc =
              acc ++
                [configure_many_to_many(id, assoc, config, parent, source, queryable, domain)]

            case Map.get(config, :joins) do
              nil -> acc
              nested_joins -> acc ++ normalize_nested_joins(queryable, nested_joins, id, domain)
            end

          # Standard association
          _ ->
            queryable = domain.schemas[association.queryable]

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

            acc = acc ++ [join]

            case Map.get(config, :joins) do
              nil -> acc
              nested_joins -> acc ++ normalize_nested_joins(queryable, nested_joins, id, domain)
            end
        end
    end)
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

  # Expand has_many :through associations into intermediate joins
  defp expand_through_joins(id, through_path, config, parent, source, domain, acc) do
    # through_path is a list like [:posts, :tags] meaning:
    # source -> posts -> tags
    # We need to ensure intermediate joins exist and configure the final join

    case through_path do
      [intermediate_assoc, final_assoc] ->
        # Get the intermediate association
        intermediate = source.associations[intermediate_assoc]

        if intermediate do
          intermediate_queryable = domain.schemas[intermediate.queryable]

          # Check if intermediate join is already being added
          # If not, we need to add it implicitly
          intermediate_join =
            configure(
              intermediate_assoc,
              intermediate,
              # Mark as implicitly added for through
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

          # Now get the final association from the intermediate schema
          # We need to look it up from the actual intermediate queryable associations
          final_assoc_data = intermediate_queryable.associations[final_assoc]

          if final_assoc_data do
            final_queryable = domain.schemas[final_assoc_data.queryable]

            # Configure the final join with reference to intermediate
            final_join =
              configure(
                # Use the original through association name
                id,
                final_assoc_data,
                config,
                # Parent is the intermediate join
                intermediate_assoc,
                intermediate_queryable,
                final_queryable
              )
              |> attach_association_scope!(
                id,
                final_assoc_data,
                intermediate_queryable,
                final_queryable,
                domain
              )

            # Mark the final join as a through join for special handling
            final_join = Map.put(final_join, :is_through, true)
            final_join = Map.put(final_join, :through_path, through_path)

            # Add both joins
            acc = acc ++ [intermediate_join, final_join]

            # Handle nested joins if any
            case Map.get(config, :joins) do
              nil ->
                acc

              nested_joins ->
                acc ++ normalize_nested_joins(final_queryable, nested_joins, id, domain)
            end
          else
            # Final association not found, skip
            acc
          end
        else
          # Intermediate association not found, skip
          acc
        end

      # Longer through paths (rare but possible)
      [first_assoc | rest] when length(rest) >= 2 ->
        # Recursively expand
        first = source.associations[first_assoc]

        if first do
          first_queryable = domain.schemas[first.queryable]

          first_join =
            configure(first_assoc, first, %{implicit: true}, parent, source, first_queryable)
            |> attach_association_scope!(
              first_assoc,
              first,
              source,
              first_queryable,
              domain
            )

          # Recursively expand the remaining path
          acc = acc ++ [first_join]
          expand_through_joins(id, rest, config, first_assoc, first_queryable, domain, acc)
        else
          acc
        end

      _ ->
        # Invalid through path, skip
        acc
    end
  end

  # Configure non-association (custom) joins
  defp configure_non_assoc(id, config, parent, _from_source, _domain) do
    name = Map.get(config, :name, id)
    source_table = Map.get(config, :source, to_string(id))
    owner_key = Map.get(config, :owner_key, :id)
    related_key = Map.get(config, :related_key, :id)

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
      type: Map.get(config, :type, :left),
      on: Map.get(config, :on, []),
      param_filters: Map.get(config, :param_filters, %{}),
      filters: Map.get(config, :filters, %{}),
      fields: Map.get(config, :fields, %{})
    }
  end

  # Configure many-to-many joins (with join_through table)
  defp configure_many_to_many(id, association, config, parent, from_source, queryable, domain) do
    name = Map.get(config, :name, id)
    join_through = association.join_through

    # For many-to-many, we need to track the join table
    join_through_table =
      case join_through do
        table when is_binary(table) ->
          table

        module when is_atom(module) ->
          if function_exported?(module, :__schema__, 1) do
            module.__schema__(:source)
          else
            to_string(module) |> String.split(".") |> List.last() |> Macro.underscore()
          end

        _ ->
          "#{id}_join"
      end

    join_keys = Map.get(association, :join_keys, [])

    {derived_main_foreign_key, derived_tag_foreign_key} =
      case join_keys do
        [{main_fk, _owner_key}, {tag_fk, _related_key} | _] ->
          {to_string(main_fk), to_string(tag_fk)}

        _ ->
          {
            foreign_key_from_table(Map.get(from_source, :source_table, to_string(id))),
            foreign_key_from_table(Map.get(queryable, :source_table, to_string(id)))
          }
      end

    final_join_table =
      case Map.get(config, :join_table) do
        nil -> join_through_table
        value when is_atom(value) -> Atom.to_string(value)
        value -> value
      end

    final_main_foreign_key =
      config
      |> Map.get(:main_foreign_key, derived_main_foreign_key)
      |> to_string()

    final_tag_foreign_key =
      config
      |> Map.get(:tag_foreign_key, derived_tag_foreign_key)
      |> to_string()

    %{
      config: config,
      from_source: from_source,
      owner_key: association.owner_key,
      my_key: association.related_key,
      source: queryable.source_table,
      id: id,
      name: name,
      requires_join: parent,
      join_type: :many_to_many,
      join_table: final_join_table,
      main_foreign_key: final_main_foreign_key,
      tag_foreign_key: final_tag_foreign_key,
      join_through: join_through_table,
      join_keys: join_keys,
      filters: Map.get(config, :filters, %{}),
      fields:
        Selecto.Schema.Column.configure_columns(
          association.field,
          queryable.fields -- Map.get(queryable, :redact_fields, []),
          queryable,
          config
        )
    }
    |> parameterize()
    |> attach_association_scope!(id, association, from_source, queryable, domain)
  end

  defp foreign_key_from_table(table) when is_atom(table),
    do: table |> Atom.to_string() |> foreign_key_from_table()

  defp foreign_key_from_table(table) when is_binary(table) do
    table
    |> String.split(".")
    |> List.last()
    |> String.trim_trailing("s")
    |> Kernel.<>("_id")
  end

  ### id, the id of this join in the joins map on parent
  ### association, the struct form ecto.schema that has instructions on how to join
  ### config, the map that contains config details for this join
  ### parent - atom that references the parent
  ### from_source - the association from the parent or the domain if parent is root

  ### Dimension table join
  defp configure(id, association, %{type: :dimension} = config, parent, from_source, queryable) do
    # dimension table, has one 'name-ish' value to display, and then the Local reference would provide ID filtering.
    # So create a field for group-by that displays NAME and filters by ID

    name = Map.get(config, :name, id)

    from_field =
      case parent do
        :selecto_root -> "#{association.owner_key}"
        _ -> "#{parent}.#{association.owner_key}"
      end

    config =
      Map.put(
        config,
        :custom_columns,
        Map.get(config, :custom_columns, %{})
        |> Map.put(
          ## we will use the nane of the join's association!
          "#{id}",
          %{
            name: name,
            ### concat_ws?
            select: "#{association.field}.#{config.dimension}",
            ### we will always get a tuple of select + group_by_filter_select here
            group_by_format: fn {a, _id}, _def -> a end,
            group_by_filter: from_field,
            group_by_filter_select: ["#{association.field}.#{config.dimension}", from_field]
          }
        )
      )

    ### Add custom filter that has a select (or set of checkboxes or radios... filter_form_type: :checks eg) list of names, IF not existing by name of the remote ID filter and:
    ### - the join provides a list of tuples {filterable, viewable}
    ### - the join provides a function returning same
    ### - the join has 'facet: true' in which case we will determine given all other filters, what are the available items & how many matches for those items

    %{
      config: config,
      from_source: from_source,
      owner_key: association.owner_key,
      my_key: association.related_key,
      source: queryable.source_table,
      id: id,
      name: name,
      ## probably don't need 'where'
      requires_join: parent,
      filters: Map.get(config, :filters, %{}),
      fields:
        Selecto.Schema.Column.configure_columns(
          association.field,
          [config.dimension],
          queryable,
          config
        )
    }
    |> parameterize()
  end

  ### Many-to-many tagging join (through join table)
  defp configure(id, association, %{type: :tagging} = config, parent, from_source, queryable) do
    # For tagging relationships, we need to handle the intermediate join table
    # This assumes the association is a has_many :through relationship
    # Example: Post has_many :tags, through: :post_tags

    name = Map.get(config, :name, id)
    # Field to display from tag table
    tag_field = Map.get(config, :tag_field, :name)

    # Configure custom columns for tag aggregation
    config =
      Map.put(
        config,
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

    # Add faceted filter for individual tags
    config =
      Map.put(
        config,
        :custom_filters,
        Map.get(config, :custom_filters, %{})
        |> Map.put(
          "#{id}_filter",
          %{
            name: "#{name}",
            filter_type: :multi_select,
            # Enable faceted filtering
            facet: true,
            source_table: queryable.source_table,
            source_field: tag_field
          }
        )
      )

    %{
      config: config,
      from_source: from_source,
      owner_key: association.owner_key,
      my_key: association.related_key,
      source: queryable.source_table,
      id: id,
      name: name,
      requires_join: parent,
      # Special marker for SQL builder
      join_type: :many_to_many,
      filters: Map.get(config, :filters, %{}),
      fields:
        Selecto.Schema.Column.configure_columns(
          association.field,
          queryable.fields -- queryable.redact_fields,
          queryable,
          config
        )
    }
    |> parameterize()
  end

  ### Hierarchical self-join (adjacency list pattern)
  defp configure(id, association, %{type: :hierarchical} = config, parent, from_source, queryable) do
    # Self-referencing table with parent_id pointing to same table
    # Supports adjacency list hierarchical pattern

    name = Map.get(config, :name, id)
    hierarchy_type = Map.get(config, :hierarchy_type, :adjacency_list)
    # Prevent infinite recursion
    depth_limit = Map.get(config, :depth_limit, 5)

    case hierarchy_type do
      :adjacency_list ->
        configure_adjacency_list(
          id,
          association,
          config,
          parent,
          from_source,
          queryable,
          name,
          depth_limit
        )

      :materialized_path ->
        configure_materialized_path(id, association, config, parent, from_source, queryable, name)

      :closure_table ->
        configure_closure_table(id, association, config, parent, from_source, queryable, name)
    end
  end

  ### Star schema dimension join (optimized for OLAP)
  defp configure(
         id,
         association,
         %{type: :star_dimension} = config,
         parent,
         from_source,
         queryable
       ) do
    # Star schema dimensions are optimized for aggregation and analysis
    # They typically contain descriptive attributes and are joined to fact tables

    name = Map.get(config, :name, id)
    display_field = Map.get(config, :display_field, :name)

    # Configure dimension-specific features
    config =
      Map.put(
        config,
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

    # Add aggregation-friendly filters
    config =
      Map.put(
        config,
        :custom_filters,
        Map.get(config, :custom_filters, %{})
        |> Map.put(
          "#{id}_facet",
          %{
            name: "#{name} Filter",
            filter_type: :select_facet,
            # Enable faceted filtering for dimensions
            facet: true,
            source_table: queryable.source_table,
            source_field: display_field,
            is_dimension: true
          }
        )
      )

    %{
      config: config,
      from_source: from_source,
      owner_key: association.owner_key,
      my_key: association.related_key,
      source: queryable.source_table,
      id: id,
      name: name,
      requires_join: parent,
      # Optimized for OLAP queries
      join_type: :star_dimension,
      display_field: display_field,
      display_fallback: Map.get(config, :display_fallback),
      filters: Map.get(config, :filters, %{}),
      fields:
        Selecto.Schema.Column.configure_columns(
          association.field,
          queryable.fields -- queryable.redact_fields,
          queryable,
          config
        )
    }
    |> parameterize()
  end

  ### Snowflake schema normalized dimension join
  defp configure(
         id,
         association,
         %{type: :snowflake_dimension} = config,
         parent,
         from_source,
         queryable
       ) do
    # Snowflake dimensions are normalized and may require multiple joins to get full context
    # They maintain referential integrity but require more complex queries

    name = Map.get(config, :name, id)
    display_field = Map.get(config, :display_field, :name)
    # Additional joins needed
    normalization_joins = Map.get(config, :normalization_joins, [])

    # Configure for normalized dimension access
    config =
      Map.put(
        config,
        :custom_columns,
        Map.get(config, :custom_columns, %{})
        |> Map.put(
          "#{id}_normalized",
          %{
            name: "#{name}",
            select: build_snowflake_select(association.field, display_field, normalization_joins),
            group_by_format: fn {a, _id}, _def -> a end,
            filterable: true,
            requires_normalization_joins: normalization_joins
          }
        )
      )

    %{
      config: config,
      from_source: from_source,
      owner_key: association.owner_key,
      my_key: association.related_key,
      source: queryable.source_table,
      id: id,
      name: name,
      requires_join: parent,
      join_type: :snowflake_dimension,
      display_field: display_field,
      # Track additional joins needed
      normalization_joins: normalization_joins,
      filters: Map.get(config, :filters, %{}),
      fields:
        Selecto.Schema.Column.configure_columns(
          association.field,
          queryable.fields -- queryable.redact_fields,
          queryable,
          config
        )
    }
    |> parameterize()
  end

  ### Enhanced joins (new join types)
  defp configure(id, association, %{type: join_type} = config, parent, from_source, queryable)
       when join_type in [
              :self_join,
              :lateral_join,
              :cross_join,
              :full_outer_join,
              :conditional_join
            ] do
    Selecto.EnhancedJoins.configure_enhanced_join(
      id,
      association,
      config,
      parent,
      from_source,
      queryable
    )
  end

  ### Regular (catch-all clause)
  defp configure(id, association, config, parent, from_source, queryable) do
    std_config(id, association, config, parent, from_source, queryable)
  end

  defp configure_adjacency_list(
         id,
         association,
         config,
         parent,
         from_source,
         queryable,
         name,
         _depth_limit
       ) do
    # Add custom columns for hierarchy navigation
    # These reference fields from the JOIN alias used in the main query.
    join_alias = to_string(id)

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

    # Get the depth limit from config for the join struct
    depth_limit = Map.get(config, :depth_limit, 5)
    id_field = Map.get(config, :id_field, association.related_key || :id)
    parent_field = Map.get(config, :parent_field, association.owner_key || :parent_id)
    name_field = Map.get(config, :name_field, :name)

    %{
      config: config,
      from_source: from_source,
      owner_key: association.owner_key,
      my_key: association.related_key,
      source: queryable.source_table,
      id: id,
      name: name,
      requires_join: parent,
      join_type: :hierarchical_adjacency,
      hierarchy_depth: depth_limit,
      id_field: id_field,
      parent_field: parent_field,
      name_field: name_field,
      filters: Map.get(config, :filters, %{}),
      fields:
        Selecto.Schema.Column.configure_columns(
          association.field,
          queryable.fields -- queryable.redact_fields,
          queryable,
          config
        )
    }
    |> parameterize()
  end

  defp configure_materialized_path(id, association, config, parent, from_source, queryable, name) do
    path_field = Map.get(config, :path_field, :path)
    path_separator = Map.get(config, :path_separator, "/")
    root_path = Map.get(config, :root_path, "")

    # Add custom columns for path-based operations
    # These reference fields from the JOIN alias used in the main query.
    join_alias = to_string(id)

    config =
      Map.put(
        config,
        :custom_columns,
        Map.get(config, :custom_columns, %{})
        |> Map.put(
          "#{id}_depth",
          %{
            name: "#{name} Depth",
            select: "#{join_alias}.depth",
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

    %{
      config: config,
      from_source: from_source,
      owner_key: association.owner_key,
      my_key: association.related_key,
      source: queryable.source_table,
      id: id,
      name: name,
      requires_join: parent,
      join_type: :hierarchical_materialized_path,
      path_field: path_field,
      path_separator: path_separator,
      root_path: root_path,
      filters: Map.get(config, :filters, %{}),
      fields:
        Selecto.Schema.Column.configure_columns(
          association.field,
          queryable.fields -- queryable.redact_fields,
          queryable,
          config
        )
    }
    |> parameterize()
  end

  defp configure_closure_table(id, association, config, parent, from_source, queryable, name) do
    # Assumes a separate closure table exists for storing ancestor-descendant relationships
    closure_table = Map.get(config, :closure_table, "#{queryable.source_table}_closure")
    ancestor_field = Map.get(config, :ancestor_field, :ancestor_id)
    descendant_field = Map.get(config, :descendant_field, :descendant_id)
    depth_field = Map.get(config, :depth_field, :depth)

    # Add custom columns leveraging closure table CTE
    # These reference fields from the JOIN alias used in the main query.
    join_alias = to_string(id)

    config =
      Map.put(
        config,
        :custom_columns,
        Map.get(config, :custom_columns, %{})
        |> Map.put(
          "#{id}_depth",
          %{
            name: "#{name} Depth",
            select: "#{join_alias}.depth",
            group_by_format: fn {a, _id}, _def -> a end,
            filterable: true
          }
        )
        |> Map.put(
          "#{id}_descendant_count",
          %{
            name: "#{name} Descendant Count",
            select: "#{join_alias}.descendant_count",
            group_by_format: fn {a, _id}, _def -> a end,
            filterable: true
          }
        )
      )

    %{
      config: config,
      from_source: from_source,
      owner_key: association.owner_key,
      my_key: association.related_key,
      source: queryable.source_table,
      id: id,
      name: name,
      requires_join: parent,
      join_type: :hierarchical_closure_table,
      closure_table: closure_table,
      ancestor_field: ancestor_field,
      descendant_field: descendant_field,
      depth_field: depth_field,
      filters: Map.get(config, :filters, %{}),
      fields:
        Selecto.Schema.Column.configure_columns(
          association.field,
          queryable.fields -- queryable.redact_fields,
          queryable,
          config
        )
    }
    |> parameterize()
  end

  # Helper functions for building hierarchy SQL
  # Note: Previously broken CTE functions have been removed and replaced with
  # proper CTE integration in the SQL builder. Custom columns now reference
  # CTE fields directly instead of embedding invalid subqueries.

  defp build_snowflake_select(field, display_field, normalization_joins) do
    # Build select clause that may require additional joins for normalized data
    # This is a simplified version - real implementation would coordinate with SQL builder
    case normalization_joins do
      [] -> "#{field}.#{display_field}"
      # Use the normalized table's field
      [%{alias: alias_name} | _] -> "#{alias_name}.#{display_field}"
      [%{table: table} | _] -> "#{table}.#{display_field}"
      # Fallback for string joins
      [join | _] when is_binary(join) -> "#{join}.#{display_field}"
    end
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
      ## probably don't need 'where'
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
    |> parameterize()
  end

  defp parameterize(join) do
    join
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
