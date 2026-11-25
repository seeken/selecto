defmodule Selecto.RatioMeasures do
  @moduledoc "Governed decimal ratios of independently summed numeric measures."
  alias Selecto.Domain.Contract.Shared.Core, as: M
  alias Selecto.Analytics.Unit

  def definitions(%Selecto{domain: domain}), do: definitions(domain)

  def definitions(domain) do
    case normalize(domain) do
      {:ok, definitions} -> definitions
      {:error, message} -> raise ArgumentError, message
    end
  end

  def errors(domain) do
    case normalize(domain) do
      {:ok, _} ->
        []

      {:error, message} ->
        [%{code: :invalid_ratio_measure, path: [:ratio_measures], message: message}]
    end
  end

  def decorate(domain) do
    case normalize(domain) do
      {:ok, definitions} when map_size(definitions) > 0 ->
        Selecto.Domain.Shared.Map.put_section(domain, :ratio_measures, definitions)

      _ ->
        domain
    end
  end

  defp normalize(domain) do
    raw = M.map_value(domain, :ratio_measures)

    cond do
      is_nil(raw) ->
        {:ok, %{}}

      not is_map(raw) ->
        {:error, "ratio_measures must be a map"}

      true ->
        Enum.reduce_while(raw, {:ok, %{}}, fn {id, spec}, {:ok, acc} ->
          case definition(domain, id, spec) do
            {:ok, spec} -> {:cont, {:ok, Map.put(acc, id, spec)}}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp definition(domain, id, spec) when is_map(spec) do
    with true <- Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, to_string(id)),
         true <-
           Enum.all?(Map.keys(spec), &(to_string(&1) in ~w(label numerator denominator unit))),
         label when is_binary(label) and byte_size(label) > 0 <- M.map_value(spec, :label),
         {:ok, numerator} <- operand(domain, M.map_value(spec, :numerator)),
         {:ok, denominator} <- operand(domain, M.map_value(spec, :denominator)),
         {:ok, unit} <-
           Unit.normalize_unit(
             M.map_value(spec, :unit) ||
               %{
                 kind: :ratio,
                 numerator: Unit.column_unit(numerator),
                 denominator: Unit.column_unit(denominator)
               }
           ) do
      {:ok, Selecto.Domain.Shared.Map.put_map_value(spec, :unit, unit)}
    else
      _ -> {:error, "ratio #{id} requires public numeric sum operands without owner fanout"}
    end
  end

  defp definition(_, id, _), do: {:error, "ratio #{id} must be a map"}

  defp operand(domain, part) when is_map(part) do
    with true <- Enum.all?(Map.keys(part), &(to_string(&1) in ~w(field function))),
         function when function in [:sum, "sum"] <- M.map_value(part, :function),
         field when is_binary(field) <- M.map_value(part, :field),
         {:ok, column, relation} <-
           resolve(domain, M.map_value(domain, :source), String.split(field, ".")),
         true <- Unit.numeric_type?(M.map_value(column, :type)),
         true <-
           Enum.all?(
             [:hidden, :internal, :redacted],
             &(M.map_value(column, &1) not in [true, 1, "1"])
           ),
         true <- M.map_value(column, :aggregatable) not in [false, 0, "0"],
         true <-
           List.last(String.split(field, ".")) not in Enum.map(
             M.map_value(relation, :redact_fields) || [],
             &to_string/1
           ) do
      {:ok, column}
    else
      _ -> {:error, :invalid_operand}
    end
  end

  defp operand(_, _), do: {:error, :invalid_operand}

  defp resolve(_domain, relation, [name]) do
    case M.fetch_key(M.map_value(relation, :columns), name) do
      {:ok, column} when is_map(column) -> {:ok, column, relation}
      _ -> {:error, :unknown_field}
    end
  end

  defp resolve(domain, relation, [association | rest]) do
    with {:ok, association} when is_map(association) <-
           M.fetch_key(M.map_value(relation, :associations), association),
         true <- M.map_value(association, :cardinality) not in [:many, "many"],
         {:ok, target} <-
           M.fetch_key(M.map_value(domain, :schemas), M.map_value(association, :queryable)) do
      resolve(domain, target, rest)
    else
      _ -> {:error, :fanout_or_unknown_path}
    end
  end
end
