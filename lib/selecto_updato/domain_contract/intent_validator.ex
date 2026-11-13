defmodule SelectoUpdato.DomainContract.IntentValidator do
  @moduledoc """
  Non-executing validator for Updato write/action intents.

  The validator checks a proposed intent against a
  `SelectoUpdato.DomainContract` document. It does not build an operation,
  changeset, query, write plan, or transaction.
  """

  @insert_operations ~w(insert)
  @update_operations ~w(update)
  @upsert_operations ~w(upsert)
  @delete_operations ~w(delete)
  @fieldless_operations @delete_operations

  @type diagnostic :: %{
          required(:code) => atom(),
          required(:path) => String.t(),
          required(:message) => String.t(),
          optional(:field) => String.t(),
          optional(:value) => term(),
          optional(:allowed) => [String.t()]
        }

  @type result :: %{valid?: boolean(), errors: [diagnostic()], warnings: [diagnostic()]}

  @spec validate(map(), map(), keyword()) :: result()
  def validate(contract, intent, opts \\ [])

  def validate(contract, intent, _opts) when is_map(contract) and is_map(intent) do
    indexes = indexes(contract)

    errors =
      cond do
        has_key?(intent, :operation) ->
          validate_operation_intent(intent, indexes)

        has_key?(intent, :action) ->
          validate_action_intent(intent, indexes)

        true ->
          [
            error(
              :missing_intent_target,
              "",
              "write intent must include operation or action"
            )
          ]
      end

    %{valid?: errors == [], errors: errors, warnings: []}
  end

  def validate(_contract, _intent, _opts) do
    %{
      valid?: false,
      errors: [error(:invalid_intent, "", "write intent must be a map")],
      warnings: []
    }
  end

  defp indexes(contract) do
    operations =
      contract
      |> map_get(:operations, [])
      |> list_or_empty()

    fields =
      contract
      |> map_get(:fields, [])
      |> list_or_empty()

    actions =
      contract
      |> map_get(:actions, [])
      |> list_or_empty()

    %{
      operations: Map.new(operations, &{string_id(map_get(&1, :id)), &1}),
      fields: Map.new(fields, &{string_id(map_get(&1, :id)), &1}),
      actions: Map.new(actions, &{string_id(map_get(&1, :id)), &1})
    }
  end

  defp validate_operation_intent(intent, indexes) do
    operation = string_id(map_get(intent, :operation))
    operation_spec = Map.get(indexes.operations, operation)
    allowed_operations = Map.keys(indexes.operations) |> Enum.sort()

    cond do
      is_nil(operation) or operation == "" ->
        [error(:invalid_operation, "operation", "operation must be a non-empty id")]

      is_nil(operation_spec) ->
        [
          error(:operation_not_found, "operation", "operation is not exposed by this contract",
            value: operation,
            allowed: allowed_operations
          )
        ]

      map_get(operation_spec, :enabled) == false ->
        [
          error(:operation_disabled, "operation", "operation is disabled by this contract",
            value: operation
          )
        ]

      true ->
        validate_operation_fields(intent, indexes, operation)
    end
  end

  defp validate_operation_fields(intent, indexes, operation) do
    field_ids = intent_field_ids(intent)

    cond do
      operation in @fieldless_operations and field_ids != [] ->
        [
          error(:fields_not_allowed, "fields", "operation does not accept write fields",
            value: field_ids
          )
        ]

      operation in @fieldless_operations ->
        []

      field_ids == [] ->
        []

      true ->
        Enum.flat_map(field_ids, &validate_operation_field(&1, operation, indexes))
    end
  end

  defp validate_operation_field(field_id, operation, indexes) do
    case Map.get(indexes.fields, field_id) do
      nil ->
        [
          error(:field_not_found, "fields", "field is not exposed by this contract",
            field: field_id,
            allowed: Map.keys(indexes.fields) |> Enum.sort()
          )
        ]

      field ->
        validate_field_writable(field, operation)
    end
  end

  defp validate_field_writable(field, operation) when operation in @insert_operations do
    if map_get(field, :insertable) == true do
      []
    else
      [field_error(:field_not_insertable, field, "field is not insertable")]
    end
  end

  defp validate_field_writable(field, operation) when operation in @update_operations do
    if map_get(field, :updatable) == true do
      []
    else
      [field_error(:field_not_updatable, field, "field is not updatable")]
    end
  end

  defp validate_field_writable(field, operation) when operation in @upsert_operations do
    if map_get(field, :insertable) == true or map_get(field, :updatable) == true do
      []
    else
      [field_error(:field_not_writable, field, "field is not writable for upsert")]
    end
  end

  defp validate_field_writable(_field, _operation), do: []

  defp validate_action_intent(intent, indexes) do
    action = string_id(map_get(intent, :action))
    action_spec = Map.get(indexes.actions, action)
    allowed_actions = Map.keys(indexes.actions) |> Enum.sort()

    cond do
      is_nil(action) or action == "" ->
        [error(:invalid_action, "action", "action must be a non-empty id")]

      is_nil(action_spec) ->
        [
          error(:action_not_found, "action", "action is not exposed by this contract",
            value: action,
            allowed: allowed_actions
          )
        ]

      true ->
        []
    end
  end

  defp intent_field_ids(intent) do
    cond do
      has_key?(intent, :fields) ->
        intent |> map_get(:fields) |> list_or_empty() |> Enum.map(&string_id/1)

      has_key?(intent, :attrs) ->
        intent |> map_get(:attrs) |> map_keys()

      has_key?(intent, :changes) ->
        intent |> map_get(:changes) |> map_keys()

      has_key?(intent, :set) ->
        intent |> map_get(:set) |> map_keys()

      true ->
        []
    end
  end

  defp map_keys(map) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.map(&string_id/1)
  end

  defp map_keys(_map), do: []

  defp field_error(code, field, message) do
    error(code, "fields", message, field: string_id(map_get(field, :id)))
  end

  defp error(code, path, message, attrs \\ []) do
    attrs
    |> Enum.into(%{code: code, path: path, message: message})
    |> compact()
  end

  defp compact(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, []} -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp has_key?(map, key) when is_map(map) and is_atom(key) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end

  defp has_key?(_map, _key), do: false

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default

  defp list_or_empty(nil), do: []
  defp list_or_empty(values) when is_list(values), do: values
  defp list_or_empty(value), do: [value]

  defp string_id(nil), do: nil
  defp string_id(value) when is_atom(value), do: Atom.to_string(value)
  defp string_id(value) when is_binary(value), do: value
  defp string_id(value), do: inspect(value)
end
