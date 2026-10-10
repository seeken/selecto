defmodule Selecto.Builder.Subselect do
  @moduledoc """
  SQL generation logic for Subselect functionality.

  This module handles the construction of correlated subqueries that return
  aggregated data from related tables as JSON arrays, collection values,
  or other aggregate formats.
  """

  import Selecto.Builder.Sql.Helpers, only: [quote_identifier: 2]
  # alias Selecto.SQL.Params
  alias Selecto.Types
  alias Selecto.AdapterSupport
  alias Selecto.Dialect.Collection.Operation, as: CollectionOperation
  alias Selecto.Dialect.Json.Operation, as: JsonOperation

  @doc """
  Build subselect clauses for the SELECT portion of the query.

  Returns a list of SQL fragments that can be included in the main SELECT clause.
  Each subselect becomes a correlated subquery that aggregates related data.
  """
  @spec build_subselect_clauses(Types.t()) :: {[Types.iodata_with_markers()], Types.sql_params()}
  def build_subselect_clauses(selecto) do
    source_alias = "selecto_root"

    build_subselect_clauses(selecto, source_alias)
  end

  @spec build_subselect_clauses(Types.t(), String.t()) ::
          {[Types.iodata_with_markers()], Types.sql_params()}
  def build_subselect_clauses(selecto, source_alias) do
    subselects = Selecto.Subselect.get_subselect_configs(selecto)

    if length(subselects) > 0 do
      {clauses, all_params} =
        Enum.map(subselects, &build_single_subselect(selecto, &1, source_alias))
        |> Enum.unzip()

      # Join multiple subselect clauses with commas
      combined_clauses =
        case clauses do
          [single] -> single
          multiple -> Enum.intersperse(multiple, ", ")
        end

      {combined_clauses, List.flatten(all_params)}
    else
      {[], []}
    end
  end

  @doc """
  Build a single correlated subquery for a subselect configuration.
  """
  @spec build_single_subselect(Types.t(), Types.subselect_selector()) ::
          {Types.iodata_with_markers(), Types.sql_params()}
  def build_single_subselect(selecto, subselect_config) do
    source_alias = "selecto_root"

    build_single_subselect(selecto, subselect_config, source_alias)
  end

  @spec build_single_subselect(Types.t(), Types.subselect_selector(), String.t()) ::
          {Types.iodata_with_markers(), Types.sql_params()}
  def build_single_subselect(selecto, subselect_config, source_alias) do
    # Build the complete subselect with aggregation function
    {subselect_iodata, subselect_params} =
      build_aggregated_subselect(selecto, subselect_config, source_alias)

    # Add alias for the subselect field
    field_with_alias = [
      "(",
      subselect_iodata,
      ") AS ",
      adapter_quote_identifier(selecto, subselect_config.alias)
    ]

    {field_with_alias, subselect_params}
  end

  defp build_aggregated_subselect(selecto, subselect_config, source_alias) do
    target_table = get_target_table(selecto, subselect_config.target_schema)
    target_alias = generate_subquery_alias(subselect_config.target_schema)
    adapter_name = AdapterSupport.adapter_name(Map.get(selecto, :adapter))

    if Map.get(subselect_config, :limit) && adapter_name not in [:postgresql, :sqlite] do
      raise ArgumentError, "per-parent collection limits require PostgreSQL or SQLite"
    end

    cond do
      adapter_name == :mssql and subselect_config.format == :json_agg ->
        build_mssql_json_agg_subselect(
          selecto,
          subselect_config,
          source_alias,
          target_table,
          target_alias
        )

      adapter_name == :mssql and subselect_config.format == :array_agg ->
        build_mssql_array_agg_subselect(
          selecto,
          subselect_config,
          source_alias,
          target_table,
          target_alias
        )

      true ->
        do_build_aggregated_subselect(
          selecto,
          subselect_config,
          source_alias,
          target_table,
          target_alias
        )
    end
  end

  defp do_build_aggregated_subselect(
         selecto,
         subselect_config,
         source_alias,
         target_table,
         target_alias
       ) do
    # Build SELECT fields for the subquery based on aggregation type
    {select_clause, select_params} =
      case subselect_config.format do
        :json_agg ->
          if length(subselect_config.fields) == 1 and nested_subselects(subselect_config) == [] do
            [field] = subselect_config.fields
            field_name = adapter_quote_identifier(selecto, to_string(field))

            render_json_aggregate!(
              selecto,
              [target_alias, ".", field_name],
              subselect_config,
              target_alias
            )
          else
            # Multiple fields - build JSON objects
            {json_pairs, nested_params} =
              build_json_object_pairs(selecto, subselect_config, target_alias)

            {json_object, object_params} = render_json_object!(selecto, json_pairs)

            {json_build, aggregate_params} =
              render_json_aggregate!(selecto, json_object, subselect_config, target_alias)

            {json_build, nested_params ++ object_params ++ aggregate_params}
          end

        :array_agg ->
          # Simplify for now
          [field] = subselect_config.fields
          field_name = adapter_quote_identifier(selecto, to_string(field))
          render_collection_aggregate!(selecto, :array_agg, [target_alias, ".", field_name])

        :string_agg ->
          # Simplify for now
          [field] = subselect_config.fields
          field_name = adapter_quote_identifier(selecto, to_string(field))
          separator = Map.get(subselect_config, :separator, ",")

          render_collection_aggregate!(
            selecto,
            :string_agg,
            [target_alias, ".", field_name],
            delimiter: separator
          )

        :count ->
          {["count(*)"], []}

        :sum ->
          [field] = subselect_config.fields
          field_name = adapter_quote_identifier(selecto, to_string(field))
          {["COALESCE(SUM(", target_alias, ".", field_name, "), 0)"], []}
      end

    # Build correlation WHERE clause
    {correlation_where, correlation_params} =
      build_correlation_condition(
        selecto,
        subselect_config,
        target_alias,
        source_alias
      )

    # Build additional filters if specified
    {additional_where, additional_params} =
      build_additional_filters(
        selecto,
        subselect_config,
        target_alias
      )

    parent_primary_key =
      if Map.get(subselect_config, :after), do: root_parent_primary_key(selecto), else: nil

    {cursor_where, cursor_params} =
      build_collection_cursor_condition(
        selecto,
        subselect_config,
        target_alias,
        source_alias,
        parent_primary_key
      )

    # Combine all WHERE conditions
    all_where_conditions =
      [correlation_where] ++
        if(additional_where != [], do: [additional_where], else: []) ++
        if cursor_where != [], do: [cursor_where], else: []

    where_clause =
      case all_where_conditions do
        [single] -> single
        multiple -> Enum.intersperse(multiple, [" AND "])
      end

    # A per-parent limit belongs inside the correlated rowset, before JSON
    # aggregation. Limiting the aggregate query itself would not limit children.
    subselect_iodata = [
      "SELECT ",
      select_clause,
      " FROM ",
      collection_from_clause(
        selecto,
        subselect_config,
        target_table,
        target_alias,
        where_clause
      )
    ]

    all_params = select_params ++ correlation_params ++ additional_params ++ cursor_params
    {subselect_iodata, all_params}
  end

  defp build_json_object_pairs(selecto, subselect_config, target_alias) do
    field_pairs =
      Enum.map(subselect_config.fields, fn field ->
        field_key = escape_string(json_field_key(field))
        [field_key, ", ", nested_json_field_value(selecto, subselect_config, target_alias, field)]
      end)

    {nested_pairs, nested_params} =
      subselect_config
      |> nested_subselects()
      |> Enum.map(&build_nested_json_pair(selecto, subselect_config, &1, target_alias))
      |> Enum.unzip()

    {field_pairs ++ nested_pairs, List.flatten(nested_params)}
  end

  defp nested_json_field_value(selecto, subselect_config, target_alias, field) do
    field_sql = [target_alias, ".", adapter_quote_identifier(selecto, to_string(field))]
    schema = get_target_schema_config(selecto, subselect_config.target_schema)
    columns = Map.get(schema, :columns) || %{}

    column = Map.get(columns, to_string(field)) || Map.get(columns, field)
    type = if is_map(column), do: Map.get(column, :type) || Map.get(column, "type")

    if type in [:decimal, :numeric, :number, "decimal", "numeric", "number"] and
         AdapterSupport.adapter_name(Map.get(selecto, :adapter)) == :postgresql do
      # JSON decoders commonly turn JSON numeric literals into IEEE floats.
      # Project declared exact decimals as strings before JSON serialization.
      {value_sql, []} =
        render_json_operation!(selecto, %JsonOperation{
          operation: :json_exact_decimal_value,
          clause: :select,
          options: %{column_sql: field_sql}
        })

      value_sql
    else
      field_sql
    end
  end

  defp build_nested_json_pair(selecto, parent_config, child_config, parent_alias) do
    child_key = nested_key(child_config)
    child_alias = nested_alias(parent_alias, child_key)
    {child_select, child_params} = build_nested_json_agg(selecto, child_config, child_alias)
    child_table = get_target_table(selecto, child_config.target_schema)

    {correlation_where, correlation_params} =
      build_nested_correlation_condition(
        selecto,
        parent_config,
        child_config,
        parent_alias,
        child_alias
      )

    {additional_where, additional_params} =
      build_additional_filters(selecto, child_config, child_alias)

    parent_primary_key =
      if Map.get(child_config, :after) do
        get_target_schema_config(selecto, parent_config.target_schema).primary_key
      end

    {cursor_where, cursor_params} =
      build_collection_cursor_condition(
        selecto,
        child_config,
        child_alias,
        parent_alias,
        parent_primary_key
      )

    where_clause =
      build_combined_where_clause(
        build_combined_where_clause(correlation_where, additional_where),
        cursor_where
      )

    {empty_json, empty_params} = render_empty_json_array!(selecto)

    subquery = [
      "COALESCE((SELECT ",
      child_select,
      " FROM ",
      collection_from_clause(selecto, child_config, child_table, child_alias, where_clause),
      "), ",
      empty_json,
      ")"
    ]

    {[escape_string(child_key), ", ", subquery],
     child_params ++ correlation_params ++ additional_params ++ cursor_params ++ empty_params}
  end

  defp build_nested_json_agg(selecto, subselect_config, target_alias) do
    cond do
      subselect_config.format == :json_agg and
        length(subselect_config.fields) == 1 and nested_subselects(subselect_config) == [] ->
        [field] = subselect_config.fields
        field_name = adapter_quote_identifier(selecto, to_string(field))

        render_json_aggregate!(
          selecto,
          [target_alias, ".", field_name],
          subselect_config,
          target_alias
        )

      subselect_config.format == :json_agg ->
        {json_pairs, nested_params} =
          build_json_object_pairs(selecto, subselect_config, target_alias)

        {json_object, object_params} = render_json_object!(selecto, json_pairs)

        {json_build, aggregate_params} =
          render_json_aggregate!(selecto, json_object, subselect_config, target_alias)

        {json_build, nested_params ++ object_params ++ aggregate_params}

      true ->
        raise ArgumentError,
              "Nested subselects currently require json_agg format, got #{inspect(subselect_config.format)}"
    end
  end

  defp render_json_aggregate!(selecto, expression, subselect_config, target_alias) do
    {order_by_sql, []} = build_subquery_order_by(selecto, subselect_config, target_alias)

    # SQLite consumes the ordered derived relation below, which also works
    # before aggregate ORDER BY was added in SQLite 3.44.
    order_by_sql =
      if AdapterSupport.adapter_name(Map.get(selecto, :adapter)) == :sqlite,
        do: nil,
        else: order_by_sql

    render_json_operation!(selecto, %JsonOperation{
      operation: :json_agg,
      clause: :select,
      options: %{column_sql: expression, order_by_sql: order_by_sql}
    })
  end

  defp collection_from_clause(selecto, config, table, target_alias, where_clause) do
    adapter_name = AdapterSupport.adapter_name(Map.get(selecto, :adapter))
    limit = Map.get(config, :limit)

    if adapter_name == :sqlite and
         (Map.get(config, :order_by, []) != [] or not is_nil(limit)) and
         (is_nil(limit) or (is_integer(limit) and limit > 0)) do
      {order_by_sql, []} = build_subquery_order_by(selecto, config, target_alias)

      [
        "(SELECT ",
        target_alias,
        ".* FROM ",
        table,
        " ",
        target_alias,
        " WHERE ",
        where_clause,
        " ORDER BY ",
        order_by_sql,
        if(limit, do: [" LIMIT ", Integer.to_string(limit)], else: []),
        ") ",
        target_alias
      ]
    else
      collection_from_clause_with_limit(selecto, config, table, target_alias, where_clause)
    end
  end

  defp collection_from_clause_with_limit(selecto, config, table, target_alias, where_clause) do
    case Map.get(config, :limit) do
      nil ->
        [table, " ", target_alias, " WHERE ", where_clause]

      limit when is_integer(limit) and limit > 0 ->
        if AdapterSupport.adapter_name(Map.get(selecto, :adapter)) != :postgresql do
          raise ArgumentError, "per-parent collection limits require PostgreSQL or SQLite"
        end

        {order_by_sql, []} = build_subquery_order_by(selecto, config, target_alias)

        [
          "(SELECT ",
          target_alias,
          ".* FROM ",
          table,
          " ",
          target_alias,
          " WHERE ",
          where_clause,
          " ORDER BY ",
          order_by_sql,
          " LIMIT ",
          Integer.to_string(limit),
          ") ",
          target_alias
        ]

      _ ->
        raise ArgumentError, "per-parent collection limit must be a positive integer"
    end
  end

  defp render_json_object!(selecto, pairs) do
    render_json_operation!(selecto, %JsonOperation{
      operation: :json_build_object,
      clause: :select,
      options: %{pairs_sql: Enum.intersperse(pairs, [", "])}
    })
  end

  defp render_empty_json_array!(selecto) do
    render_json_operation!(selecto, %JsonOperation{
      operation: :json_empty_array,
      clause: :select
    })
  end

  defp render_json_operation!(selecto, operation) do
    selecto.adapter
    |> Selecto.DialectSupport.render_json(:render_json_operation, operation, selecto)
    |> unwrap_dialect_fragment!()
  end

  defp render_collection_aggregate!(selecto, operation, expression, opts \\ []) do
    fragment = %CollectionOperation{
      operation: operation,
      clause: :select,
      column: expression,
      distinct: false,
      order_by: [],
      options: Map.new(opts)
    }

    selecto.adapter
    |> Selecto.DialectSupport.render_collection_operation(fragment, selecto)
    |> unwrap_dialect_fragment!()
  end

  defp unwrap_dialect_fragment!({:ok, {iodata, params}}), do: {iodata, params}
  defp unwrap_dialect_fragment!({:ok, iodata}), do: {iodata, []}

  defp unwrap_dialect_fragment!({:error, %Selecto.Error{} = error}),
    do: raise(Selecto.Error.to_exception(error))

  defp unwrap_dialect_fragment!({:error, reason}),
    do: raise(ArgumentError, "unsupported subselect dialect fragment: #{inspect(reason)}")

  defp build_nested_correlation_condition(
         selecto,
         parent_config,
         child_config,
         parent_alias,
         child_alias
       ) do
    parent_schema_config = get_target_schema_config(selecto, parent_config.target_schema)
    child_path = nested_join_path!(selecto, parent_config, child_config)

    with {:ok, edges} <- resolve_join_edges(selecto, parent_schema_config, child_path, []),
         :ok <-
           validate_correlation_target(
             selecto,
             List.last(edges).association.queryable,
             child_config.target_schema
           ) do
      condition =
        case edges do
          [edge] ->
            edge_correlation(selecto, edge, child_alias, parent_alias)

          _ ->
            {intermediate_edges, [final_edge]} = Enum.split(edges, -1)

            {join_clauses, start_correlation, end_correlation} =
              render_join_chain(
                selecto,
                intermediate_edges,
                final_edge,
                parent_alias,
                child_alias
              )

            [
              "EXISTS (SELECT 1 FROM ",
              join_clauses,
              " WHERE ",
              start_correlation,
              " AND ",
              end_correlation,
              ")"
            ]
        end

      {condition, []}
    else
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp nested_join_path!(selecto, parent_config, child_config) do
    parent_path = config_join_path!(selecto, parent_config)
    child_path = config_join_path!(selecto, child_config)

    cond do
      length(child_path) > length(parent_path) and
          Enum.take(child_path, length(parent_path)) == parent_path ->
        Enum.drop(child_path, length(parent_path))

      length(child_path) == 1 ->
        child_path

      true ->
        raise ArgumentError,
              "Nested subselect path #{inspect(child_path)} must extend its parent path #{inspect(parent_path)}"
    end
  end

  defp config_join_path!(selecto, config) do
    case Map.get(config, :join_path) do
      path when is_list(path) and path != [] ->
        normalize_join_path(path)

      _ ->
        case Selecto.Subselect.resolve_join_path(selecto, config.target_schema) do
          {:ok, path} -> normalize_join_path(path)
          {:error, reason} -> raise ArgumentError, reason
        end
    end
  end

  defp nested_subselects(config), do: Map.get(config, :nested, Map.get(config, "nested", []))

  defp nested_key(config) do
    Map.get(config, :key) ||
      Map.get(config, "key") ||
      Map.get(config, :alias) ||
      Map.get(config, "alias") ||
      Map.get(config, :join_path, []) |> List.last() |> to_string()
  end

  defp nested_alias(parent_alias, child_key) do
    safe_child =
      child_key
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_]+/, "_")

    "#{parent_alias}_#{safe_child}"
  end

  defp normalize_join_path(path) when is_list(path), do: Enum.map(path, &normalize_join_segment/1)
  defp normalize_join_path(_path), do: []

  defp normalize_join_segment(segment) when is_atom(segment), do: segment

  defp normalize_join_segment(segment) do
    try do
      segment |> to_string() |> String.to_existing_atom()
    rescue
      ArgumentError -> to_string(segment)
    end
  end

  defp fetch_equivalent_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn {candidate, value} ->
          if equivalent_key?(candidate, key), do: value
        end)
    end
  end

  defp equivalent_key?(left, right) when is_atom(left) and is_binary(right),
    do: Atom.to_string(left) == right

  defp equivalent_key?(left, right) when is_binary(left) and is_atom(right),
    do: left == Atom.to_string(right)

  defp equivalent_key?(_left, _right), do: false

  defp json_field_key(field) do
    field
    |> to_string()
    |> String.split(".")
    |> List.last()
  end

  defp build_mssql_json_agg_subselect(
         selecto,
         subselect_config,
         source_alias,
         target_table,
         target_alias
       ) do
    {correlation_where, correlation_params} =
      build_correlation_condition(
        selecto,
        subselect_config,
        target_alias,
        source_alias
      )

    {additional_where, additional_params} =
      build_additional_filters(
        selecto,
        subselect_config,
        target_alias
      )

    all_where_conditions =
      [correlation_where] ++
        if additional_where != [], do: [additional_where], else: []

    where_clause =
      case all_where_conditions do
        [single] -> single
        multiple -> Enum.intersperse(multiple, [" AND "])
      end

    select_fields =
      build_mssql_json_path_select_fields(
        selecto,
        subselect_config.target_schema,
        subselect_config.fields,
        target_alias
      )

    subselect_iodata = [
      "SELECT COALESCE((SELECT ",
      select_fields,
      " FROM ",
      target_table,
      " ",
      target_alias,
      " WHERE ",
      where_clause,
      " FOR JSON PATH), '[]')"
    ]

    {subselect_iodata, correlation_params ++ additional_params}
  end

  defp build_mssql_array_agg_subselect(
         selecto,
         subselect_config,
         source_alias,
         target_table,
         target_alias
       ) do
    [field] = subselect_config.fields

    select_field = [
      build_mssql_subselect_field_expr(
        selecto,
        subselect_config.target_schema,
        field,
        target_alias
      ),
      " AS ",
      adapter_quote_identifier(selecto, mssql_json_field_alias(field))
    ]

    build_mssql_json_array_subselect(
      selecto,
      subselect_config,
      source_alias,
      target_table,
      target_alias,
      select_field
    )
  end

  defp build_mssql_json_array_subselect(
         selecto,
         subselect_config,
         source_alias,
         target_table,
         target_alias,
         select_field
       ) do
    {correlation_where, correlation_params} =
      build_correlation_condition(selecto, subselect_config, target_alias, source_alias)

    {additional_where, additional_params} =
      build_additional_filters(selecto, subselect_config, target_alias)

    where_clause = build_combined_where_clause(correlation_where, additional_where)

    subselect_iodata = [
      "SELECT COALESCE((SELECT ",
      select_field,
      " FROM ",
      target_table,
      " ",
      target_alias,
      " WHERE ",
      where_clause,
      " FOR JSON PATH), '[]')"
    ]

    {subselect_iodata, correlation_params ++ additional_params}
  end

  defp build_combined_where_clause(correlation_where, additional_where) do
    all_where_conditions =
      [correlation_where] ++ if additional_where != [], do: [additional_where], else: []

    case all_where_conditions do
      [single] -> single
      multiple -> Enum.intersperse(multiple, [" AND "])
    end
  end

  defp build_mssql_json_path_select_fields(selecto, target_schema, fields, target_alias) do
    target_schema_config = get_target_schema_config(selecto, target_schema)

    fields
    |> Enum.map(fn field ->
      field_string = to_string(field)
      field_alias = adapter_quote_identifier(selecto, mssql_json_field_alias(field_string))

      field_sql =
        case Selecto.Json.parse_field_reference(field_string, target_schema_config) do
          {:json_path, column, path} ->
            Selecto.Json.build_extraction(column, path,
              adapter: Map.get(selecto, :adapter),
              table_alias: target_alias
            )

          {:regular, _} ->
            field_name = adapter_quote_identifier(selecto, field_string)
            [target_alias, ".", field_name]
        end

      [field_sql, " AS ", field_alias]
    end)
    |> Enum.intersperse([", "])
  end

  defp build_mssql_subselect_field_expr(selecto, target_schema, field, target_alias) do
    field_string = to_string(field)
    target_schema_config = get_target_schema_config(selecto, target_schema)

    case Selecto.Json.parse_field_reference(field_string, target_schema_config) do
      {:json_path, column, path} ->
        Selecto.Json.build_extraction(column, path,
          adapter: Map.get(selecto, :adapter),
          table_alias: target_alias
        )

      {:regular, _} ->
        field_name = adapter_quote_identifier(selecto, field_string)
        [target_alias, ".", field_name]
    end
  end

  defp mssql_json_field_alias(field) do
    field
    |> to_string()
    |> String.split(".")
    |> List.last()
  end

  @doc """
  Build the correlated subquery that fetches related data.
  """
  @spec build_correlated_subquery(Types.t(), Types.subselect_selector()) ::
          {Types.iodata_with_markers(), Types.sql_params()}
  def build_correlated_subquery(selecto, subselect_config) do
    source_alias = "selecto_root"

    build_correlated_subquery(selecto, subselect_config, source_alias)
  end

  @spec build_correlated_subquery(Types.t(), Types.subselect_selector(), String.t()) ::
          {Types.iodata_with_markers(), Types.sql_params()}
  def build_correlated_subquery(selecto, subselect_config, source_alias) do
    target_table = get_target_table(selecto, subselect_config.target_schema)
    target_alias = generate_subquery_alias(subselect_config.target_schema)

    # Build SELECT fields for the subquery
    {select_fields, select_params} =
      build_subquery_select_fields(selecto, subselect_config, target_alias)

    # Build correlation WHERE clause
    {correlation_where, correlation_params} =
      build_correlation_condition(
        selecto,
        subselect_config,
        target_alias,
        source_alias
      )

    # Build additional filters if specified
    {additional_where, additional_params} =
      build_additional_filters(
        selecto,
        subselect_config,
        target_alias
      )

    # Build ORDER BY if specified
    {order_clause, order_params} =
      build_subquery_order_by(
        selecto,
        subselect_config,
        target_alias
      )

    # Combine all WHERE conditions
    all_where_conditions =
      [correlation_where] ++
        if additional_where != [], do: [additional_where], else: []

    where_clause =
      case all_where_conditions do
        [single] -> single
        multiple -> Enum.intersperse(multiple, [" AND "])
      end

    base_subquery = [
      "SELECT ",
      select_fields,
      " FROM ",
      target_table,
      " ",
      target_alias,
      " WHERE ",
      where_clause
    ]

    subquery_iodata =
      if order_clause != [] do
        base_subquery ++ [" ORDER BY ", order_clause]
      else
        base_subquery
      end

    all_params = select_params ++ correlation_params ++ additional_params ++ order_params
    {subquery_iodata, all_params}
  end

  @doc """
  Wrap subquery results in the appropriate aggregation function.
  """
  @spec wrap_in_aggregation(
          Types.iodata_with_markers(),
          Types.sql_params(),
          Types.subselect_format(),
          Types.subselect_selector()
        ) ::
          {Types.iodata_with_markers(), Types.sql_params()}
  def wrap_in_aggregation(subquery_iodata, subquery_params, format, _config) do
    case format do
      :json_agg ->
        {["(", subquery_iodata, ")"], subquery_params}

      :array_agg ->
        {["(", subquery_iodata, ")"], subquery_params}

      :string_agg ->
        {["(", subquery_iodata, ")"], subquery_params}

      :count ->
        # For count, we need to modify the SELECT clause
        count_subquery =
          String.replace(
            IO.iodata_to_binary(subquery_iodata),
            "SELECT ",
            "SELECT count(*) FROM (SELECT "
          )

        count_subquery = count_subquery <> ") _count_sub"
        {[count_subquery], subquery_params}
    end
  end

  @doc """
  Resolve the join condition needed to correlate the subquery with the main query.
  """
  @spec resolve_join_condition(Types.t(), atom()) ::
          {:ok, {String.t(), String.t()}} | {:error, String.t()}
  def resolve_join_condition(selecto, target_schema) do
    # Find the relationship path from source to target
    case Selecto.Subselect.resolve_join_path(selecto, target_schema) do
      {:ok, join_path} ->
        # Get the final connection fields
        {source_field, target_field} = get_connection_fields(selecto, target_schema, join_path)
        {:ok, {source_field, target_field}}

      {:error, reason} ->
        {:error, "Cannot resolve join condition: #{reason}"}
    end
  end

  @spec resolve_join_condition_with_path(Types.t(), atom()) ::
          {:ok, Types.iodata_with_markers()} | {:error, String.t()}
  def resolve_join_condition_with_path(selecto, target_schema) do
    source_alias = "selecto_root"

    resolve_join_condition_with_path(selecto, target_schema, source_alias, nil)
  end

  @spec resolve_join_condition_with_path(Types.t(), atom(), String.t()) ::
          {:ok, Types.iodata_with_markers()} | {:error, String.t()}
  def resolve_join_condition_with_path(selecto, target_schema, source_alias) do
    resolve_join_condition_with_path(selecto, target_schema, source_alias, nil)
  end

  @spec resolve_join_condition_with_path(Types.t(), atom(), String.t(), [atom()] | nil) ::
          {:ok, Types.iodata_with_markers()} | {:error, String.t()}
  def resolve_join_condition_with_path(selecto, target_schema, source_alias, explicit_join_path) do
    if is_list(explicit_join_path) and explicit_join_path != [] do
      build_join_condition_from_path(selecto, target_schema, explicit_join_path, source_alias)
    else
      do_resolve_join_condition_with_path(selecto, target_schema, source_alias)
    end
  end

  defp do_resolve_join_condition_with_path(selecto, target_schema, source_alias) do
    # Use join path resolution for all cases
    case Selecto.Subselect.resolve_join_path(selecto, target_schema) do
      {:ok, []} ->
        # Direct relationship - build simple correlation
        build_direct_correlation(selecto, target_schema, source_alias)

      {:ok, [single_schema]} when single_schema == target_schema ->
        # Single-step direct foreign key relationship
        build_direct_correlation(selecto, target_schema, source_alias)

      {:ok, join_path} ->
        # Multi-step relationship - build EXISTS condition
        build_exists_correlation(selecto, target_schema, join_path, source_alias)

      {:error, reason} ->
        {:error, "Cannot resolve join condition: #{reason}"}
    end
  end

  defp build_join_condition_from_path(selecto, target_schema, [assoc_name], source_alias) do
    build_direct_correlation_with_assoc(selecto, target_schema, assoc_name, source_alias)
  end

  defp build_join_condition_from_path(selecto, target_schema, join_path, source_alias) do
    build_exists_correlation(selecto, target_schema, join_path, source_alias)
  end

  # Private helper functions

  # Removed application-specific correlation functions.
  # These should be handled by the general join path resolution above.

  defp build_direct_correlation(selecto, target_schema, source_alias) do
    target_alias = generate_subquery_alias(target_schema)

    current_schema_config = selecto.domain.source
    association = Map.get(current_schema_config.associations, target_schema)

    if association do
      ensure_correlation_target!(selecto, association.queryable, target_schema)

      condition =
        build_association_correlation_condition(
          selecto,
          target_schema,
          association,
          current_schema_config,
          get_target_schema_config(selecto, association.queryable),
          target_alias,
          source_alias
        )

      {:ok, condition}
    else
      # No association found - raise error instead of using incorrect fallback
      {:error,
       "Cannot find association from #{inspect(current_schema_config.source_table)} to #{target_schema}"}
    end
  end

  # Build direct correlation when we already know the association name
  defp build_direct_correlation_with_assoc(selecto, target_schema, assoc_name, source_alias) do
    target_alias = generate_subquery_alias(target_schema)

    current_schema_config = selecto.domain.source
    association = Map.get(current_schema_config.associations, assoc_name)

    if association do
      ensure_correlation_target!(selecto, association.queryable, target_schema)

      condition =
        build_association_correlation_condition(
          selecto,
          assoc_name,
          association,
          current_schema_config,
          get_target_schema_config(selecto, association.queryable),
          target_alias,
          source_alias
        )

      {:ok, condition}
    else
      # No association found
      {:error,
       "Cannot find association #{assoc_name} from #{inspect(current_schema_config.source_table)}"}
    end
  end

  defp build_association_correlation_condition(
         selecto,
         association_id,
         association,
         source_relation,
         target_relation,
         target_alias,
         source_alias
       ) do
    # Resolve scope keys through the schema (authored keys or inferred tenant
    # fields, validated against both relations), then render the shared
    # domain-owned association predicate (through bridges, policies, quoting).
    association =
      case Selecto.Schema.Join.association_scope_keys!(
             association_id,
             association,
             source_relation,
             target_relation
           ) do
        {nil, nil} ->
          association

        {source_scope_key, target_scope_key} ->
          association
          |> Map.put(:source_scope_key, source_scope_key)
          |> Map.put(:target_scope_key, target_scope_key)
      end

    Selecto.Builder.Association.predicate(selecto, association, target_alias, source_alias)
  end

  defp build_exists_correlation(selecto, target_schema, [assoc_name], source_alias) do
    build_direct_correlation_with_assoc(selecto, target_schema, assoc_name, source_alias)
  end

  defp build_exists_correlation(selecto, target_schema, join_path, source_alias) do
    target_alias = generate_subquery_alias(target_schema)

    case build_join_chain(selecto, join_path, source_alias, target_schema, target_alias) do
      {:ok, {join_clauses, start_correlation, end_correlation}} ->
        {:ok,
         [
           "EXISTS (SELECT 1 FROM ",
           join_clauses,
           " WHERE ",
           start_correlation,
           " AND ",
           end_correlation,
           ")"
         ]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_join_chain(selecto, join_path, source_alias, target_schema, target_alias) do
    if length(join_path) < 2 do
      {:error, "Multi-step path must have at least 2 associations"}
    else
      with {:ok, edges} <- resolve_join_edges(selecto, selecto.domain.source, join_path, []),
           :ok <-
             validate_correlation_target(
               selecto,
               List.last(edges).association.queryable,
               target_schema
             ) do
        {intermediate_edges, [final_edge]} = Enum.split(edges, -1)

        {:ok,
         render_join_chain(selecto, intermediate_edges, final_edge, source_alias, target_alias)}
      end
    end
  end

  defp resolve_join_edges(_selecto, _current_relation, [], edges), do: {:ok, edges}

  defp resolve_join_edges(selecto, current_relation, [association_id | remaining_path], edges) do
    case fetch_equivalent_key(current_relation.associations || %{}, association_id) do
      nil ->
        {:error,
         "No association found from #{current_relation.source_table} to #{association_id}"}

      association ->
        case fetch_equivalent_key(selecto.domain.schemas, association.queryable) do
          nil ->
            {:error,
             "Schema #{association.queryable} not found in domain (from association #{association_id})"}

          target_relation ->
            edge = %{
              association_id: association_id,
              association: association,
              source_relation: current_relation,
              target_relation: target_relation
            }

            resolve_join_edges(selecto, target_relation, remaining_path, edges ++ [edge])
        end
    end
  end

  defp render_join_chain(
         selecto,
         [first_edge | remaining_edges],
         final_edge,
         source_alias,
         target_alias
       ) do
    reserved_aliases = [source_alias, target_alias]
    first_alias = available_join_alias(first_edge.association_id, reserved_aliases)
    first_table = [first_edge.target_relation.source_table, " ", first_alias]
    start_correlation = edge_correlation(selecto, first_edge, first_alias, source_alias)

    {join_clauses, parent_alias, _aliases} =
      remaining_edges
      |> Enum.reduce({[first_table], first_alias, [first_alias | reserved_aliases]}, fn edge,
                                                                                        {clauses,
                                                                                         parent_alias,
                                                                                         aliases} ->
        join_alias = available_join_alias(edge.association_id, aliases)

        join_clause = [
          " INNER JOIN ",
          edge.target_relation.source_table,
          " ",
          join_alias,
          " ON ",
          edge_correlation(selecto, edge, join_alias, parent_alias)
        ]

        {clauses ++ [join_clause], join_alias, [join_alias | aliases]}
      end)

    # Bind the selected row through the final association itself. An internal
    # target row with the same primary key does not establish path membership.
    end_correlation = edge_correlation(selecto, final_edge, target_alias, parent_alias)
    {join_clauses, start_correlation, end_correlation}
  end

  defp available_join_alias(association_id, aliases) do
    base_alias = "j_#{association_id}"
    occupied_aliases = MapSet.new(aliases, &String.downcase/1)

    Enum.find_value(0..length(aliases), fn index ->
      candidate = if index == 0, do: base_alias, else: "#{base_alias}_#{index}"
      if MapSet.member?(occupied_aliases, String.downcase(candidate)), do: nil, else: candidate
    end)
  end

  defp edge_correlation(selecto, edge, target_alias, source_alias) do
    build_association_correlation_condition(
      selecto,
      edge.association_id,
      edge.association,
      edge.source_relation,
      edge.target_relation,
      target_alias,
      source_alias
    )
  end

  defp validate_correlation_target(selecto, actual_schema, target_schema) do
    actual_relation = get_target_schema_config(selecto, actual_schema)
    target_relation = get_target_schema_config(selecto, target_schema)

    if actual_relation.source_table == target_relation.source_table do
      :ok
    else
      {:error,
       "Join path terminates at #{actual_schema}, which does not match target schema #{target_schema}"}
    end
  end

  defp ensure_correlation_target!(selecto, actual_schema, target_schema) do
    case validate_correlation_target(selecto, actual_schema, target_schema) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp build_subquery_select_fields(selecto, subselect_config, target_alias) do
    case subselect_config.format do
      :json_agg ->
        build_json_select_fields(selecto, subselect_config.fields, target_alias)

      :count ->
        # For count, we just need any field
        {["1"], []}

      _ ->
        build_simple_select_fields(selecto, subselect_config.fields, target_alias)
    end
  end

  defp build_json_select_fields(selecto, fields, target_alias) do
    case fields do
      [single_field] ->
        # Single field - return the value directly for json_agg
        field_name = adapter_quote_identifier(selecto, to_string(single_field))
        {[target_alias, ".", field_name], []}

      multiple_fields ->
        # Multiple fields - build JSON object
        json_pairs =
          Enum.map(multiple_fields, fn field ->
            field_name = adapter_quote_identifier(selecto, to_string(field))
            # Use literal string for field key, not parameter
            field_key = escape_string(to_string(field))
            [field_key, ", ", target_alias, ".", field_name]
          end)

        render_json_object!(selecto, json_pairs)
    end
  end

  defp build_simple_select_fields(selecto, fields, target_alias) do
    field_clauses =
      Enum.map(fields, fn field ->
        field_name = adapter_quote_identifier(selecto, to_string(field))
        [target_alias, ".", field_name]
      end)

    select_clause =
      case field_clauses do
        [single] -> single
        multiple -> Enum.intersperse(multiple, [", "])
      end

    {select_clause, []}
  end

  defp build_correlation_condition(selecto, subselect_config, _target_alias, source_alias) do
    case resolve_join_condition_with_path(
           selecto,
           subselect_config.target_schema,
           source_alias,
           Map.get(subselect_config, :join_path)
         ) do
      {:ok, condition_sql} ->
        {condition_sql, []}

      {:error, reason} ->
        # This should not happen if domain is properly configured
        # Raise an error instead of using an incorrect fallback
        raise ArgumentError, "Cannot build correlation condition for subselect: #{reason}"
    end
  end

  defp build_additional_filters(selecto, subselect_config, target_alias) do
    case Map.get(subselect_config, :filters, []) do
      [] ->
        {[], []}

      filters ->
        # Build WHERE conditions for additional filters
        build_filter_conditions(selecto, filters, target_alias)
    end
  end

  defp build_subquery_order_by(selecto, subselect_config, target_alias) do
    case stable_collection_order(selecto, subselect_config) do
      [] ->
        {[], []}

      order_specs ->
        order_clauses =
          Enum.map(order_specs, fn
            {direction, field} ->
              field_name = adapter_quote_identifier(selecto, to_string(field))

              direction_sql =
                case direction do
                  :asc -> "ASC"
                  :desc -> "DESC"
                  _ -> "ASC"
                end

              [target_alias, ".", field_name, " ", direction_sql]

            field when is_atom(field) ->
              field_name = adapter_quote_identifier(selecto, to_string(field))
              [target_alias, ".", field_name]

            field when is_binary(field) ->
              field_name = adapter_quote_identifier(selecto, field)
              [target_alias, ".", field_name]
          end)

        order_clause = Enum.intersperse(order_clauses, [", "])
        {order_clause, []}
    end
  end

  defp stable_collection_order(selecto, config) do
    orders = Map.get(config, :order_by, [])

    if Map.get(config, :limit) do
      primary_key = get_target_schema_config(selecto, config.target_schema).primary_key

      if not (is_atom(primary_key) or is_binary(primary_key)) do
        raise ArgumentError, "per-parent collection limit requires a target primary key"
      end

      if Enum.any?(orders, fn
           {_direction, field} -> to_string(field) == to_string(primary_key)
           field -> to_string(field) == to_string(primary_key)
         end) do
        orders
      else
        orders ++ [{:asc, primary_key}]
      end
    else
      orders
    end
  end

  defp root_parent_primary_key(selecto) do
    Map.fetch!(selecto.domain.source, :primary_key)
  end

  defp build_collection_cursor_condition(selecto, config, child_alias, parent_alias, parent_key) do
    case Map.get(config, :after) do
      nil ->
        {[], []}

      cursor ->
        do_build_collection_cursor_condition(
          selecto,
          config,
          child_alias,
          parent_alias,
          parent_key,
          cursor
        )
    end
  end

  defp do_build_collection_cursor_condition(
         selecto,
         config,
         child_alias,
         parent_alias,
         parent_key,
         %{parent_key: parent_value, values: values}
       ) do
    orders = stable_collection_order(selecto, config)

    order_columns =
      Enum.map(orders, fn
        {direction, field} ->
          {[child_alias, ".", adapter_quote_identifier(selecto, to_string(field))], direction}

        field ->
          {[child_alias, ".", adapter_quote_identifier(selecto, to_string(field))], :asc}
      end)

    seek_terms =
      order_columns
      |> Enum.with_index()
      |> Enum.map(fn {{column, direction}, index} ->
        prefix =
          order_columns
          |> Enum.take(index)
          |> Enum.zip(Enum.take(values, index))
          |> Enum.map(fn {{prior_column, _}, prior_value} ->
            if is_nil(prior_value) do
              [prior_column, " IS NULL"]
            else
              [prior_column, " IS NOT DISTINCT FROM ", {:param, prior_value}]
            end
          end)

        comparison = cursor_after_comparison(column, direction, Enum.at(values, index))

        ["(", Enum.intersperse(prefix ++ [comparison], " AND "), ")"]
      end)

    parent_column = [parent_alias, ".", adapter_quote_identifier(selecto, to_string(parent_key))]

    clause = [
      "(",
      parent_column,
      " IS DISTINCT FROM ",
      {:param, parent_value},
      " OR (",
      Enum.intersperse(seek_terms, " OR "),
      "))"
    ]

    {clause, extract_params(clause)}
  end

  # PostgreSQL places NULL last for ASC and first for DESC by default.
  defp cursor_after_comparison(_column, :asc, nil), do: "FALSE"
  defp cursor_after_comparison(column, :desc, nil), do: [column, " IS NOT NULL"]

  defp cursor_after_comparison(column, :asc, value),
    do: ["(", column, " > ", {:param, value}, " OR ", column, " IS NULL)"]

  defp cursor_after_comparison(column, :desc, value),
    do: [column, " < ", {:param, value}]

  defp build_filter_conditions(selecto, filters, target_alias) do
    # Use existing filter building logic, adapted for subquery context
    # This is simplified - in reality, we'd reuse Selecto.Builder.Sql.Where logic
    condition_clauses =
      Enum.map(filters, fn
        {field, value} ->
          field_name = adapter_quote_identifier(selecto, to_string(field))
          value_param = {:param, value}
          [target_alias, ".", field_name, " = ", value_param]
      end)

    condition_sql =
      case condition_clauses do
        [] ->
          {[], []}

        [single] ->
          {single, extract_params(single)}

        multiple ->
          combined = Enum.intersperse(multiple, [" AND "])
          {combined, extract_params(combined)}
      end

    condition_sql
  end

  defp get_target_table(selecto, target_schema) do
    case Map.get(selecto.domain.schemas, target_schema) do
      nil -> raise ArgumentError, "Target schema #{target_schema} not found"
      schema_config -> schema_config.source_table
    end
  end

  defp get_target_schema_config(selecto, target_schema) do
    case Map.get(selecto.domain.schemas, target_schema) do
      nil -> raise ArgumentError, "Target schema #{target_schema} not found"
      schema_config -> schema_config
    end
  end

  defp generate_subquery_alias(target_schema) do
    "sub_" <> to_string(target_schema)
  end

  defp get_connection_fields(selecto, _target_schema, join_path) do
    # Determine the fields that connect the main query to the subquery target
    # This is a simplified implementation - needs refinement based on actual join path
    case join_path do
      [] ->
        # Direct relationship
        # Simplified assumption
        {"id", "parent_id"}

      [first_join | _rest] ->
        # Get the association configuration for the first join
        association = get_association_config(selecto, first_join)
        source_field = to_string(association.owner_key)
        target_field = to_string(association.related_key)
        {source_field, target_field}
    end
  end

  defp get_association_config(selecto, join_name) do
    # Look up association configuration
    case Map.get(selecto.domain.source.associations, join_name) do
      nil ->
        # Look in schemas
        Enum.find_value(selecto.domain.schemas, fn {_name, schema} ->
          Map.get(schema.associations, join_name)
        end) || raise ArgumentError, "Association #{join_name} not found"

      assoc ->
        assoc
    end
  end

  defp extract_params(iodata) when is_list(iodata) do
    # Extract parameter values from iodata structure
    Enum.flat_map(iodata, fn
      {:param, value} -> [value]
      item when is_list(item) -> extract_params(item)
      _ -> []
    end)
  end

  defp extract_params(_), do: []

  defp escape_string(string) do
    # Escape SQL string literals
    "'#{String.replace(string, "'", "''")}'"
  end

  defp adapter_quote_identifier(selecto, identifier) do
    adapter = Map.fetch!(selecto, :adapter)

    if Selecto.AdapterSupport.callback_available?(adapter, :quote_identifier, 1) do
      adapter.quote_identifier(to_string(identifier))
    else
      quote_identifier(selecto, identifier)
    end
  end
end
