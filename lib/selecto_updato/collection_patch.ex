defmodule SelectoUpdato.CollectionPatch do
  @moduledoc """
  Collection patch normalization and operation planning for Updato actions.

  Turns declared `collection_patches` execution metadata plus normalized
  collection inputs into planned collection operations against a domain
  contract (relationship or field targets). Used by
  `SelectoUpdato.ActionPlanner`.
  """

  import SelectoUpdato.ActionPlanner.Support

  @doc """
  Normalizes the execution's `collection_patches` metadata into planned
  patches keyed by patch id.
  """
  def normalize_patches(contract, execution, input_specs, inputs) do
    case map_get(execution, :collection_patches, %{}) do
      patches when is_map(patches) ->
        patches
        |> sorted_entries()
        |> Enum.reduce_while({:ok, %{}}, fn {patch_id, patch_spec}, {:ok, acc} ->
          case normalize_patch(contract, patch_id, patch_spec, input_specs, inputs) do
            {:ok, id, patch} -> {:cont, {:ok, Map.put(acc, id, patch)}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      nil ->
        {:ok, %{}}

      _other ->
        {:error,
         error(
           :invalid_collection_patches,
           [:execution, :collection_patches],
           "Action execution collection_patches must be a map."
         )}
    end
  end

  @doc """
  Plans collection operations for normalized patches against the contract.
  """
  def operations(_contract, patches) when patches in [%{}, nil], do: {:ok, %{}}

  def operations(contract, patches) when is_map(patches) do
    patches
    |> sorted_entries()
    |> Enum.reduce_while({:ok, %{}}, fn {patch_id, patch}, {:ok, acc} ->
      case operation_plan(contract, patch_id, patch) do
        {:ok, id, operation_plan} -> {:cont, {:ok, Map.put(acc, id, operation_plan)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def operations(_contract, _patches) do
    {:error,
     error(
       :invalid_collection_patches,
       [:collection_patches],
       "Action collection patches must be a map before operation planning."
     )}
  end

  defp normalize_patch(_contract, patch_id, patch_spec, input_specs, inputs)
       when is_map(patch_spec) do
    source_input = id(map_get(patch_spec, :from_input, patch_id))

    with {:ok, input_spec} <- collection_input_spec(input_specs, source_input),
         {:ok, entries} <- collection_input_entries(inputs, source_input),
         {:ok, target} <- patch_target(patch_spec) do
      {:ok, id(patch_id),
       %{
         from_input: source_input,
         target: target,
         strategy:
           id(map_get(patch_spec, :strategy, map_get(input_spec, :representation, "snapshot"))),
         entries: entries
       }
       |> maybe_put(:identity, field_id_or_nil(map_get(patch_spec, :identity)))
       |> maybe_put(:order_field, field_id_or_nil(map_get(patch_spec, :order_field)))}
    end
  end

  defp normalize_patch(_contract, patch_id, _patch_spec, _input_specs, _inputs) do
    {:error,
     error(
       :invalid_collection_patch,
       [:execution, :collection_patches, id(patch_id)],
       "Collection patch metadata must be a map."
     )}
  end

  defp collection_input_spec(input_specs, source_input) do
    input_spec = Enum.find(input_specs, &(id(map_get(&1, :id)) == source_input))

    cond do
      is_nil(input_spec) ->
        {:error,
         error(
           :unknown_collection_patch_input,
           [:execution, :collection_patches, source_input],
           "Collection patch references an unknown action input."
         )}

      id(map_get(input_spec, :type)) != "collection" ->
        {:error,
         error(
           :invalid_collection_patch_input,
           [:execution, :collection_patches, source_input],
           "Collection patch input #{inspect(source_input)} is not a collection."
         )}

      true ->
        {:ok, input_spec}
    end
  end

  defp collection_input_entries(inputs, source_input) do
    case fetch_value(inputs, source_input) do
      {:ok, entries} when is_list(entries) ->
        {:ok, entries}

      {:ok, _other} ->
        {:error,
         error(
           :invalid_collection_patch_input,
           [:intent, :inputs, source_input],
           "Collection patch input #{inspect(source_input)} must be a normalized list."
         )}

      :error ->
        {:error,
         error(
           :missing_collection_patch_input,
           [:intent, :inputs, source_input],
           "Collection patch input #{inspect(source_input)} is required by the selected execution."
         )}
    end
  end

  defp patch_target(patch_spec) do
    case normalize_target(map_get(patch_spec, :target)) do
      {:ok, target} ->
        {:ok, target}

      :error ->
        {:error,
         error(
           :invalid_collection_patch_target,
           [:execution, :collection_patches, :target],
           "Collection patch target must be {:relationship, id}, {:field, id}, or a JSON-safe equivalent."
         )}
    end
  end

  defp normalize_target({kind, id}), do: normalize_target([kind, id])

  defp normalize_target([kind, target_id]) do
    case id(kind) do
      "relationship" -> {:ok, {:relationship, id(target_id)}}
      "field" -> {:ok, {:field, id(target_id)}}
      _other -> :error
    end
  end

  defp normalize_target(_target), do: :error

  defp operation_plan(contract, patch_id, patch) do
    with {:ok, target} <- operation_target(contract, patch_id, map_get(patch, :target)),
         {:ok, operations} <- entry_operations(target, patch_id, patch) do
      {:ok, id(patch_id),
       %{
         from_input: map_get(patch, :from_input),
         target: map_get(patch, :target),
         target_kind: Map.fetch!(target, :kind),
         strategy: map_get(patch, :strategy),
         operations: operations,
         requires_host_scope: true
       }
       |> maybe_put(:relationship, Map.get(target, :relationship))
       |> maybe_put(:field, Map.get(target, :field))
       |> maybe_put(:ownership, Map.get(target, :ownership))}
    end
  end

  defp operation_target(contract, patch_id, {:relationship, relationship}) do
    relationship = id(relationship)

    case contract_entry(contract, :relationships, relationship) do
      nil ->
        {:error,
         error(
           :unknown_collection_patch_relationship,
           [:collection_patches, id(patch_id), :target],
           "Collection patch references unknown relationship #{inspect(relationship)}."
         )}

      relationship_spec ->
        if map_get(relationship_spec, :writable) == false do
          {:error,
           error(
             :collection_patch_target_not_writable,
             [:collection_patches, id(patch_id), :target],
             "Collection patch relationship #{inspect(relationship)} is not writable."
           )}
        else
          {:ok,
           %{
             kind: :relationship,
             relationship: relationship,
             allowed_ops: Enum.map(list_value(relationship_spec, :allowed_ops), &id/1),
             ownership: map_get(relationship_spec, :ownership)
           }}
        end
    end
  end

  defp operation_target(contract, patch_id, {:field, field}) do
    field = id(field)

    case contract_entry(contract, :fields, field) do
      nil ->
        {:error,
         error(
           :unknown_collection_patch_field,
           [:collection_patches, id(patch_id), :target],
           "Collection patch references unknown field #{inspect(field)}."
         )}

      field_spec ->
        if map_get(field_spec, :updatable) == false do
          {:error,
           error(
             :collection_patch_target_not_writable,
             [:collection_patches, id(patch_id), :target],
             "Collection patch field #{inspect(field)} is not writable."
           )}
        else
          {:ok, %{kind: :field, field: field, allowed_ops: []}}
        end
    end
  end

  defp operation_target(_contract, patch_id, _target) do
    {:error,
     error(
       :invalid_collection_patch_target,
       [:collection_patches, id(patch_id), :target],
       "Collection patch target must be normalized before operation planning."
     )}
  end

  defp entry_operations(target, patch_id, patch) do
    patch
    |> map_get(:entries, [])
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case entry_operation(target, patch_id, patch, entry, index) do
        {:ok, operation} -> {:cont, {:ok, acc ++ [operation]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp entry_operation(target, patch_id, patch, entry, index) do
    source_op = Map.fetch!(entry, "op")
    action = entry_action(source_op)

    with :ok <- validate_target_action(target, patch_id, source_op, action, index) do
      {:ok,
       %{
         action: action,
         source_op: source_op
       }
       |> maybe_put(:identity, entry_identity(patch, entry))
       |> maybe_put(:client_identity, entry_client_identity(entry))
       |> maybe_put(:attrs, entry_attrs(patch, entry, source_op))
       |> maybe_put(:changes, entry_changes(patch, entry, source_op))}
    end
  end

  defp entry_action("add"), do: :insert
  defp entry_action("remove"), do: :delete
  defp entry_action("update"), do: :update
  defp entry_action("reorder"), do: :update

  defp validate_target_action(target, patch_id, source_op, action, index) do
    allowed_ops = Map.get(target, :allowed_ops, [])
    action_id = id(action)

    if allowed_ops == [] or action_id in allowed_ops do
      :ok
    else
      {:error,
       error(
         :collection_operation_not_allowed_for_target,
         [:collection_patches, id(patch_id), :entries, index, :op],
         "Collection operation #{inspect(source_op)} maps to #{inspect(action_id)}, which the target does not allow.",
         value: source_op,
         target_operation: action_id,
         allowed: allowed_ops
       )}
    end
  end

  defp entry_identity(patch, entry) do
    identity_field = id(map_get(patch, :identity, "id"))
    Map.get(entry, identity_field)
  end

  defp entry_client_identity(entry), do: Map.get(entry, "client_id")

  defp entry_attrs(patch, entry, "add") do
    Map.drop(entry, control_fields(patch, include_order?: false))
  end

  defp entry_attrs(_patch, _entry, _source_op), do: nil

  defp entry_changes(patch, entry, "update") do
    Map.drop(entry, control_fields(patch, include_order?: false))
  end

  defp entry_changes(patch, entry, "reorder") do
    order_field = id(map_get(patch, :order_field))

    if order_field == "" do
      %{}
    else
      %{order_field => Map.get(entry, order_field)}
    end
  end

  defp entry_changes(_patch, _entry, _source_op), do: nil

  defp control_fields(patch, opts) do
    order_fields =
      if Keyword.get(opts, :include_order?, true) do
        [id(map_get(patch, :order_field))]
      else
        []
      end

    ["op", id(map_get(patch, :identity, "id")), "client_id"] ++ order_fields
  end
end
