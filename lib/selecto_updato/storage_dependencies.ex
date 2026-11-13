defmodule SelectoUpdato.StorageDependencies do
  @moduledoc false

  # Prospective availability is independent of enforcement and applicability.
  # Collect every consumed branch before evaluating conditions or logical tests.
  def storage?(rules, operation), do: active_bindings(rules, operation) != []

  def fields(rules, operation, all_fields) do
    rules
    |> active_bindings(operation)
    |> Enum.flat_map(fn {_id, binding} ->
      definition = Map.fetch!(rules.definitions, binding.rule.id)

      roots(binding.subject.path, all_fields) ++
        references(definition.test, all_fields) ++ references(binding.condition, all_fields)
    end)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def collection_fields(rules, operation, relationship, all_fields) do
    dependencies =
      rules
      |> active_bindings(operation)
      |> Enum.flat_map(fn {_id, binding} ->
        definition = Map.fetch!(rules.definitions, binding.rule.id)

        collection_node(definition.test, relationship, all_fields) ++
          collection_node(binding.condition, relationship, all_fields)
      end)

    if Enum.any?(dependencies, &is_tuple/1),
      do: :unavailable,
      else: dependencies |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()
  end

  defp active_bindings(rules, operation) do
    Enum.filter(rules.bindings, fn {_id, binding} ->
      binding.stage in ["candidate", "transaction", "evidence"] and
        (binding.operations == [] or to_string(operation) in binding.operations)
    end)
  end

  defp collection_node(nil, _relationship, _fields), do: []

  defp collection_node(%{"op" => op}, _relationship, _fields)
       when op in [
              "collection.count",
              "type.is",
              "presence.required",
              "presence.non_null",
              "presence.absent"
            ],
       do: []

  defp collection_node(%{"op" => "collection.sum", "path" => path}, _relationship, fields),
    do: roots(path, fields)

  defp collection_node(
         %{"op" => "collection.unique_by", "paths" => paths},
         _relationship,
         fields
       ),
       do: Enum.flat_map(paths, &roots(&1, fields))

  defp collection_node(%{"op" => op, "rules" => rules}, relationship, fields)
       when op in ["all", "any"],
       do: Enum.flat_map(rules, &collection_node(&1, relationship, fields))

  defp collection_node(%{"op" => "not", "rule" => rule}, relationship, fields),
    do: collection_node(rule, relationship, fields)

  defp collection_node(
         %{"op" => "path.test", "path" => [relationship], "test" => test},
         relationship,
         fields
       ),
       do: collection_node(test, relationship, fields)

  defp collection_node(%{"op" => op, "path" => path}, _relationship, fields)
       when op in ["path.test", "value.compare_path", "temporal.compare_path"],
       do: [{:unavailable_root_context, path, fields}]

  defp collection_node(_test, _relationship, fields), do: fields

  defp roots([], all_fields), do: all_fields
  defp roots([field | _], _all_fields), do: [field]

  defp references(nil, _all_fields), do: []

  defp references(%{"op" => op, "path" => path} = test, all_fields)
       when op in ["path.test", "value.compare_path", "temporal.compare_path"] do
    roots(path, all_fields) ++ children(test, all_fields)
  end

  defp references(test, all_fields), do: children(test, all_fields)

  defp children(%{"op" => op, "rules" => rules}, all_fields) when op in ["all", "any"],
    do: Enum.flat_map(rules, &references(&1, all_fields))

  defp children(%{"op" => "not", "rule" => rule}, all_fields),
    do: references(rule, all_fields)

  defp children(%{"op" => "path.test", "test" => test}, all_fields),
    do: references(test, all_fields)

  defp children(%{"op" => "object.shape", "properties" => properties}, all_fields),
    do: Enum.flat_map(properties, fn {_key, test} -> references(test, all_fields) end)

  defp children(_, _all_fields), do: []
end
