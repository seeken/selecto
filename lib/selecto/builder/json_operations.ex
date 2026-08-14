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
      {:ok, sql} -> add_alias(sql, spec.alias, adapter)
      {:error, %Error{} = error} -> raise Error.to_exception(error)
      {:error, reason} -> raise Error.to_exception(render_error(adapter, spec.operation, reason))
    end
  end

  defp add_alias(sql, nil, _adapter), do: sql

  defp add_alias(sql, alias_name, adapter) do
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
