defmodule Selecto.Subfilter.SQL.Safe do
  @moduledoc false

  alias Selecto.Subfilter.Error

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

  def temporal_condition(filter_spec, qualified_field) do
    case filter_spec.temporal_type do
      :recent_years ->
        interval_condition(filter_spec.value, "year", qualified_field, "CURRENT_DATE")

      :within_days ->
        interval_condition(filter_spec.value, "day", qualified_field, "CURRENT_DATE")

      :within_hours ->
        interval_condition(filter_spec.value, "hour", qualified_field, "NOW()")

      :since_date ->
        {:ok, "#{qualified_field} > ?", [filter_spec.value]}

      other ->
        unsupported_temporal_type(other)
    end
  end

  defp interval_condition(value, unit, qualified_field, clock)
       when is_integer(value) and value > 0 do
    {:ok, "#{qualified_field} > (#{clock} - (? * INTERVAL '1 #{unit}'))", [value]}
  end

  defp interval_condition(value, unit, _qualified_field, _clock) do
    {:error,
     %Error{
       type: :invalid_temporal_value,
       message: "Temporal interval must be a positive integer",
       details: %{value: value, unit: unit}
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
