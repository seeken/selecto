defmodule Selecto.Builder.JsonOperations do
  @moduledoc """
  Compiles validated portable JSON intent through the configured dialect.

  Core owns the finite operation vocabulary and alias composition. Database
  adapters own native JSON functions, operators, paths, casts, and feature
  support.
  """

  alias Selecto.Advanced.JsonOperations.Spec
  alias Selecto.AdapterSupport
  alias Selecto.Dialect.Json.Operation
  alias Selecto.DialectSupport
  alias Selecto.Error

  @doc "Generate SQL for a JSON operation in a SELECT clause."
  def build_json_select(%Spec{} = spec, opts \\ []) do
    build(spec, :select, opts)
  end

  @doc "Generate SQL for a JSON operation in a WHERE clause."
  def build_json_filter(%Spec{} = spec, opts \\ []) do
    build(spec, :filter, opts)
  end

  @doc "Generate SQL for a JSON operation in an ORDER BY clause."
  def build_json_order(%Spec{} = spec, opts \\ []) do
    build(spec, :order, opts)
  end

  @doc "Generate SQL for multiple JSON SELECT operations."
  def build_json_operations(specs, opts \\ []) when is_list(specs) do
    sql_parts = specs |> Enum.map(&build_json_select(&1, opts)) |> Enum.intersperse(", ")
    {sql_parts, []}
  end

  defp build(%Spec{validated: false}, _clause, _opts) do
    raise ArgumentError, "JSON operation specification must be validated before SQL generation"
  end

  defp build(%Spec{} = spec, clause, opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    validate_spec!(spec)
    validate_clause!(spec, clause)

    fragment = %Operation{
      operation: spec.operation,
      clause: clause,
      column: spec.column,
      path: spec.path,
      value: spec.value,
      key_field: spec.key_field,
      value_field: spec.value_field,
      table_alias: Keyword.get(opts, :table_alias),
      options: spec.options || %{}
    }

    case DialectSupport.render_json(adapter, :render_json_operation, fragment, %{
           adapter: adapter
         }) do
      {:ok, sql} ->
        sql
        |> add_filter_comparison(spec, clause)
        |> add_alias(spec.alias, adapter, clause)

      {:error, %Error{} = error} ->
        raise Error.to_exception(error)

      {:error, reason} ->
        raise Error.to_exception(render_error(adapter, spec.operation, reason))
    end
  end

  defp validate_spec!(spec) do
    case Selecto.Advanced.JsonOperations.validate_json_operation(spec) do
      {:ok, _validated_spec} -> :ok
      {:error, validation_error} -> raise validation_error
    end
  end

  defp validate_clause!(spec, clause) do
    case Selecto.Advanced.JsonOperations.validate_operation_clause(spec, clause) do
      :ok -> :ok
      {:error, validation_error} -> raise validation_error
    end
  end

  defp add_filter_comparison(sql, %Spec{options: options}, :filter) do
    case Map.get(options || %{}, :comparison) do
      {operator, value} ->
        ["(", sql, " ", comparison_operator(operator), " ", {:param, value}, ")"]

      nil ->
        sql
    end
  end

  defp add_filter_comparison(sql, _spec, _clause), do: sql

  defp comparison_operator(operator) when operator in [:=, :==], do: "="
  defp comparison_operator(operator) when operator in [:!=, :<>], do: "<>"
  defp comparison_operator(:>), do: ">"
  defp comparison_operator(:>=), do: ">="
  defp comparison_operator(:<), do: "<"
  defp comparison_operator(:<=), do: "<="

  defp add_alias(sql, nil, _adapter, _clause), do: sql
  defp add_alias(sql, _alias_name, _adapter, clause) when clause != :select, do: sql

  defp add_alias(sql, alias_name, adapter, :select) do
    [sql, " AS ", adapter.quote_identifier(to_string(alias_name))]
  end

  defp render_error(adapter, operation, reason) do
    Error.validation_error("Adapter could not render the requested JSON operation", %{
      adapter: AdapterSupport.adapter_name(adapter),
      operation: operation,
      reason: reason,
      unsupported_feature: :json_operation
    })
  end
end
