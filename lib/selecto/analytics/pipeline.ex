defmodule Selecto.Analytics.Pipeline do
  @moduledoc "Applies unit-aware analytical transforms after aggregate execution."

  alias Selecto.Analytics.{TransformRegistry, Unit}

  @spec apply(list(), list(), map(), atom() | String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def apply(values, transforms, unit, behavior)
      when is_list(values) and is_list(transforms) and length(transforms) <= 8 do
    with {:ok, unit} <- normalize_input_unit(unit, transforms),
         {:ok, raw} <- cast_values(values),
         {:ok, current, final_unit, _behavior, derivation} <-
           Enum.reduce_while(transforms, {:ok, raw, unit, behavior, []}, fn requested,
                                                                            {:ok, current,
                                                                             current_unit,
                                                                             current_behavior,
                                                                             derivation} ->
             with {:ok, transform} <- normalize_transform(requested),
                  {:ok, output_unit} <-
                    TransformRegistry.result_unit(
                      transform.type,
                      current_unit,
                      current_behavior
                    ),
                  {:ok, output} <- execute(transform, current) do
               entry = %{
                 type: transform.type,
                 parameters: transform.parameters,
                 input_unit: current_unit,
                 output_unit: output_unit
               }

               next_behavior =
                 if transform.type in [:moving_average, :exponential_moving_average],
                   do: current_behavior,
                   else: nil

               {:cont, {:ok, output, output_unit, next_behavior, derivation ++ [entry]}}
             else
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      points =
        Enum.zip_with(raw, current, fn raw_value, value ->
          %{raw_value: raw_value, value: value, derivation: derivation}
        end)

      {:ok, %{unit: final_unit, transforms: derivation, points: points}}
    end
  end

  def apply(values, _transforms, _unit, _behavior) when not is_list(values),
    do: {:error, "analytical values must be a list"}

  def apply(_values, transforms, _unit, _behavior) when not is_list(transforms),
    do: {:error, "analytical transforms must be a list"}

  def apply(_values, _transforms, _unit, _behavior),
    do: {:error, "too many analytical transforms"}

  defp normalize_input_unit(nil, []), do: {:ok, nil}
  defp normalize_input_unit(unit, _transforms), do: Unit.normalize_unit(unit)

  defp normalize_transform(requested) when is_atom(requested) or is_binary(requested),
    do: normalize_transform(%{type: requested})

  defp normalize_transform(requested) when is_map(requested) do
    type = Map.get(requested, :type, Map.get(requested, "type"))
    parameters = Map.get(requested, :parameters, Map.get(requested, "parameters", %{}))

    case TransformRegistry.definition(type) do
      nil -> {:error, "analytical transform is not available"}
      %{id: id} when is_map(parameters) -> {:ok, %{type: id, parameters: parameters}}
      _ -> {:error, "analytical transform parameters must be a map"}
    end
  end

  defp normalize_transform(_), do: {:error, "analytical transform must be a map or name"}

  defp cast_values(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, result} ->
      case number(value) do
        {:ok, number} -> {:cont, {:ok, [number | result]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp number(nil), do: {:ok, nil}
  # Keep native integers intact. Coercing them to float here loses raw values
  # above 2^53 even when no transform is requested.
  defp number(value) when is_integer(value) or is_float(value), do: {:ok, value}
  defp number(%Decimal{} = value), do: {:ok, Decimal.to_float(value)}

  defp number(value) when is_binary(value) do
    if Regex.match?(~r/^-?(?:\d+(?:\.\d*)?|\.\d+)$/, value) do
      parseable =
        value
        |> String.replace_prefix("-.", "-0.")
        |> String.replace_prefix(".", "0.")
        |> then(fn text -> if String.ends_with?(text, "."), do: text <> "0", else: text end)

      case Float.parse(parseable) do
        {number, ""} -> {:ok, number}
        _ -> {:error, "analytical series contains a non-numeric value"}
      end
    else
      {:error, "analytical series contains a non-numeric value"}
    end
  end

  defp number(_), do: {:error, "analytical series contains a non-numeric value"}

  defp execute(%{type: :percent_of_total}, values) do
    total = Enum.reduce(values, 0.0, fn value, sum -> sum + (value || 0) end)

    {:ok,
     Enum.map(values, fn value ->
       if is_nil(value) or total == 0, do: nil, else: value / total * 100
     end)}
  end

  defp execute(%{type: :percent_change}, values), do: {:ok, previous_change(values, true)}

  defp execute(%{type: :percentage_point_change}, values),
    do: {:ok, previous_change(values, false)}

  defp execute(%{type: :index_to_first}, values) do
    baseline = Enum.find(values, &(not is_nil(&1) and &1 != 0))

    {:ok,
     Enum.map(values, fn value ->
       if is_nil(value) or is_nil(baseline), do: nil, else: value / baseline * 100
     end)}
  end

  defp execute(%{type: :cumulative}, values) do
    {result, _} =
      Enum.map_reduce(values, 0.0, fn
        nil, sum -> {nil, sum}
        value, sum -> {sum + value, sum + value}
      end)

    {:ok, result}
  end

  defp execute(%{type: :moving_average, parameters: parameters}, values) do
    with {:ok, window} <- integer_parameter(parameters, :window, 2, 365) do
      {:ok,
       values
       |> Enum.with_index()
       |> Enum.map(fn
         {nil, _index} ->
           nil

         {_value, index} ->
           sample =
             values |> Enum.slice(max(0, index - window + 1)..index) |> Enum.reject(&is_nil/1)

           Enum.sum(sample) / length(sample)
       end)}
    end
  end

  defp execute(%{type: :exponential_moving_average, parameters: parameters}, values) do
    with {:ok, alpha} <- decimal_parameter(parameters, :alpha) do
      {result, _} =
        Enum.map_reduce(values, nil, fn
          nil, previous ->
            {nil, previous}

          value, nil ->
            {value, value}

          value, previous ->
            next = alpha * value + (1 - alpha) * previous
            {next, next}
        end)

      {:ok, result}
    end
  end

  defp execute(%{type: :min_max}, values) do
    case Enum.reject(values, &is_nil/1) do
      [] ->
        {:ok, Enum.map(values, fn _ -> nil end)}

      defined ->
        min_value = Enum.min(defined)
        span = Enum.max(defined) - min_value

        {:ok,
         Enum.map(values, fn value ->
           if is_nil(value) or span == 0, do: nil, else: (value - min_value) / span * 100
         end)}
    end
  end

  defp execute(%{type: :z_score}, values) do
    case Enum.reject(values, &is_nil/1) do
      [] ->
        {:ok, Enum.map(values, fn _ -> nil end)}

      defined ->
        mean = Enum.sum(defined) / length(defined)

        variance =
          Enum.reduce(defined, 0.0, fn value, total -> total + :math.pow(value - mean, 2) end) /
            length(defined)

        deviation = :math.sqrt(variance)

        {:ok,
         Enum.map(values, fn value ->
           if is_nil(value) or deviation == 0, do: nil, else: (value - mean) / deviation
         end)}
    end
  end

  defp previous_change(values, percent?) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      previous = if index == 0, do: nil, else: Enum.at(values, index - 1)

      cond do
        is_nil(value) or is_nil(previous) -> nil
        percent? and previous == 0 -> nil
        percent? -> (value - previous) / previous * 100
        true -> value - previous
      end
    end)
  end

  defp integer_parameter(parameters, key, minimum, maximum) do
    value = Map.get(parameters, key, Map.get(parameters, Atom.to_string(key)))
    parsed = if is_integer(value), do: {value, ""}, else: Integer.parse(to_string(value || ""))

    case parsed do
      {number, ""} when number >= minimum and number <= maximum -> {:ok, number}
      _ -> {:error, "#{key} must be an integer from #{minimum} through #{maximum}"}
    end
  end

  defp decimal_parameter(parameters, key) do
    value = Map.get(parameters, key, Map.get(parameters, Atom.to_string(key)))

    with {:ok, number} <- number(value),
         true <- number > 0 and number <= 1,
         do: {:ok, number},
         else: (_ -> {:error, "#{key} must be a number greater than 0 and at most 1"})
  end
end
