defmodule Selecto.Domain.ActionPreconditions do
  @moduledoc """
  Normalizes the portable filter predicates declared on a domain action.

  Preconditions are an AND-list of `{field, value}` equality filters,
  `{comparator, field, value}` filters, or maps with `field`, `comparator`, and
  `value` keys. JSON-safe arrays and string keys are accepted. The supported
  comparators are `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, and non-empty `in`.
  These declarations never grant write authority or replace caller target scope.
  """

  @type predicate :: %{field: String.t(), comparator: atom(), value: term()}

  @spec normalize(term()) :: {:ok, [predicate()]} | {:error, map()}
  def normalize(nil), do: {:ok, []}

  def normalize(predicates) when is_list(predicates) do
    predicates
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {predicate, index}, {:ok, acc} ->
      case normalize_predicate(predicate) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, Map.update!(error, :path, &[index | &1])}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  def normalize(_predicates),
    do: error(:invalid_action_preconditions, [], "Action preconditions must be a list.")

  defp normalize_predicate({field, value}), do: predicate(field, :eq, value)
  defp normalize_predicate({comparator, field, value}), do: predicate(field, comparator, value)
  defp normalize_predicate([field, value]), do: predicate(field, :eq, value)
  defp normalize_predicate([comparator, field, value]), do: predicate(field, comparator, value)

  defp normalize_predicate(spec) when is_map(spec) and not is_struct(spec) do
    comparator = get(spec, :comparator) || get(spec, :operator) || get(spec, :op) || :eq
    predicate(get(spec, :field), comparator, get(spec, :value))
  end

  defp normalize_predicate(_predicate),
    do:
      error(
        :invalid_action_precondition,
        [],
        "Action preconditions must be filter tuples, JSON arrays, or filter maps."
      )

  defp predicate(field, comparator, value) do
    with {:ok, field} <- field(field),
         {:ok, comparator} <- comparator(comparator),
         :ok <- value(comparator, value) do
      {:ok, %{field: field, comparator: comparator, value: value}}
    end
  end

  defp field(field) when is_atom(field) and field not in [nil, true, false],
    do: {:ok, Atom.to_string(field)}

  defp field(field) when is_binary(field) and byte_size(field) > 0, do: {:ok, field}

  defp field(_field),
    do:
      error(
        :invalid_action_precondition_field,
        [:field],
        "Action precondition fields must be non-empty atoms or strings."
      )

  defp comparator(value) when value in [:eq, "eq", "="], do: {:ok, :eq}
  defp comparator(value) when value in [:neq, "neq", "!=", "<>"], do: {:ok, :neq}
  defp comparator(value) when value in [:gt, "gt", ">"], do: {:ok, :gt}
  defp comparator(value) when value in [:gte, "gte", ">="], do: {:ok, :gte}
  defp comparator(value) when value in [:lt, "lt", "<"], do: {:ok, :lt}
  defp comparator(value) when value in [:lte, "lte", "<="], do: {:ok, :lte}
  defp comparator(value) when value in [:in, "in"], do: {:ok, :in}

  defp comparator(_value),
    do:
      error(
        :invalid_action_precondition_comparator,
        [:comparator],
        "Action preconditions support eq, neq, gt, gte, lt, lte, and in comparators."
      )

  defp value(:in, values) when not is_list(values) or values == [],
    do:
      error(
        :invalid_action_precondition_value,
        [:value],
        "Action IN preconditions require a non-empty list."
      )

  defp value(_comparator, _value), do: :ok

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp error(code, path, message), do: {:error, %{code: code, path: path, message: message}}
end
