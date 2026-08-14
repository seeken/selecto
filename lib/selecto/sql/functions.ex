defmodule Selecto.SQL.Functions do
  @moduledoc """
  Advanced SQL function support for Selecto.

  This module extends the existing function support in Selecto.Builder.Sql.Select
  with additional advanced SQL functions including window functions, array operations,
  string manipulation, and mathematical functions.

  ## Function Categories

  ### String Functions
  - `substr/3` - Extract substring
  - `trim/1`, `ltrim/1`, `rtrim/1` - String trimming
  - `upper/1`, `lower/1` - Case conversion
  - `length/1` - String length
  - `position/2` - Find substring position
  - `replace/3` - String replacement

  ### Mathematical Functions
  - `abs/1` - Absolute value
  - `ceil/1`, `floor/1` - Rounding functions
  - `round/1`, `round/2` - Rounding with precision
  - `power/2` - Exponentiation
  - `sqrt/1` - Square root
  - `mod/2` - Modulo operation
  - `random/0` - Random number generation

  ### Date/Time Functions
  - `now/0` - Current timestamp
  - `date_trunc/2` - Truncate to date part
  - `interval/1` - Time intervals
  - `age/1`, `age/2` - Date arithmetic
  - `date_part/2` - Enhanced extract functionality

  ### Array Functions
  - `array_agg/1` - Array aggregation
  - `array_length/1` - Array length
  - `array_to_string/2` - Array to string conversion
  - `string_to_array/2` - String to array conversion
  - `unnest/1` - Array expansion
  - `array_cat/2` - Array concatenation

  ### Window Functions
  - `row_number/0` - Row numbering
  - `rank/0` - Ranking with gaps
  - `dense_rank/0` - Dense ranking
  - `lag/1`, `lag/2` - Previous row values
  - `lead/1`, `lead/2` - Next row values
  - `first_value/1`, `last_value/1` - Window boundaries
  - `ntile/1` - Percentile groups

  ### Conditional Functions
  - Enhanced `case` expressions
  - `decode/3+` - Oracle-style conditional
  - `iif/3` - Simple if-then-else

  ## Usage Examples

      # String functions
      {:substr, "description", 1, 50}
      {:trim, "name"}
      {:upper, "category"}

      # Math functions
      {:round, "price", 2}
      {:power, "base", 2}

      # Window functions
      {:window, {:row_number}, over: [partition_by: ["category"], order_by: ["price"]]}
      {:window, {:lag, "price"}, over: [partition_by: ["product_id"], order_by: ["date"]]}

      # Array functions
      {:array_agg, "tag_name", over: [partition_by: ["product_id"]]}
      {:unnest, "tags"}
  """

  alias Selecto.Dialect.Collection.Operation, as: CollectionOperation
  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation
  alias Selecto.Dialect.Json.Operation, as: JsonOperation

  @doc """
  Process advanced SQL functions that extend beyond the basic set.

  This integrates with the existing prep_selector in Selecto.Builder.Sql.Select
  to provide comprehensive function support.
  """
  def prep_advanced_selector(selecto, selector) do
    case selector do
      # String Functions
      {:substr, field, start, length} ->
        prep_string_function(selecto, "substr", [field, {:literal, start}, {:literal, length}])

      {:substr, field, start} ->
        prep_string_function(selecto, "substr", [field, {:literal, start}])

      {:trim, field} ->
        prep_string_function(selecto, "trim", [field])

      {:ltrim, field} ->
        prep_string_function(selecto, "ltrim", [field])

      {:rtrim, field} ->
        prep_string_function(selecto, "rtrim", [field])

      {:upper, field} ->
        prep_string_function(selecto, "upper", [field])

      {:lower, field} ->
        prep_string_function(selecto, "lower", [field])

      {:length, field} ->
        prep_string_function(selecto, "length", [field])

      {:position, substring, string} ->
        prep_position_function(selecto, substring, string)

      {:replace, field, old, new} ->
        prep_string_function(selecto, "replace", [field, old, new])

      # Mathematical Functions
      {:abs, field} ->
        prep_math_function(selecto, "abs", [field])

      {:ceil, field} ->
        prep_math_function(selecto, "ceil", [field])

      {:floor, field} ->
        prep_math_function(selecto, "floor", [field])

      {:round, field} ->
        prep_math_function(selecto, "round", [field])

      {:round, field, precision} ->
        prep_math_function(selecto, "round", [field, {:literal, precision}])

      {:power, base, exponent} ->
        prep_math_function(selecto, "power", [base, exponent])

      {:sqrt, field} ->
        prep_math_function(selecto, "sqrt", [field])

      {:mod, dividend, divisor} ->
        prep_math_function(selecto, "mod", [dividend, divisor])

      {:random} ->
        prep_math_function(selecto, "random", [])

      # Date/Time Functions
      {:now} ->
        prep_datetime_operation(selecto, :current_timestamp, [])

      {:date_trunc, part, field} ->
        prep_datetime_operation(selecto, :truncate, [field], part: part)

      {:interval, spec} ->
        prep_interval(selecto, spec)

      {:age, field} ->
        prep_datetime_operation(selecto, :age, [field])

      {:age, field1, field2} ->
        prep_datetime_operation(selecto, :age, [field1, field2])

      {:date_part, part, field} ->
        prep_datetime_operation(selecto, :extract_part, [field], part: part)

      # Array Functions
      {:array_agg, field} ->
        prep_collection_operation(selecto, :array_agg, field)

      {:array_agg, field, opts} when is_list(opts) ->
        prep_collection_aggregate(selecto, :array_agg, field, opts)

      # String aggregation - 2 argument version
      {:string_agg, field, delimiter} ->
        prep_collection_aggregate(selecto, :string_agg, field, delimiter: delimiter)

      {:string_agg, field, delimiter, opts} when is_list(opts) ->
        prep_collection_aggregate(
          selecto,
          :string_agg,
          field,
          Keyword.put(opts, :delimiter, delimiter)
        )

      # JSON object aggregation - 2 argument version
      {:json_object_agg, key_field, value_field} ->
        prep_json_object_aggregate(selecto, key_field, value_field)

      # JSON array aggregation
      {:json_agg, field} ->
        prep_json_aggregate(selecto, field)

      # GROUPING function for ROLLUP/CUBE queries
      {:grouping, fields} when is_list(fields) ->
        prep_grouping_function(selecto, fields)

      {:grouping, field} ->
        prep_grouping_function(selecto, [field])

      {:array_length, field} ->
        prep_collection_operation(selecto, :array_length, field, dimension: 1)

      {:array_to_string, field, delimiter} ->
        prep_collection_operation(selecto, :array_to_string, field,
          value: literal_value(delimiter)
        )

      {:string_to_array, field, delimiter} ->
        prep_collection_operation(selecto, :string_to_array, field,
          value: literal_value(delimiter)
        )

      {:unnest, field} ->
        prep_collection_operation(selecto, :unnest, field)

      {:array_cat, array1, array2} ->
        prep_collection_expression_operation(selecto, :array_cat, array1, array2)

      # Additional array functions
      {:cardinality, field} ->
        prep_collection_operation(selecto, :cardinality, field)

      {:array_ndims, field} ->
        prep_collection_operation(selecto, :array_ndims, field)

      {:array_dims, field} ->
        prep_collection_operation(selecto, :array_dims, field)

      {:array_append, array, element} ->
        prep_collection_operation(selecto, :array_append, array, value: literal_value(element))

      {:array_prepend, element, array} ->
        prep_collection_operation(selecto, :array_prepend, array, value: literal_value(element))

      {:array_fill, value, dimensions} ->
        prep_collection_operation(selecto, :array_fill, nil,
          value: literal_value(value),
          options: %{dimensions: literal_value(dimensions)}
        )

      {:array_remove, array, element} ->
        prep_collection_operation(selecto, :array_remove, array, value: literal_value(element))

      {:array_replace, array, from_elem, to_elem} ->
        prep_collection_operation(selecto, :array_replace, array,
          value: literal_value(from_elem),
          options: %{new_value: literal_value(to_elem)}
        )

      {:array_position, array, element} ->
        prep_collection_operation(selecto, :array_position, array, value: literal_value(element))

      {:array_position, array, element, start} ->
        prep_collection_operation(selecto, :array_position, array,
          value: literal_value(element),
          options: %{start: literal_value(start)}
        )

      {:array_positions, array, element} ->
        prep_collection_operation(selecto, :array_positions, array, value: literal_value(element))

      # Window Functions
      {:window, func, opts} ->
        prep_window_function(selecto, func, opts)

      # Enhanced Conditional Functions
      {:decode, field, mappings} ->
        prep_decode_function(selecto, field, mappings)

      {:iif, condition, true_value, false_value} ->
        prep_iif_function(selecto, condition, true_value, false_value)

      # Fallback to existing prep_selector for standard functions
      _ ->
        nil
    end
  end

  # String function helpers
  defp prep_string_function(selecto, func_name, args) do
    {sel_parts, joins, params} = prep_function_args(selecto, args)
    func_iodata = [func_name, "(", Enum.intersperse(sel_parts, ", "), ")"]
    {func_iodata, joins, params}
  end

  defp prep_position_function(selecto, substring, string) do
    {substring_iodata, substring_joins, substring_params} = prep_single_arg(selecto, substring)
    {string_iodata, string_joins, string_params} = prep_single_arg(selecto, string)

    {[
       "position(",
       substring_iodata,
       " in ",
       string_iodata,
       ")"
     ], List.wrap(substring_joins) ++ List.wrap(string_joins), substring_params ++ string_params}
  end

  # Math function helpers
  defp prep_math_function(selecto, func_name, args) do
    {sel_parts, joins, params} = prep_function_args(selecto, args)
    func_iodata = [func_name, "(", Enum.intersperse(sel_parts, ", "), ")"]
    {func_iodata, joins, params}
  end

  # Date/time operation helpers
  defp prep_datetime_operation(selecto, operation, args, opts \\ []) do
    {expressions, joins, params} = prep_function_args(selecto, args)

    part =
      case Keyword.fetch(opts, :part) do
        :error -> nil
        {:ok, raw_part} -> normalize_datetime_part!(raw_part)
      end

    fragment = %DateTimeOperation{
      operation: operation,
      clause: :select,
      expression: Enum.at(expressions, 0),
      second_expression: Enum.at(expressions, 1),
      part: part
    }

    render_dialect_fragment(
      Selecto.DialectSupport.render_datetime_operation(selecto.adapter, fragment, selecto),
      joins,
      params
    )
  end

  defp normalize_datetime_part!(part) do
    case DateTimeOperation.normalize_part(part) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, "invalid datetime part: #{inspect(reason)}"
    end
  end

  # Collection and JSON helpers construct finite core fragments. The configured
  # adapter dialect owns the concrete function names, operators, and placeholder
  # additions for those fragments.
  defp prep_collection_operation(selecto, operation, field, attrs \\ []) do
    {column, joins, params} = prep_optional_arg(selecto, field)

    fragment =
      struct!(CollectionOperation, %{
        operation: operation,
        clause: :select,
        column: column,
        dimension: Keyword.get(attrs, :dimension),
        value: Keyword.get(attrs, :value),
        distinct: Keyword.get(attrs, :distinct, false),
        order_by: Keyword.get(attrs, :order_by, []),
        options: Keyword.get(attrs, :options, %{})
      })

    render_dialect_fragment(
      Selecto.DialectSupport.render_collection_operation(selecto.adapter, fragment, selecto),
      joins,
      params
    )
  end

  defp prep_collection_expression_operation(selecto, operation, field, value_expression) do
    {column, column_joins, column_params} = prep_single_arg(selecto, field)
    {value_sql, value_joins, value_params} = prep_single_arg(selecto, value_expression)

    fragment = %CollectionOperation{
      operation: operation,
      clause: :select,
      column: column,
      order_by: [],
      options: %{value_expression: value_sql}
    }

    render_dialect_fragment(
      Selecto.DialectSupport.render_collection_operation(selecto.adapter, fragment, selecto),
      List.wrap(column_joins) ++ List.wrap(value_joins),
      column_params ++ value_params
    )
  end

  defp prep_collection_aggregate(selecto, operation, field, opts) do
    {column, column_joins, column_params} = prep_single_arg(selecto, field)
    {order_by, order_joins, order_params} = prep_aggregate_order(selecto, opts[:order_by])

    options =
      case Keyword.fetch(opts, :delimiter) do
        {:ok, delimiter} -> %{delimiter: literal_value(delimiter)}
        :error -> %{}
      end

    fragment = %CollectionOperation{
      operation: operation,
      clause: :select,
      column: column,
      distinct: Keyword.get(opts, :distinct, false),
      order_by: order_by,
      options: options
    }

    render_dialect_fragment(
      Selecto.DialectSupport.render_collection_operation(selecto.adapter, fragment, selecto),
      List.wrap(column_joins) ++ order_joins,
      column_params ++ order_params
    )
  end

  defp prep_json_aggregate(selecto, field) do
    {column, joins, params} = prep_single_arg(selecto, field)

    fragment = %JsonOperation{
      operation: :json_agg,
      clause: :select,
      column: nil,
      options: %{column_sql: column}
    }

    render_dialect_fragment(
      Selecto.DialectSupport.render_json(
        selecto.adapter,
        :render_json_operation,
        fragment,
        selecto
      ),
      joins,
      params
    )
  end

  defp prep_json_object_aggregate(selecto, key_field, value_field) do
    {key_sql, key_joins, key_params} = prep_single_arg(selecto, key_field)
    {value_sql, value_joins, value_params} = prep_single_arg(selecto, value_field)

    fragment = %JsonOperation{
      operation: :json_object_agg,
      clause: :select,
      key_field: nil,
      value_field: nil,
      options: %{key_sql: key_sql, value_sql: value_sql}
    }

    render_dialect_fragment(
      Selecto.DialectSupport.render_json(
        selecto.adapter,
        :render_json_operation,
        fragment,
        selecto
      ),
      List.wrap(key_joins) ++ List.wrap(value_joins),
      key_params ++ value_params
    )
  end

  defp prep_aggregate_order(_selecto, nil), do: {[], [], []}

  defp prep_aggregate_order(selecto, order_by) do
    order_by
    |> List.wrap()
    |> Enum.reduce({[], [], []}, fn order, {parts, joins, params} ->
      {field, direction} = normalize_aggregate_order(order)
      {field_sql, field_joins, field_params} = prep_single_arg(selecto, field)

      {
        parts ++ [{field_sql, direction}],
        joins ++ List.wrap(field_joins),
        params ++ field_params
      }
    end)
  end

  defp normalize_aggregate_order({field, direction}) when direction in [:asc, :desc],
    do: {field, direction}

  defp normalize_aggregate_order(field), do: {field, :asc}

  defp prep_optional_arg(_selecto, nil), do: {nil, [], []}
  defp prep_optional_arg(selecto, field), do: prep_single_arg(selecto, field)

  defp render_dialect_fragment({:ok, {iodata, dialect_params}}, joins, params),
    do: {iodata, List.wrap(joins), params ++ dialect_params}

  defp render_dialect_fragment({:ok, iodata}, joins, params),
    do: {iodata, List.wrap(joins), params}

  defp render_dialect_fragment({:error, %Selecto.Error{} = error}, _joins, _params),
    do: raise(Selecto.Error.to_exception(error))

  defp render_dialect_fragment({:error, reason}, _joins, _params),
    do: raise(ArgumentError, "unsupported dialect fragment: #{inspect(reason)}")

  defp literal_value({:literal, value}), do: value
  defp literal_value(value), do: value

  # Window function helpers
  defp prep_window_function(selecto, func, opts) do
    # Process the base function
    {func_iodata, func_joins, func_params} =
      case func do
        {:row_number} ->
          {["row_number()"], [], []}

        {:rank} ->
          {["rank()"], [], []}

        {:dense_rank} ->
          {["dense_rank()"], [], []}

        {:lag, field} ->
          {field_iodata, joins, params} = prep_function_args(selecto, [field])
          {["lag(", field_iodata, ")"], joins, params}

        {:lag, field, offset} ->
          {args_iodata, joins, params} = prep_function_args(selecto, [field, {:literal, offset}])
          {["lag(", Enum.intersperse(args_iodata, ", "), ")"], joins, params}

        {:lead, field} ->
          {field_iodata, joins, params} = prep_function_args(selecto, [field])
          {["lead(", field_iodata, ")"], joins, params}

        {:lead, field, offset} ->
          {args_iodata, joins, params} = prep_function_args(selecto, [field, {:literal, offset}])
          {["lead(", Enum.intersperse(args_iodata, ", "), ")"], joins, params}

        {:first_value, field} ->
          {field_iodata, joins, params} = prep_function_args(selecto, [field])
          {["first_value(", field_iodata, ")"], joins, params}

        {:last_value, field} ->
          {field_iodata, joins, params} = prep_function_args(selecto, [field])
          {["last_value(", field_iodata, ")"], joins, params}

        {:ntile, buckets} ->
          {["ntile(", Integer.to_string(buckets), ")"], [], []}

        {:nth_value, field, n} ->
          {field_iodata, joins, params} = prep_function_args(selecto, [field])
          {["nth_value(", field_iodata, ", ", Integer.to_string(n), ")"], joins, params}

        {:cume_dist} ->
          {["cume_dist()"], [], []}

        {:percent_rank} ->
          {["percent_rank()"], [], []}

        {agg_func, field} when agg_func in [:sum, :count, :avg, :min, :max] ->
          {field_iodata, joins, params} = prep_function_args(selecto, [field])
          func_name = Atom.to_string(agg_func)
          {[func_name, "(", field_iodata, ")"], joins, params}
      end

    # Build OVER clause
    {over_iodata, over_joins, over_params} = build_over_clause(selecto, opts)

    # Combine function with OVER clause
    window_iodata = [func_iodata, " over (", over_iodata, ")"]
    all_joins = List.flatten([func_joins | over_joins])
    all_params = func_params ++ over_params

    {window_iodata, all_joins, all_params}
  end

  # Build OVER clause for window functions
  defp build_over_clause(selecto, opts) do
    partition_clause =
      case Keyword.get(opts, :partition_by) do
        nil ->
          []

        fields when is_list(fields) ->
          {part_args, part_joins, part_params} = prep_function_args(selecto, fields)
          {["partition by ", Enum.intersperse(part_args, ", ")], part_joins, part_params}

        field ->
          {part_args, part_joins, part_params} = prep_function_args(selecto, [field])
          {["partition by ", part_args], part_joins, part_params}
      end

    order_clause =
      case Keyword.get(opts, :order_by) do
        nil ->
          []

        fields when is_list(fields) ->
          {order_args, order_joins, order_params} = prep_function_args(selecto, fields)
          {["order by ", Enum.intersperse(order_args, ", ")], order_joins, order_params}

        field ->
          {order_args, order_joins, order_params} = prep_function_args(selecto, [field])
          {["order by ", order_args], order_joins, order_params}
      end

    # Combine clauses
    case {partition_clause, order_clause} do
      {[], []} ->
        {[], [], []}

      {{part_iodata, part_joins, part_params}, []} ->
        {part_iodata, part_joins, part_params}

      {[], {order_iodata, order_joins, order_params}} ->
        {order_iodata, order_joins, order_params}

      {{part_iodata, part_joins, part_params}, {order_iodata, order_joins, order_params}} ->
        combined_iodata = [part_iodata, " ", order_iodata]
        combined_joins = part_joins ++ order_joins
        combined_params = part_params ++ order_params
        {combined_iodata, combined_joins, combined_params}
    end
  end

  # Interval function helper
  defp prep_interval(selecto, spec) do
    with {:ok, interval} <- Selecto.Dialect.Interval.new(spec),
         {:ok, iodata} <-
           Selecto.DialectSupport.render_interval(selecto.adapter, interval, selecto) do
      {iodata, [], []}
    else
      {:error, %Selecto.Error{} = error} ->
        raise Selecto.Error.to_exception(error)

      {:error, reason} ->
        raise ArgumentError, "invalid or unsupported interval: #{inspect(reason)}"
    end
  end

  # Decode function (Oracle-style conditional)
  defp prep_decode_function(selecto, field, mappings) do
    {field_iodata, field_joins, field_params} = prep_function_args(selecto, [field])

    {mapping_parts, mapping_joins, mapping_params} =
      Enum.reduce(mappings, {[], [], []}, fn {match_value, return_value},
                                             {parts, joins, params} ->
        {match_iodata, match_joins, match_params} = prep_function_args(selecto, [match_value])
        {return_iodata, return_joins, return_params} = prep_function_args(selecto, [return_value])

        new_parts = parts ++ [match_iodata, ", ", return_iodata]
        new_joins = joins ++ match_joins ++ return_joins
        new_params = params ++ match_params ++ return_params

        {new_parts, new_joins, new_params}
      end)

    decode_iodata = ["decode(", field_iodata, ", ", mapping_parts, ")"]
    all_joins = field_joins ++ mapping_joins
    all_params = field_params ++ mapping_params

    {decode_iodata, all_joins, all_params}
  end

  # Simple if-then-else function
  defp prep_iif_function(selecto, condition, true_value, false_value) do
    # Convert to CASE expression
    _case_selector = {:case, [{condition, true_value}], false_value}

    # Delegate to existing case handling (would need to call back to main prep_selector)
    # For now, build manually
    {cond_iodata, cond_joins, cond_params} = build_condition_iodata(selecto, condition)
    {true_iodata, true_joins, true_params} = prep_function_args(selecto, [true_value])
    {false_iodata, false_joins, false_params} = prep_function_args(selecto, [false_value])

    case_iodata = [
      "case when ",
      cond_iodata,
      " then ",
      true_iodata,
      " else ",
      false_iodata,
      " end"
    ]

    all_joins = cond_joins ++ true_joins ++ false_joins
    all_params = cond_params ++ true_params ++ false_params

    {case_iodata, all_joins, all_params}
  end

  # Helper to build condition iodata (simplified for now)
  defp build_condition_iodata(selecto, condition) do
    # This would need to integrate with the WHERE clause builder
    # For now, handle simple field comparisons
    case condition do
      {field, :eq, value} ->
        {field_iodata, field_joins, field_params} = prep_function_args(selecto, [field])
        {value_iodata, value_joins, value_params} = prep_function_args(selecto, [value])
        condition_iodata = [field_iodata, " = ", value_iodata]
        {condition_iodata, field_joins ++ value_joins, field_params ++ value_params}

      {field, :gt, value} ->
        {field_iodata, field_joins, field_params} = prep_function_args(selecto, [field])
        {value_iodata, value_joins, value_params} = prep_function_args(selecto, [value])
        condition_iodata = [field_iodata, " > ", value_iodata]
        {condition_iodata, field_joins ++ value_joins, field_params ++ value_params}

      # Add more condition types as needed
      _ ->
        # Fallback
        {["true"], [], []}
    end
  end

  # Generic function argument processor
  defp prep_function_args(selecto, args) do
    Enum.reduce(args, {[], [], []}, fn arg, {sel_parts, joins, params} ->
      {arg_iodata, arg_joins, arg_params} = prep_single_arg(selecto, arg)

      {
        sel_parts ++ [arg_iodata],
        joins ++ List.wrap(arg_joins),
        params ++ arg_params
      }
    end)
  end

  # Process individual function arguments
  defp prep_single_arg(selecto, arg) do
    case arg do
      {:literal, value} ->
        {{:param, value}, :selecto_root, [value]}

      field when is_binary(field) ->
        # Handle field references by calling back to main prep_selector
        Selecto.Builder.Sql.Select.prep_selector(selecto, field)

      value when is_integer(value) or is_float(value) or is_boolean(value) ->
        {{:param, value}, :selecto_root, [value]}

      # For complex expressions, call back to main prep_selector
      complex_expr ->
        case prep_advanced_selector(selecto, complex_expr) do
          nil ->
            # Try the main prep_selector for standard expressions
            try do
              Selecto.Builder.Sql.Select.prep_selector(selecto, complex_expr)
            rescue
              _ -> {[inspect(complex_expr)], :selecto_root, []}
            end

          result ->
            result
        end
    end
  end

  # GROUPING function for ROLLUP/CUBE - indicates whether a column is aggregated
  defp prep_grouping_function(selecto, fields) do
    {field_parts, all_joins, all_params} = prep_function_args(selecto, fields)

    func_iodata = ["GROUPING(", Enum.intersperse(field_parts, ", "), ")"]

    {func_iodata, all_joins, all_params}
  end
end
