defmodule Selecto.Domain.Contract.Events do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core

  @supported_types ~w(any boolean enum integer list map number string uuid)

  def validate(errors, events) when is_map(events) do
    Enum.reduce(events, errors, fn {event_id, spec}, acc ->
      path = [:events, event_id]

      acc
      |> validate_event_id(event_id, path)
      |> validate_event_spec(event_id, spec, path)
    end)
  end

  def validate(errors, events) do
    [
      Core.error(
        :invalid_section_shape,
        [:events],
        "domain section :events must be a map",
        expected: :map,
        actual: Core.value_type(events)
      )
      | errors
    ]
  end

  defp validate_event_id(errors, event_id, _path)
       when (is_atom(event_id) or is_binary(event_id)) and event_id not in ["", nil],
       do: errors

  defp validate_event_id(errors, event_id, path) do
    [
      Core.error(
        :invalid_event_id,
        path,
        "event ids must be non-empty atoms or strings",
        event: event_id
      )
      | errors
    ]
  end

  defp validate_event_spec(errors, event_id, spec, path) when is_map(spec) do
    errors
    |> validate_schema_version(event_id, Core.map_value(spec, :schema_version), path)
    |> validate_data(event_id, Core.map_value(spec, :data), path)
    |> validate_additional_fields(event_id, Core.map_value(spec, :additional_fields), path)
  end

  defp validate_event_spec(errors, event_id, spec, path) do
    [
      Core.error(
        :invalid_event_spec,
        path,
        "event #{inspect(event_id)} must be a map",
        event: event_id,
        actual: Core.value_type(spec)
      )
      | errors
    ]
  end

  defp validate_schema_version(errors, _event_id, version, _path)
       when is_integer(version) and version > 0,
       do: errors

  defp validate_schema_version(errors, event_id, version, path) do
    [
      Core.error(
        :invalid_event_schema_version,
        path ++ [:schema_version],
        "event #{inspect(event_id)} schema_version must be a positive integer",
        event: event_id,
        actual: version
      )
      | errors
    ]
  end

  defp validate_data(errors, event_id, data, path) when is_map(data) do
    Enum.reduce(data, errors, fn {field_id, spec}, acc ->
      field_path = path ++ [:data, field_id]

      acc
      |> validate_field_id(event_id, field_id, field_path)
      |> validate_field_spec(event_id, field_id, spec, field_path)
    end)
  end

  defp validate_data(errors, event_id, data, path) do
    [
      Core.error(
        :invalid_event_data_contract,
        path ++ [:data],
        "event #{inspect(event_id)} data must be a map",
        event: event_id,
        actual: Core.value_type(data)
      )
      | errors
    ]
  end

  defp validate_field_id(errors, _event_id, field_id, _path)
       when (is_atom(field_id) or is_binary(field_id)) and field_id not in ["", nil],
       do: errors

  defp validate_field_id(errors, event_id, field_id, path) do
    [
      Core.error(
        :invalid_event_field_id,
        path,
        "event field ids must be non-empty atoms or strings",
        event: event_id,
        field: field_id
      )
      | errors
    ]
  end

  defp validate_field_spec(errors, event_id, field_id, type, path)
       when is_atom(type) or is_binary(type) do
    validate_field_type(errors, event_id, field_id, type, path)
  end

  defp validate_field_spec(errors, event_id, field_id, spec, path) when is_map(spec) do
    errors
    |> validate_field_type(event_id, field_id, Core.map_value(spec, :type) || :any, path)
    |> validate_boolean_option(
      event_id,
      field_id,
      :required,
      Core.map_value(spec, :required),
      path
    )
    |> validate_boolean_option(
      event_id,
      field_id,
      :nullable,
      Core.map_value(spec, :nullable),
      path
    )
    |> validate_enum_values(event_id, field_id, spec, path)
    |> validate_list_item(event_id, field_id, spec, path)
  end

  defp validate_field_spec(errors, event_id, field_id, spec, path) do
    [
      Core.error(
        :invalid_event_field_spec,
        path,
        "event field specification must be a type or map",
        event: event_id,
        field: field_id,
        actual: Core.value_type(spec)
      )
      | errors
    ]
  end

  defp validate_field_type(errors, event_id, field_id, type, path) do
    if type_id(type) in @supported_types do
      errors
    else
      [
        Core.error(
          :unsupported_event_field_type,
          path ++ [:type],
          "event field uses an unsupported type",
          event: event_id,
          field: field_id,
          actual: type,
          supported: @supported_types
        )
        | errors
      ]
    end
  end

  defp validate_boolean_option(errors, _event_id, _field_id, _key, value, _path)
       when value in [nil, true, false],
       do: errors

  defp validate_boolean_option(errors, event_id, field_id, key, value, path) do
    [
      Core.error(
        :invalid_event_field_option,
        path ++ [key],
        "event field #{inspect(key)} option must be boolean",
        event: event_id,
        field: field_id,
        option: key,
        actual: value
      )
      | errors
    ]
  end

  defp validate_enum_values(errors, event_id, field_id, spec, path) do
    if type_id(Core.map_value(spec, :type) || :any) == "enum" and
         not is_list(Core.map_value(spec, :values)) do
      [
        Core.error(
          :invalid_event_enum,
          path ++ [:values],
          "enum event fields must declare a values list",
          event: event_id,
          field: field_id
        )
        | errors
      ]
    else
      errors
    end
  end

  defp validate_list_item(errors, event_id, field_id, spec, path) do
    type = type_id(Core.map_value(spec, :type) || :any)
    item = Core.map_value(spec, :item)

    cond do
      type == "list" and is_nil(item) ->
        errors

      type == "list" ->
        validate_field_spec(errors, event_id, "#{field_id}[]", item, path ++ [:item])

      not is_nil(item) ->
        [
          Core.error(
            :event_item_on_non_list,
            path ++ [:item],
            "only list event fields may declare an item contract",
            event: event_id,
            field: field_id,
            type: type
          )
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_additional_fields(errors, _event_id, value, _path)
       when value in [nil, true, false],
       do: errors

  defp validate_additional_fields(errors, event_id, value, path) do
    [
      Core.error(
        :invalid_event_additional_fields,
        path ++ [:additional_fields],
        "event additional_fields must be boolean",
        event: event_id,
        actual: value
      )
      | errors
    ]
  end

  defp type_id(type) when is_atom(type) or is_binary(type), do: to_string(type)
  defp type_id(_type), do: nil
end
