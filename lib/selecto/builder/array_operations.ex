defmodule Selecto.Builder.ArrayOperations do
  @moduledoc """
  Compiles portable collection intent through the configured database dialect.

  Core resolves semantic field references and preserves ordered parameters.
  Adapters own native collection functions, constructors, operators, and
  expansion syntax.
  """

  alias Selecto.Advanced.ArrayOperations.Spec
  alias Selecto.Dialect.Collection.Operation
  alias Selecto.DialectSupport
  alias Selecto.Error

  import Selecto.Builder.Sql.Helpers, only: [force_quote_identifier: 2]

  @doc "Build SQL for a validated collection operation."
  def build_array_sql(%Spec{} = spec, params_list, %Selecto{} = selecto) do
    fragment = operation_fragment(spec, selecto)

    case DialectSupport.render_collection_operation(selecto.adapter, fragment, selecto) do
      {:ok, {sql, params}} when is_list(params) ->
        {add_alias(sql, spec.alias, selecto.adapter), params_list ++ params}

      {:ok, sql} ->
        {add_alias(sql, spec.alias, selecto.adapter), params_list}

      {:error, %Error{} = error} ->
        raise Error.to_exception(error)

      {:error, reason} ->
        raise Error.to_exception(render_error(selecto, spec.operation, reason))
    end
  end

  def build_array_sql(%Spec{}, _params_list, nil) do
    raise ArgumentError, "collection SQL requires a configured Selecto runtime"
  end

  @doc false
  def build_filter_sql(operation, column_sql, value, %Selecto{} = selecto) do
    fragment = %Operation{
      operation: operation,
      clause: :filter,
      column: column_sql,
      value: value,
      distinct: false,
      order_by: [],
      options: %{}
    }

    case DialectSupport.render_collection_operation(selecto.adapter, fragment, selecto) do
      {:ok, {sql, params}} -> {sql, params}
      {:ok, sql} -> {sql, []}
      {:error, %Error{} = error} -> raise Error.to_exception(error)
      {:error, reason} -> raise Error.to_exception(render_error(selecto, operation, reason))
    end
  end

  defp operation_fragment(spec, selecto) do
    %Operation{
      operation: spec.operation,
      clause: clause(spec.operation),
      column: build_column_reference(spec.column, selecto),
      dimension: spec.dimension,
      value: spec.value,
      distinct: spec.operation == :array_agg_distinct or spec.distinct,
      order_by: build_order_by(spec.order_by, selecto),
      options: spec.options || %{}
    }
  end

  defp clause(operation)
       when operation in [:array_contains, :array_contained, :array_overlap, :array_eq],
       do: :filter

  defp clause(:unnest), do: :table
  defp clause(_operation), do: :select

  defp build_column_reference(nil, _selecto), do: nil

  defp build_column_reference(column, selecto) when is_atom(column),
    do: build_column_reference(Atom.to_string(column), selecto)

  defp build_column_reference({:field, field}, selecto),
    do: build_column_reference(field, selecto)

  defp build_column_reference({operation, column}, selecto) when is_atom(operation) do
    nested = %Spec{
      id: "nested_#{operation}",
      operation: operation,
      column: column,
      distinct: false,
      options: %{},
      validated: true
    }

    case build_array_sql(nested, [], selecto) do
      {sql, []} ->
        sql

      {_sql, params} ->
        raise ArgumentError, "nested collection operation produced parameters: #{inspect(params)}"
    end
  end

  defp build_column_reference(column, selecto) when is_binary(column) do
    case String.split(column, ".", parts: 2) do
      [table, field] ->
        [force_quote_identifier(selecto, table), ".", force_quote_identifier(selecto, field)]

      [field] ->
        [
          force_quote_identifier(selecto, "selecto_root"),
          ".",
          force_quote_identifier(selecto, field)
        ]
    end
  end

  defp build_column_reference(column, _selecto), do: to_string(column)

  defp build_order_by(nil, _selecto), do: []

  defp build_order_by(order_by, selecto) do
    Enum.map(order_by, fn
      {column, direction} -> {build_column_reference(column, selecto), direction!(direction)}
      column -> {build_column_reference(column, selecto), :asc}
    end)
  end

  defp direction!(direction) when direction in [:asc, "asc", "ASC"], do: :asc
  defp direction!(direction) when direction in [:desc, "desc", "DESC"], do: :desc

  defp direction!(direction),
    do: raise(ArgumentError, "invalid collection order direction: #{inspect(direction)}")

  defp add_alias(sql, nil, _adapter), do: sql

  defp add_alias(sql, alias_name, adapter),
    do: [sql, " AS ", adapter.quote_identifier(to_string(alias_name))]

  defp render_error(selecto, operation, reason) do
    Error.validation_error("Adapter could not render the requested collection operation", %{
      adapter: Selecto.AdapterSupport.adapter_name(selecto.adapter),
      operation: operation,
      reason: reason,
      unsupported_feature: :collection_operation
    })
  end
end
