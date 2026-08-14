defmodule Selecto.Subfilter.SQL.Safe do
  @moduledoc false

  alias Selecto.Subfilter.Error
  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation

  @comparison_operators ~w(= != <> < <= > >=)

  def comparison_operator(operator) do
    operator = to_string(operator)

    if operator in @comparison_operators do
      {:ok, operator}
    else
      {:error,
       %Error{
         type: :invalid_comparison_operator,
         message: "Unsupported comparison operator: #{inspect(operator)}",
         details: %{operator: operator, allowed: @comparison_operators}
       }}
    end
  end

  def temporal_condition(
        filter_spec,
        qualified_field,
        adapter \\ Selecto.AdapterSupport.default_adapter()
      ) do
    case filter_spec.temporal_type do
      :recent_years ->
        interval_condition(filter_spec.value, :year, qualified_field, :current_date, adapter)

      :within_days ->
        interval_condition(filter_spec.value, :day, qualified_field, :current_date, adapter)

      :within_hours ->
        interval_condition(
          filter_spec.value,
          :hour,
          qualified_field,
          :current_timestamp,
          adapter
        )

      :since_date ->
        {:ok, "#{qualified_field} > ?", [filter_spec.value]}

      other ->
        unsupported_temporal_type(other)
    end
  end

  defp interval_condition(value, unit, qualified_field, clock, adapter)
       when is_integer(value) and value > 0 do
    fragment = %DateTimeOperation{
      operation: :temporal_cutoff,
      clause: :filter,
      expression: qualified_field,
      part: unit,
      options: %{amount: value, clock: clock}
    }

    case Selecto.DialectSupport.render_datetime_operation(adapter, fragment, %{}) do
      {:ok, {iodata, params}} -> {:ok, generic_placeholder_sql(iodata), params}
      {:ok, iodata} -> {:ok, generic_placeholder_sql(iodata), [value]}
      {:error, reason} -> unsupported_datetime_operation(reason)
    end
  end

  defp interval_condition(value, unit, _qualified_field, _clock, _adapter) do
    {:error,
     %Error{
       type: :invalid_temporal_value,
       message: "Temporal interval must be a positive integer",
       details: %{value: value, unit: unit}
     }}
  end

  defp generic_placeholder_sql(iodata) do
    iodata
    |> replace_param_markers()
    |> IO.iodata_to_binary()
  end

  defp replace_param_markers({:param, _value}), do: "?"

  defp replace_param_markers(list) when is_list(list),
    do: Enum.map(list, &replace_param_markers/1)

  defp replace_param_markers(value), do: value

  defp unsupported_datetime_operation(reason) do
    {:error,
     %Error{
       type: :unsupported_temporal_type,
       message: "Configured adapter does not support temporal interval filters",
       details: %{reason: reason}
     }}
  end

  defp unsupported_temporal_type(type) do
    {:error,
     %Error{
       type: :unsupported_temporal_type,
       message: "Unsupported temporal type: #{type}",
       details: %{temporal_type: type}
     }}
  end
end
