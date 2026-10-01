defmodule Selecto.Subselect do
  @moduledoc """
  Subselect functionality for array-based data aggregation from related tables.

  The Subselect feature enables returning related data as arrays or JSON objects,
  preventing result set denormalization while maintaining relational context.

  ## Examples

      # Basic subselect - get orders as JSON array for each attendee
      selecto
      |> Selecto.select(["attendee.name"])
      |> Selecto.subselect([
           "order.product_name", 
           "order.quantity"
         ])
      |> Selecto.filter([{"event_id", 123}])

      # This generates SQL like:
      # SELECT 
      #   a.name,
      #   (SELECT json_agg(json_build_object(
      #     'product_name', o.product_name,
      #     'quantity', o.quantity
      #   )) FROM orders o WHERE o.attendee_id = a.attendee_id) as orders
      # FROM attendees a
      # WHERE a.event_id = 123

  ## Aggregation Formats

  - `:json_agg` - Returns JSON array of objects (default)
  - `:array_agg` - Returns a collection value when supported by the adapter
  - `:string_agg` - Returns delimited string
  - `:count` - Returns count of related records
  - `:sum` - Returns a zero-filled sum of one related numeric field
  """

  alias Selecto.Types

  @doc """
  Add subselect fields to return related data as aggregated arrays.

  ## Parameters

  - `selecto` - The Selecto struct
  - `field_specs` - List of field specifications with optional configuration
  - `opts` - Global options for subselects

  ## Field Specification Formats

      # Simple field list (uses defaults)
      ["order.product_name", "order.quantity"]

      # With custom configuration
      [
        %{
          fields: ["product_name", "quantity"],
          target_schema: :order,
          format: :json_agg,
          alias: "order_items"
        }
      ]

  ## Options

  - `:format` - Default aggregation format (`:json_agg`, `:array_agg`, `:string_agg`, `:count`)
  - `:alias_prefix` - Prefix for generated field aliases
  - `:order_by` - Default ordering for aggregated results
  - `:limit` - Per-parent JSON collection limit; requires explicit ordering and
    the PostgreSQL adapter
  - `:after` - Optional parent-bound keyset position, `%{parent_key: value,
    values: [...]}`. The values contain the complete ordering tuple, including
    the target primary-key tie breaker. The caller must reauthorize the parent
    and bind the cursor to its source/filter/release context.

  ## Returns

  Updated Selecto struct with subselect configuration applied.
  """
  @spec subselect(Types.t(), [String.t() | Types.subselect_selector()], keyword()) :: Types.t()
  def subselect(selecto, field_specs, opts \\ []) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :subselect)
    subselect_configs = normalize_field_specs(field_specs, opts)

    # Validate all subselect configurations
    Enum.each(subselect_configs, &validate_subselect_config(selecto, &1))

    # Add to selecto state
    current_subselects = Map.get(selecto.set, :subselected, [])
    updated_subselects = current_subselects ++ subselect_configs

    put_in(selecto.set[:subselected], updated_subselects)
  end

  @doc """
  Validate that a subselect configuration is valid for the given domain.
  """
  @spec validate_subselect_config(Types.t(), Types.subselect_selector()) ::
          :ok | {:error, String.t()}
  def validate_subselect_config(selecto, subselect_config) do
    with :ok <- validate_target_schema(selecto, subselect_config.target_schema),
         :ok <- validate_fields_exist(selecto, subselect_config),
         :ok <- validate_filters_exist(selecto, subselect_config),
         :ok <- validate_sum_config(selecto, subselect_config),
         :ok <- validate_collection_limit(subselect_config),
         :ok <- validate_collection_cursor(selecto, subselect_config),
         :ok <- validate_relationship_path(selecto, subselect_config) do
      Enum.each(Map.get(subselect_config, :nested, []), fn nested ->
        validate_subselect_config(selecto, normalize_config_map(nested, :json_agg, "", []))
      end)

      :ok
    else
      {:error, reason} -> raise ArgumentError, "Invalid subselect configuration: #{reason}"
    end
  end

  @doc """
  Group subselects by their target table for efficient SQL generation.
  """
  @spec group_subselects_by_table(Types.t()) :: %{atom() => [Types.subselect_selector()]}
  def group_subselects_by_table(selecto) do
    subselects = Map.get(selecto.set, :subselected, [])

    Enum.group_by(subselects, fn config ->
      config.target_schema
    end)
  end

  @doc """
  Check if a Selecto query has subselect configuration applied.
  """
  @spec has_subselects?(Types.t()) :: boolean()
  def has_subselects?(selecto) do
    subselects = Map.get(selecto.set, :subselected, [])
    length(subselects) > 0
  end

  @doc """
  Get all subselect configurations from a Selecto query.
  """
  @spec get_subselect_configs(Types.t()) :: [Types.subselect_selector()]
  def get_subselect_configs(selecto) do
    Map.get(selecto.set, :subselected, [])
  end

  @doc """
  Clear all subselect configurations from a Selecto query.
  """
  @spec clear_subselects(Types.t()) :: Types.t()
  def clear_subselects(selecto) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :clear_subselects)
    updated_set = Map.delete(selecto.set, :subselected)
    %{selecto | set: updated_set}
  end

  @doc """
  Resolve the join path needed to reach a target schema from the query root.

  A retargeted query is rooted at its target, so the path starts there.
  """
  @spec resolve_join_path(Types.t(), atom()) :: {:ok, [atom()]} | {:error, String.t()}
  def resolve_join_path(selecto, target_schema) do
    Selecto.Retarget.calculate_join_path(selecto, target_schema)
  end

  # Private helper functions

  defp normalize_field_specs(field_specs, opts) do
    default_format = Keyword.get(opts, :format, :json_agg)
    alias_prefix = Keyword.get(opts, :alias_prefix, "")
    default_order_by = Keyword.get(opts, :order_by, [])

    Enum.map(field_specs, fn spec ->
      case spec do
        field when is_binary(field) ->
          parse_field_string(field, default_format, alias_prefix, default_order_by)

        %{} = config ->
          normalize_config_map(config, default_format, alias_prefix, default_order_by)

        _ ->
          raise ArgumentError, "Invalid field specification: #{inspect(spec)}"
      end
    end)
  end

  defp parse_field_string(field_string, default_format, alias_prefix, default_order_by) do
    # Parse dot notation: "table.field" or "table.field1,field2"
    cond do
      match = Regex.run(~r/^([^.]+)\.([^.]+(?:\s*,\s*[^.]+)*)$/, field_string) ->
        [_, table_part, field_part] = match
        target_schema = normalize_schema_reference(table_part)
        fields = String.split(field_part, ",") |> Enum.map(&String.trim/1)

        %{
          fields: fields,
          target_schema: target_schema,
          format: default_format,
          alias: generate_alias(target_schema, alias_prefix),
          order_by: default_order_by,
          filters: []
        }

      true ->
        raise ArgumentError,
              "Invalid field format: #{field_string}. Expected 'table.field' or 'table.field1,field2' format."
    end
  end

  defp normalize_config_map(config, default_format, alias_prefix, default_order_by) do
    %{
      fields: Map.fetch!(config, :fields),
      target_schema: Map.fetch!(config, :target_schema),
      format: Map.get(config, :format, default_format),
      alias: Map.get(config, :alias, generate_alias(config.target_schema, alias_prefix)),
      join_path: Map.get(config, :join_path),
      nested: Map.get(config, :nested, []),
      separator: Map.get(config, :separator, ","),
      order_by: Map.get(config, :order_by, default_order_by),
      limit: Map.get(config, :limit),
      after: Map.get(config, :after),
      filters: Map.get(config, :filters, [])
    }
  end

  defp validate_collection_limit(config) do
    case Map.get(config, :limit) do
      nil ->
        :ok

      limit
      when is_integer(limit) and limit > 0 and
             config.format == :json_agg ->
        if Map.get(config, :order_by, []) != [] do
          :ok
        else
          {:error, "per-parent collection limit requires explicit ordering"}
        end

      _ ->
        {:error, "per-parent collection limit requires a positive JSON aggregation limit"}
    end
  end

  defp validate_collection_cursor(selecto, config) do
    case Map.get(config, :after) do
      nil ->
        :ok

      %{parent_key: parent_key, values: values} = cursor
      when map_size(cursor) == 2 and not is_nil(parent_key) and is_list(values) ->
        orders = Map.get(config, :order_by, [])
        schema = fetch_schema_config(selecto.domain.schemas, config.target_schema)
        primary_key = Map.get(schema, :primary_key)

        cond do
          is_nil(Map.get(config, :limit)) ->
            {:error, "per-parent collection cursor requires a positive limit"}

          not (is_integer(parent_key) or is_binary(parent_key)) ->
            {:error, "per-parent collection cursor requires a scalar parent key"}

          not valid_cursor_order?(orders, schema.fields) or is_nil(primary_key) ->
            {:error, "per-parent collection cursor requires valid ordering"}

          length(values) != stable_cursor_order_size(orders, primary_key) ->
            {:error, "per-parent collection cursor has the wrong ordering tuple size"}

          not Enum.all?(values, &cursor_value?/1) ->
            {:error, "per-parent collection cursor has an invalid ordering value"}

          true ->
            :ok
        end

      _ ->
        {:error, "per-parent collection cursor requires a parent key and ordering values"}
    end
  end

  defp valid_cursor_order?(orders, fields) when is_list(orders) and orders != [] do
    Enum.all?(orders, fn
      {direction, field}
      when direction in [:asc, :desc] and (is_atom(field) or is_binary(field)) ->
        Enum.any?(fields, &(to_string(&1) == to_string(field)))

      field when is_atom(field) or is_binary(field) ->
        Enum.any?(fields, &(to_string(&1) == to_string(field)))

      _ ->
        false
    end)
  end

  defp valid_cursor_order?(_orders, _fields), do: false

  defp stable_cursor_order_size(orders, primary_key) do
    length(orders) +
      if Enum.any?(orders, fn
           {_direction, field} -> to_string(field) == to_string(primary_key)
           field -> to_string(field) == to_string(primary_key)
         end) do
        0
      else
        1
      end
  end

  defp cursor_value?(value),
    do:
      is_nil(value) or is_number(value) or is_binary(value) or is_boolean(value) or
        is_struct(value)

  defp validate_sum_config(selecto, %{format: :sum, fields: fields} = config) do
    if length(fields) != 1 or Map.get(config, :nested, []) != [] do
      {:error, "related sum requires exactly one field and no nested collections"}
    else
      [field] = fields
      schema = fetch_schema_config(selecto.domain.schemas, config.target_schema)

      column =
        Enum.find_value(Map.get(schema, :columns, %{}), fn {name, metadata} ->
          if to_string(name) == to_string(field), do: metadata
        end)

      type = column && (Map.get(column, :type) || Map.get(column, "type"))

      if type in [
           :integer,
           :decimal,
           :float,
           :number,
           :numeric,
           "integer",
           "decimal",
           "float",
           "number",
           "numeric"
         ] do
        :ok
      else
        {:error, "related sum requires a numeric field"}
      end
    end
  end

  defp validate_sum_config(_selecto, _config), do: :ok

  defp generate_alias(target_schema, prefix) do
    base_name = to_string(target_schema)
    if prefix != "", do: "#{prefix}_#{base_name}", else: base_name
  end

  defp validate_target_schema(selecto, target_schema) do
    case fetch_schema_config(selecto.domain.schemas, target_schema) do
      nil -> {:error, "Target schema #{target_schema} not found in domain"}
      _ -> :ok
    end
  end

  defp validate_fields_exist(selecto, subselect_config) do
    target_schema_config =
      fetch_schema_config(selecto.domain.schemas, subselect_config.target_schema)

    invalid_fields =
      Enum.filter(subselect_config.fields, fn field_name ->
        field_name_string = to_string(field_name)

        case Selecto.Json.parse_field_reference(field_name_string, target_schema_config) do
          {:json_path, _column, _path} ->
            false

          {:regular, _} ->
            not Enum.any?(target_schema_config.fields, fn existing_field ->
              to_string(existing_field) == field_name_string
            end)
        end
      end)

    case invalid_fields do
      [] ->
        :ok

      fields ->
        {:error,
         "Fields #{inspect(fields)} not found in schema #{subselect_config.target_schema}"}
    end
  end

  defp validate_filters_exist(selecto, subselect_config) do
    target_schema_config =
      fetch_schema_config(selecto.domain.schemas, subselect_config.target_schema)

    filters = Map.get(subselect_config, :filters, [])

    invalid? =
      not is_list(filters) or
        Enum.any?(filters, fn
          {field, _value} when is_binary(field) or is_atom(field) ->
            field = to_string(field)
            not Enum.any?(target_schema_config.fields, &(to_string(&1) == field))

          _ ->
            true
        end)

    if invalid?, do: {:error, "Subselect filters are invalid"}, else: :ok
  end

  defp validate_relationship_path(selecto, subselect_config) do
    case Map.get(subselect_config, :join_path) do
      join_path when is_list(join_path) and join_path != [] ->
        Selecto.Retarget.validate_retarget_path(selecto, join_path)

      _ ->
        case resolve_join_path(selecto, subselect_config.target_schema) do
          {:ok, _path} -> :ok
          {:error, reason} -> {:error, "Cannot reach target schema: #{reason}"}
        end
    end
  end

  defp normalize_schema_reference(schema) when is_atom(schema), do: schema

  defp normalize_schema_reference(schema) when is_binary(schema) do
    try do
      String.to_existing_atom(schema)
    rescue
      ArgumentError -> schema
    end
  end

  defp fetch_schema_config(schemas, schema_key) when is_map(schemas) do
    normalized_key = normalize_schema_reference(to_string(schema_key))
    Map.get(schemas, schema_key) || Map.get(schemas, normalized_key)
  end
end
