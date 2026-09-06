defmodule Selecto.Domain.Contract.ComputedPredicates do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core

  @comparison ~w(eq ne neq gt gte lt lte)

  def validate(errors, source) when is_map(source) do
    columns = Core.map_value(source, :columns) || %{}
    # Relations reports the registry shape error; do not enumerate malformed
    # columns while collecting additional computed-predicate diagnostics.
    columns = if is_map(columns), do: columns, else: %{}
    fields = MapSet.new(Core.relation_fields(source))

    {errors, graph} =
      Enum.reduce(columns, {errors, %{}}, fn {field, column}, {acc, graph} ->
        case Core.map_value(column, :computed) do
          nil -> {acc, graph}
          computed -> validate_column(acc, graph, Core.field_id(field), column, computed, fields)
        end
      end)

    validate_cycles(errors, graph)
  end

  def validate(errors, _source), do: errors

  def to_filter(expression) when is_tuple(expression), do: expression

  def to_filter([op, operands]) when op in [:and, :or, "and", "or"] and is_list(operands),
    do: {op_atom(op), Enum.map(operands, &to_filter/1)}

  def to_filter([op, operand]) when op in [:not, "not"], do: {:not, to_filter(operand)}
  def to_filter([op, field]) when op in [:is_null, "is_null"], do: {field, nil}
  def to_filter([op, field]) when op in [:not_null, "not_null"], do: {field, :not_null}

  def to_filter([op, field, values]) when op in [:in, "in"] and is_list(values),
    do: {field, {:in, values}}

  def to_filter([op, field, left, right]) when op in [:between, "between"],
    do: {field, {:between, left, right}}

  def to_filter([op, field, value]) when op in [:eq, "eq"], do: {field, value_operand(value)}

  def to_filter([op, field, value]) when is_atom(op) or is_binary(op) do
    if to_string(op) in @comparison do
      {field, {comparison_operator(op), value_operand(value)}}
    else
      raise ArgumentError, "unsupported computed predicate operator #{inspect(op)}"
    end
  end

  defp validate_column(errors, graph, field, column, computed, fields) when is_map(computed) do
    kind = Core.map_value(computed, :kind)

    if kind in [:predicate, "predicate"] do
      type = Core.map_value(column, :type)

      errors =
        if Enum.all?(Map.keys(computed), &(to_string(&1) in ["kind", "expression"])),
          do: errors,
          else: [
            error(:invalid_computed_predicate, field, "unknown computed predicate key") | errors
          ]

      errors =
        if type in [:boolean, "boolean"],
          do: errors,
          else: [
            error(
              :computed_predicate_not_boolean,
              field,
              "predicate computed columns must be boolean"
            )
            | errors
          ]

      expression = Core.map_value(computed, :expression)

      case validate_expression(expression, fields, field) do
        {:ok, dependencies} ->
          {errors, Map.put(graph, field, dependencies)}

        {:error, message} ->
          {[error(:invalid_computed_predicate, field, message) | errors], graph}
      end
    else
      {[error(:unsupported_computed_column, field, "unsupported computed column kind") | errors],
       graph}
    end
  end

  defp validate_column(errors, graph, field, _column, _computed, _fields),
    do:
      {[
         error(:invalid_computed_predicate, field, "computed column metadata must be a map")
         | errors
       ], graph}

  defp validate_expression([op, operands], fields, owner)
       when op in [:and, :or, "and", "or"] and is_list(operands) and operands != [] do
    collect(operands, fields, owner)
  end

  defp validate_expression([op, operand], fields, owner) when op in [:not, "not"],
    do: validate_expression(operand, fields, owner)

  defp validate_expression([op, field], fields, _owner)
       when op in [:is_null, :not_null, "is_null", "not_null"],
       do: field_dependency(field, fields)

  defp validate_expression([op, field, values], fields, _owner)
       when op in [:in, "in"] and is_list(values) and values != [] do
    if Enum.any?(values, &(not literal?(&1))),
      do: {:error, "in values must be literals"},
      else: field_dependency(field, fields)
  end

  defp validate_expression([op, field, left, right], fields, _owner)
       when op in [:between, "between"] do
    with {:ok, dependency} <- field_dependency(field, fields),
         true <- literal?(left) and literal?(right),
         do: {:ok, dependency},
         else: (_ -> {:error, "between bounds must be literals"})
  end

  defp validate_expression([op, field, value], fields, _owner)
       when is_atom(op) or is_binary(op) do
    if to_string(op) in @comparison do
      with {:ok, dependency} <- field_dependency(field, fields),
           :ok <- validate_value(value, fields),
           do: {:ok, dependency ++ value_dependencies([value])}
    else
      {:error, "unsupported predicate operator #{inspect(op)}"}
    end
  end

  defp validate_expression(_, _fields, _owner),
    do: {:error, "predicate expression has an invalid shape"}

  defp collect(expressions, fields, owner) do
    Enum.reduce_while(expressions, {:ok, []}, fn expression, {:ok, acc} ->
      case validate_expression(expression, fields, owner) do
        {:ok, dependencies} -> {:cont, {:ok, Enum.uniq(acc ++ dependencies)}}
        error -> {:halt, error}
      end
    end)
  end

  defp field_dependency(field, fields) when is_atom(field) or is_binary(field) do
    name = to_string(field)

    cond do
      String.contains?(name, ".") ->
        {:error, "computed predicates may reference only root fields"}

      MapSet.member?(fields, name) ->
        {:ok, [name]}

      true ->
        {:error, "computed predicate references unknown field #{inspect(field)}"}
    end
  end

  defp field_dependency(_, _), do: {:error, "predicate field must be a governed root field"}

  defp validate_value([tag, field], fields) when tag in [:field, "field"] do
    case field_dependency(field, fields) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp validate_value(value, _fields)
       when is_map(value) or is_tuple(value) or is_function(value) or is_list(value),
       do: {:error, "predicate values must be portable literals or field references"}

  defp validate_value(_value, _fields), do: :ok

  defp literal?(value),
    do: is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value)

  defp value_dependencies(values),
    do: for([tag, field] <- values, tag in [:field, "field"], do: to_string(field))

  defp value_operand([tag, field]) when tag in [:field, "field"], do: {:ref, field}
  defp value_operand(value), do: value
  defp op_atom(op), do: op |> to_string() |> String.to_existing_atom()

  defp comparison_operator(op),
    do:
      %{"ne" => :!=, "neq" => :!=, "gt" => :>, "gte" => :>=, "lt" => :<, "lte" => :<=}[
        to_string(op)
      ]

  defp validate_cycles(errors, graph) do
    case Enum.find(Map.keys(graph), &cycle_from?(&1, graph, MapSet.new(), MapSet.new())) do
      nil ->
        errors

      field ->
        [
          error(:computed_predicate_cycle, field, "computed predicate dependency cycle detected")
          | errors
        ]
    end
  end

  defp cycle_from?(field, graph, visiting, visited) do
    cond do
      MapSet.member?(visiting, field) ->
        true

      MapSet.member?(visited, field) ->
        false

      true ->
        visiting = MapSet.put(visiting, field)
        visited = MapSet.put(visited, field)

        Enum.any?(Map.get(graph, field, []), fn dependency ->
          Map.has_key?(graph, dependency) and cycle_from?(dependency, graph, visiting, visited)
        end)
    end
  end

  defp error(code, field, message),
    do: Core.error(code, [:source, :columns, field, :computed], message, field: field)
end
