defmodule Selecto.Document.Numeric do
  @moduledoc """
  Explicit JSON-number interpretation for reviewed document releases. Legacy
  releases retain exact runtime integer/float distinctions. The JSON profile
  admits only finite values within the portable integer53 magnitude; integral
  numbers normalize to integers only for declared integer fields. It does not
  coerce strings, booleans, unknown fields, or missing/null values.
  """
  @maximum 9_007_199_254_740_991

  def json_number?(release), do: get_in(release, ["source", "numeric_semantics"]) == "json_number"

  def normalize(release, field, value) do
    if json_number?(release), do: normalize_field(field, value), else: value
  end

  def valid?(release, %{"type" => type}, value) when type in ["integer", "float"] do
    not json_number?(release) or (is_number(value) and abs(value) <= @maximum)
  end

  def valid?(_release, _field, _value), do: true

  defp normalize_field(%{"type" => "integer"}, value)
       when is_float(value) and abs(value) <= @maximum do
    if value == trunc(value), do: trunc(value), else: value
  end

  defp normalize_field(%{"type" => "float"}, value)
       when is_integer(value) and abs(value) <= @maximum,
       do: value / 1

  defp normalize_field(
         %{"scalar_array" => %{"element_type" => type, "max_elements" => maximum}},
         values
       )
       when is_list(values) do
    # Never normalize a truncated prefix and present it as a complete array.
    if length(Enum.take(values, maximum + 1)) <= maximum,
      do: Enum.map(values, &normalize_field(%{"type" => type}, &1)),
      else: values
  end

  defp normalize_field(_, value), do: value
end
