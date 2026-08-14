defmodule Selecto.Builder.SetOperations do
  @moduledoc """
  SQL generation for set operations (UNION, INTERSECT, EXCEPT).

  This module handles the generation of SQL for combining multiple queries
  using standard SQL set operations.
  """

  alias Selecto.Builder.Sql

  @doc """
  Build SQL for set operations in the query.

  Returns {iodata, [params]} where iodata contains the set operation SQL
  and params contains the bound parameters from all participating queries.
  """
  def build_set_operations(selecto) do
    set_operations = Map.get(selecto.set, :set_operations, [])

    case set_operations do
      [] ->
        {[], []}

      [operation] ->
        build_single_set_operation(operation)

      multiple_operations ->
        build_chained_set_operations(multiple_operations)
    end
  end

  # Build SQL for a single set operation
  defp build_single_set_operation(spec) do
    {left_sql, left_params} = query_to_iodata_with_params(spec.left_query)
    {right_sql, right_params} = query_to_iodata_with_params(spec.right_query)

    operation_sql = build_operation_sql(spec.operation, spec.options.all)

    combined_sql = [
      "(",
      left_sql,
      ")",
      "\n",
      operation_sql,
      "\n",
      "(",
      right_sql,
      ")"
    ]

    combined_params = left_params ++ right_params

    {combined_sql, combined_params}
  end

  # Build SQL for chained set operations  
  defp build_chained_set_operations([first_op | rest_ops]) do
    # Start with the first operation
    {base_sql, base_params} = build_single_set_operation(first_op)

    # Chain additional operations
    {final_sql, final_params} =
      Enum.reduce(rest_ops, {base_sql, base_params}, fn op, {acc_sql, acc_params} ->
        {right_sql, right_params} = query_to_iodata_with_params(op.right_query)
        operation_sql = build_operation_sql(op.operation, op.options.all)

        chained_sql = [
          "(",
          acc_sql,
          ")",
          "\n",
          operation_sql,
          "\n",
          "(",
          right_sql,
          ")"
        ]

        chained_params = acc_params ++ right_params
        {chained_sql, chained_params}
      end)

    {final_sql, final_params}
  end

  # Convert a Selecto query to SQL with parameters
  defp query_to_iodata_with_params(selecto) do
    # Create a copy of the query without set operations to avoid recursion
    clean_selecto = %{selecto | set: Map.delete(selecto.set, :set_operations)}

    # Generate SQL for the individual query, then restore its parameter markers.
    # Each operand is finalized independently and therefore starts numbering at
    # one. Restoring markers lets the outer builder finalize the complete set
    # expression once with globally coordinated placeholder numbers.
    {sql, _aliases, params} = Sql.build(clean_selecto, [])
    {Selecto.SQL.Params.rebind_finalized(sql, params, clean_selecto.adapter), params}
  end

  # Build the operation SQL keyword
  defp build_operation_sql(:union, true), do: "UNION ALL"
  defp build_operation_sql(:union, false), do: "UNION"
  defp build_operation_sql(:intersect, true), do: "INTERSECT ALL"
  defp build_operation_sql(:intersect, false), do: "INTERSECT"
  defp build_operation_sql(:except, true), do: "EXCEPT ALL"
  defp build_operation_sql(:except, false), do: "EXCEPT"

  @doc """
  Check if the query has set operations that need special SQL handling.
  """
  def has_set_operations?(selecto) do
    set_operations = Map.get(selecto.set, :set_operations, [])
    not Enum.empty?(set_operations)
  end

  @doc """
  Wrap a query with set operations in proper parentheses for complex queries.

  This is used when set operations need to be combined with ORDER BY, LIMIT, etc.
  """
  def wrap_set_operation_query(sql_iodata, has_outer_clauses) do
    if has_outer_clauses do
      ["(", sql_iodata, ")"]
    else
      sql_iodata
    end
  end

  @doc """
  Extract all parameters from set operation queries.

  This ensures all bound parameters from participating queries are included
  in the final parameter list.
  """
  def extract_set_operation_params(selecto) do
    set_operations = Map.get(selecto.set, :set_operations, [])

    Enum.flat_map(set_operations, fn spec ->
      {_left_sql, left_params} = query_to_iodata_with_params(spec.left_query)
      {_right_sql, right_params} = query_to_iodata_with_params(spec.right_query)
      left_params ++ right_params
    end)
  end

  @doc """
  Determine if ORDER BY should be applied to the entire set operation result.

  In SQL, ORDER BY on set operations applies to the final combined result.
  """
  def should_apply_outer_order_by?(selecto) do
    has_set_operations?(selecto) and has_order_by?(selecto)
  end

  @doc """
  Resolve set-operation ordering to projected column positions.

  A set result no longer has either operand's table aliases in scope. Ordering
  by the projected position is valid across supported adapters and remains
  unambiguous when multiple selected paths share the same final column name.
  """
  def outer_order_by(selecto) do
    selected = Map.get(selecto.set, :selected, [])

    selecto.set
    |> Map.get(:order_by, [])
    |> Enum.map(&order_spec_to_position(&1, selected))
  end

  @directions [
    :asc,
    :desc,
    :asc_nulls_first,
    :asc_nulls_last,
    :desc_nulls_first,
    :desc_nulls_last
  ]

  defp order_spec_to_position({selector, direction}, selected) when direction in @directions do
    {selector_to_position(selector, selected), direction}
  end

  defp order_spec_to_position({direction, selector}, selected) when direction in @directions do
    {direction, selector_to_position(selector, selected)}
  end

  defp order_spec_to_position(selector, selected) do
    selector_to_position(selector, selected)
  end

  defp selector_to_position({:literal_position, position} = selector, _selected)
       when is_integer(position),
       do: selector

  defp selector_to_position({:raw_sql, _sql} = selector, _selected), do: selector

  defp selector_to_position(selector, selected) do
    case Enum.find_index(selected, &selected_output?(&1, selector)) do
      nil ->
        raise ArgumentError,
              "Set-operation ORDER BY selector #{inspect(selector)} must reference a selected output column"

      index ->
        {:literal_position, index + 1}
    end
  end

  defp selected_output?(selection, selector) when selection == selector, do: true

  defp selected_output?({:as, _expression, alias_name}, selector),
    do: same_name?(alias_name, selector)

  defp selected_output?({:field, field}, selector), do: same_name?(field, selector)

  defp selected_output?({:field, _field, alias_name}, selector),
    do: same_name?(alias_name, selector)

  defp selected_output?(selection, selector), do: same_name?(selection, selector)

  defp same_name?(left, right) when is_atom(left) or is_binary(left) do
    if is_atom(right) or is_binary(right), do: to_string(left) == to_string(right), else: false
  end

  defp same_name?(_left, _right), do: false

  # Check if query has ORDER BY clauses
  defp has_order_by?(selecto) do
    order_by = Map.get(selecto.set, :order_by, [])
    not Enum.empty?(order_by)
  end

  @doc """
  Validate that set operations are properly structured for SQL generation.

  Returns :ok or {:error, reason}.
  """
  def validate_set_operations_for_sql(selecto) do
    set_operations = Map.get(selecto.set, :set_operations, [])

    cond do
      Enum.empty?(set_operations) ->
        :ok

      not all_operations_validated?(set_operations) ->
        {:error, "Set operations contain unvalidated schemas"}

      true ->
        case unsupported_post_set_changes(selecto) do
          [] ->
            :ok

          changes ->
            {:error,
             "Set result contains unsupported post-set mutations in #{Enum.join(changes, ", ")}; " <>
               "only UNION/INTERSECT/EXCEPT chaining and outer ORDER BY, LIMIT, or OFFSET are supported"}
        end
    end
  end

  # Check if all set operations have been schema-validated
  defp all_operations_validated?(set_operations) do
    Enum.all?(set_operations, & &1.validated)
  end

  @set_result_metadata_fields [
    :runtime,
    :adapter,
    :connection,
    :domain,
    :config,
    :extensions,
    :tenant,
    :policy
  ]

  # A set result is represented by the latest left operand plus its appended
  # `set_operations` entry and optional outer ordering/pagination. Compare that
  # retained state at build time so a missed or future covered mutator cannot be
  # silently ignored.
  defp unsupported_post_set_changes(selecto) do
    set_operations = Map.fetch!(selecto.set, :set_operations)
    latest_operation = List.last(set_operations)
    expected_set = comparable_set(latest_operation.left_query.set)
    actual_set = comparable_set(selecto.set)

    set_changes = changed_map_keys(expected_set, actual_set, "set.")

    metadata_changes =
      @set_result_metadata_fields
      |> Enum.filter(&(Map.get(selecto, &1) != Map.get(latest_operation.left_query, &1)))
      |> Enum.map(&to_string/1)

    chain_changes =
      set_operations
      |> Enum.drop(1)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {operation, index} ->
        expected_prefix = Enum.take(set_operations, index)

        if Map.get(operation.left_query.set, :set_operations, []) == expected_prefix do
          []
        else
          ["set_operations[#{index}].left_query"]
        end
      end)

    Enum.sort(set_changes ++ metadata_changes ++ chain_changes)
  end

  defp comparable_set(set) do
    set
    |> Map.delete(:set_operations)
    |> Map.put(:order_by, [])
    |> Map.delete(:limit)
    |> Map.delete(:offset)
  end

  defp changed_map_keys(expected, actual, prefix) do
    expected
    |> Map.keys()
    |> Kernel.++(Map.keys(actual))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(expected, &1, :__missing__) != Map.get(actual, &1, :__missing__)))
    |> Enum.map(&(prefix <> to_string(&1)))
  end
end
