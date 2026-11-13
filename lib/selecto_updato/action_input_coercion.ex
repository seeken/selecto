defmodule SelectoUpdato.ActionInputCoercion do
  @moduledoc """
  Input coercion engine for Updato action planning.

  Normalizes submitted action inputs against declared input specs: scalar
  type coercion (booleans, integers, enums), collection inputs with
  snapshot or patch representations, identity/order validation, and
  uniqueness checks. Used by `SelectoUpdato.ActionPlanner` to turn raw
  intent payloads into planned input values.
  """

  import SelectoUpdato.ActionPlanner.Support

  @doc """
  Normalizes submitted inputs against the declared input specs.

  Options:

  - `:required?` - fail when a required input is missing
  - `:defaults?` - apply declared defaults for missing inputs
  """
  def normalize_values(input_specs, submitted_inputs, path, opts) do
    Enum.reduce_while(input_specs, {:ok, %{}}, fn input_spec, {:ok, acc} ->
      input_id = id(map_get(input_spec, :id))

      case input_value(input_spec, submitted_inputs, path ++ [input_id], opts) do
        {:ok, :skip} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, input_id, value)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc false
  def boolean_value(value) when value in [true, false], do: {:ok, value}
  def boolean_value(value) when value in ["true", "1", 1], do: {:ok, true}
  def boolean_value(value) when value in ["false", "0", 0], do: {:ok, false}
  def boolean_value(_value), do: :error

  defp input_value(input_spec, submitted_inputs, path, opts) do
    input_id = id(map_get(input_spec, :id))

    case fetch_value(submitted_inputs, input_id) do
      {:ok, value} ->
        normalize_input_value(input_spec, value, path, opts)

      :error ->
        cond do
          Keyword.get(opts, :defaults?, false) and has_key?(input_spec, :default) ->
            normalize_input_value(input_spec, map_get(input_spec, :default), path, opts)

          Keyword.get(opts, :required?, false) and truthy?(map_get(input_spec, :required)) ->
            {:error,
             error(
               :missing_required_action_input,
               path,
               "Action input #{inspect(input_id)} is required."
             )}

          true ->
            {:ok, :skip}
        end
    end
  end

  defp normalize_input_value(input_spec, value, path, opts) do
    with {:ok, normalized} <- coerce_input_value(input_spec, value, path, opts),
         :ok <- SelectoUpdato.RuleValidation.validate_inline(input_spec, normalized, path) do
      {:ok, normalized}
    end
  end

  defp coerce_input_value(input_spec, value, path, opts) do
    case id(map_get(input_spec, :type)) do
      "boolean" ->
        case boolean_value(value) do
          {:ok, value} ->
            {:ok, value}

          :error ->
            {:error,
             error(
               :invalid_action_input_type,
               path,
               "Action input #{inspect(List.last(path))} must be a boolean."
             )}
        end

      "integer" ->
        normalize_integer_value(value, path)

      "object_id" ->
        normalize_object_id_value(value, path)

      "enum" ->
        normalize_enum_value(input_spec, value, path)

      "collection" ->
        normalize_collection_input(input_spec, value, path, opts)

      _other ->
        {:ok, value}
    end
  end

  defp normalize_object_id_value(value, path) do
    if Selecto.Document.ObjectId.valid?(value) do
      {:ok, value}
    else
      {:error,
       error(
         :invalid_action_input_type,
         path,
         "Action input #{inspect(List.last(path))} must be a canonical tagged object_id."
       )}
    end
  end

  defp normalize_integer_value(value, _path) when is_integer(value), do: {:ok, value}

  defp normalize_integer_value(value, path) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        {:ok, integer}

      _other ->
        {:error,
         error(
           :invalid_action_input_type,
           path,
           "Action input #{inspect(List.last(path))} must be an integer."
         )}
    end
  end

  defp normalize_integer_value(_value, path) do
    {:error,
     error(
       :invalid_action_input_type,
       path,
       "Action input #{inspect(List.last(path))} must be an integer."
     )}
  end

  defp normalize_enum_value(input_spec, value, path) do
    allowed = Enum.map(list_value(input_spec, :values), &id/1)
    value_id = id(value)

    cond do
      allowed == [] ->
        {:ok, value}

      value_id in allowed ->
        {:ok, value_id}

      true ->
        {:error,
         error(
           :invalid_action_input_value,
           path,
           "Action input #{inspect(List.last(path))} must be one of the declared values.",
           value: value_id,
           allowed: allowed
         )}
    end
  end

  defp normalize_collection_input(input_spec, value, path, opts) when is_list(value) do
    with :ok <- validate_collection_size(input_spec, value, path) do
      value
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
        case normalize_collection_entry(input_spec, entry, path ++ [index], opts) do
          {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> then(fn
        {:ok, entries} -> validate_collection_uniqueness(input_spec, entries, path)
        {:error, error} -> {:error, error}
      end)
    end
  end

  defp normalize_collection_input(_input_spec, _value, path, _opts) do
    {:error,
     error(
       :invalid_action_input_type,
       path,
       "Collection action input #{inspect(List.last(path))} must be a list."
     )}
  end

  defp validate_collection_size(input_spec, value, path) do
    min_items = map_get(input_spec, :min_items)
    max_items = map_get(input_spec, :max_items)
    count = length(value)

    cond do
      is_integer(min_items) and count < min_items ->
        {:error,
         error(
           :too_few_collection_items,
           path,
           "Collection action input #{inspect(List.last(path))} has too few items.",
           min_items: min_items,
           count: count
         )}

      is_integer(max_items) and count > max_items ->
        {:error,
         error(
           :too_many_collection_items,
           path,
           "Collection action input #{inspect(List.last(path))} has too many items.",
           max_items: max_items,
           count: count
         )}

      true ->
        :ok
    end
  end

  defp normalize_collection_entry(input_spec, %{} = entry, path, opts) do
    representation = id(map_get(input_spec, :representation, "snapshot"))

    if representation == "patch" do
      normalize_patch_collection_entry(input_spec, entry, path, opts)
    else
      normalize_snapshot_collection_entry(input_spec, entry, path, opts)
    end
  end

  defp normalize_collection_entry(input_spec, entry, path, _opts) do
    if list_value(input_spec, :item) == [] do
      {:ok, entry}
    else
      {:error,
       error(
         :invalid_collection_item,
         path,
         "Collection action input items must be maps."
       )}
    end
  end

  defp normalize_patch_collection_entry(input_spec, entry, path, _opts) do
    with {:ok, op} <- collection_op(input_spec, entry, path),
         :ok <- validate_collection_identity(input_spec, entry, op, path),
         :ok <- validate_collection_order(input_spec, entry, op, path),
         {:ok, item_values} <- normalize_collection_item_values(input_spec, entry, op, path) do
      {:ok,
       entry
       |> control_values(input_spec)
       |> Map.put("op", op)
       |> Map.merge(item_values)
       |> compact_plan_map()}
    end
  end

  defp normalize_snapshot_collection_entry(input_spec, entry, path, _opts) do
    with :ok <- validate_collection_order(input_spec, entry, "snapshot", path),
         {:ok, item_values} <-
           normalize_values(list_value(input_spec, :item), entry, path,
             required?: true,
             defaults?: true
           ) do
      {:ok,
       entry
       |> control_values(input_spec)
       |> Map.merge(item_values)
       |> compact_plan_map()}
    end
  end

  defp collection_op(input_spec, entry, path) do
    allowed_ops = Enum.map(list_value(input_spec, :allowed_ops), &id/1)

    case fetch_first_value(entry, ["op", "operation"]) do
      {:ok, op} ->
        op = id(op)

        cond do
          allowed_ops == [] ->
            {:ok, op}

          op in allowed_ops ->
            {:ok, op}

          true ->
            {:error,
             error(
               :collection_operation_not_allowed,
               path ++ ["op"],
               "Collection operation #{inspect(op)} is not allowed.",
               value: op,
               allowed: allowed_ops
             )}
        end

      :error ->
        {:error,
         error(
           :missing_collection_operation,
           path ++ ["op"],
           "Patch collection items must include an operation."
         )}
    end
  end

  defp validate_collection_identity(input_spec, entry, op, path) do
    identity = map_get(input_spec, :identity, %{})
    identity_field = id(map_get(identity, :field, "id"))
    client_field = id(map_get(identity, :client_field, "client_id"))
    has_identity? = has_value?(entry, identity_field)
    has_client_identity? = has_value?(entry, client_field)

    cond do
      op in ["remove", "update", "reorder"] and not has_identity? ->
        {:error,
         error(
           :missing_collection_item_identity,
           path ++ [identity_field],
           "Collection operation #{inspect(op)} requires item identity."
         )}

      op == "add" and not (has_identity? or has_client_identity?) ->
        {:error,
         error(
           :missing_collection_item_identity,
           path ++ [client_field],
           "Collection add operations require item or client identity."
         )}

      true ->
        :ok
    end
  end

  defp validate_collection_order(input_spec, entry, op, path) do
    order = map_get(input_spec, :order, %{})
    order_field = id(map_get(order, :field))

    cond do
      order_field == "" ->
        :ok

      op == "reorder" and not has_value?(entry, order_field) ->
        {:error,
         error(
           :missing_collection_item_order,
           path ++ [order_field],
           "Collection reorder operations require an order value."
         )}

      not has_value?(entry, order_field) ->
        :ok

      id(map_get(order, :mode)) == "dense_integer" and
          not integer_value?(value!(entry, order_field)) ->
        {:error,
         error(
           :invalid_collection_item_order,
           path ++ [order_field],
           "Collection order #{inspect(order_field)} must be an integer."
         )}

      true ->
        :ok
    end
  end

  defp normalize_collection_item_values(_input_spec, _entry, op, _path)
       when op in ["remove", "reorder"] do
    {:ok, %{}}
  end

  defp normalize_collection_item_values(input_spec, entry, op, path) do
    normalize_values(list_value(input_spec, :item), entry, path,
      required?: op == "add",
      defaults?: op == "add"
    )
  end

  defp validate_collection_uniqueness(input_spec, entries, path) do
    if list_value(input_spec, :item) == [] do
      {:ok, entries}
    else
      validate_structured_collection_uniqueness(input_spec, entries, path)
    end
  end

  defp validate_structured_collection_uniqueness(input_spec, entries, path) do
    identity = map_get(input_spec, :identity, %{})
    order = map_get(input_spec, :order, %{})

    with :ok <-
           validate_unique_entry_value(
             entries,
             id(map_get(identity, :field, "id")),
             path,
             :duplicate_collection_item_identity,
             "Collection item identities must be unique."
           ),
         :ok <-
           validate_unique_entry_value(
             entries,
             id(map_get(identity, :client_field, "client_id")),
             path,
             :duplicate_collection_item_client_identity,
             "Collection item client identities must be unique."
           ),
         :ok <-
           validate_unique_entry_value(
             entries,
             id(map_get(order, :field)),
             path,
             :duplicate_collection_item_order,
             "Collection item order values must be unique."
           ) do
      {:ok, entries}
    end
  end

  defp validate_unique_entry_value(_entries, "", _path, _code, _message), do: :ok

  defp validate_unique_entry_value(entries, field, path, code, message) do
    values =
      entries
      |> Enum.map(&Map.get(&1, field))
      |> Enum.reject(&is_nil/1)

    if length(values) == length(Enum.uniq(values)) do
      :ok
    else
      {:error, error(code, path ++ [field], message)}
    end
  end

  defp control_values(entry, input_spec) do
    identity = map_get(input_spec, :identity, %{})
    order = map_get(input_spec, :order, %{})

    [
      id(map_get(identity, :field, "id")),
      id(map_get(identity, :client_field, "client_id")),
      id(map_get(order, :field))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn field, acc ->
      case fetch_value(entry, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end
end
