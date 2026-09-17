defmodule Selecto.Domain.Contract.Editors do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core

  @editor_keys ~w(label description fields actions submit_label)
  @field_keys ~w(field label control required nullable rows placeholder options)
  @controls ~w(text textarea number date datetime-local checkbox select)

  def validate(errors, editors, _writes, _actions, _source) when editors == %{}, do: errors

  def validate(errors, editors, writes, actions, source) when is_map(editors) do
    Enum.reduce(editors, errors, fn {editor_id, editor}, acc ->
      validate_editor(acc, editor_id, editor, writes, actions, source)
    end)
  end

  def validate(errors, editors, _writes, _actions, _source) do
    [
      Core.error(:invalid_editors, [:editors], "editors must be a map",
        expected: :map,
        actual: Core.value_type(editors)
      )
      | errors
    ]
  end

  defp validate_editor(errors, id, editor, writes, actions, source) when is_map(editor) do
    path = [:editors, id]
    update = fetch(get(writes, :operations), :update)
    fields = get(editor, :fields)

    errors
    |> identifier(id, path, :invalid_editor_id)
    |> reject_unknown(editor, @editor_keys, path)
    |> require_enabled_update(update, path)
    |> optional_string(get(editor, :label), path ++ [:label])
    |> optional_string(get(editor, :description), path ++ [:description])
    |> optional_string(get(editor, :submit_label), path ++ [:submit_label])
    |> validate_fields(fields, writes, source, path)
    |> validate_actions(get(editor, :actions) || [], actions, path)
  end

  defp validate_editor(errors, id, editor, _writes, _actions, _source) do
    [
      Core.error(:invalid_editor, [:editors, id], "editor definitions must be maps",
        actual: Core.value_type(editor)
      )
      | errors
    ]
  end

  defp require_enabled_update(errors, update, path) do
    if is_map(update) and get(update, :enabled) == true do
      errors
    else
      [
        Core.error(
          :editor_update_not_enabled,
          path,
          "editors require an enabled update write operation"
        )
        | errors
      ]
    end
  end

  defp validate_fields(errors, fields, writes, source, path)
       when is_list(fields) and fields != [] do
    {errors, _seen} =
      fields
      |> Enum.with_index()
      |> Enum.reduce({errors, MapSet.new()}, fn {raw, index}, {acc, seen} ->
        entry = if is_atom(raw) or is_binary(raw), do: %{field: raw}, else: raw
        field_path = path ++ [:fields, index]

        if is_map(entry) do
          field = get(entry, :field)
          field_id = field_id(field)
          duplicated = field_id != nil and MapSet.member?(seen, field_id)
          seen = if field_id, do: MapSet.put(seen, field_id), else: seen

          acc =
            acc
            |> reject_unknown(entry, @field_keys, field_path)
            |> identifier(field, field_path ++ [:field], :invalid_editor_field)
            |> duplicate(duplicated, field, field_path)
            |> public_root_field(field, source, field_path)
            |> updatable(field, writes, field_path)
            |> optional_string(get(entry, :label), field_path ++ [:label])
            |> optional_string(get(entry, :placeholder), field_path ++ [:placeholder])
            |> control(get(entry, :control), field_path)
            |> boolean(get(entry, :required), field_path ++ [:required])
            |> boolean(get(entry, :nullable), field_path ++ [:nullable])
            |> rows(get(entry, :rows), field_path)
            |> options(get(entry, :options), field_path)

          {acc, seen}
        else
          {[
             Core.error(
               :invalid_editor_field,
               field_path,
               "editor fields must be identifiers or maps",
               actual: Core.value_type(entry)
             )
             | acc
           ], seen}
        end
      end)

    errors
  end

  defp validate_fields(errors, fields, _writes, _source, path) do
    [
      Core.error(
        :invalid_editor_fields,
        path ++ [:fields],
        "editor fields must be a non-empty list",
        actual: Core.value_type(fields)
      )
      | errors
    ]
  end

  defp validate_actions(errors, action_ids, actions, path) when is_list(action_ids) do
    Enum.reduce(Enum.uniq(action_ids), errors, fn action_id, acc ->
      action = fetch(actions, action_id)
      selection = if is_map(action), do: get(action, :selection) || %{}, else: %{}

      cond do
        field_id(action_id) == nil ->
          [
            Core.error(
              :invalid_editor_action,
              path ++ [:actions],
              "editor actions must be identifiers"
            )
            | acc
          ]

        not is_map(action) ->
          [
            Core.error(
              :editor_action_not_found,
              path ++ [:actions],
              "editor action is not published",
              action: action_id
            )
            | acc
          ]

        get(selection, :mode) in [:groups, "groups"] ->
          [
            Core.error(
              :invalid_editor_action,
              path ++ [:actions],
              "editor actions must accept row targets",
              action: action_id
            )
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp validate_actions(errors, actions, _published, path) do
    [
      Core.error(:invalid_editor_actions, path ++ [:actions], "editor actions must be a list",
        actual: Core.value_type(actions)
      )
      | errors
    ]
  end

  defp public_root_field(errors, field, source, path) do
    column = fetch(get(source, :columns), field)

    if is_map(column) and get(column, :internal) != true do
      errors
    else
      [
        Core.error(:editor_field_not_public, path, "editor fields must be public root fields",
          field: field
        )
        | errors
      ]
    end
  end

  defp updatable(errors, field, writes, path) do
    spec = fetch(get(writes, :fields), field)

    if is_map(spec) and get(spec, :updatable) == true do
      errors
    else
      [
        Core.error(:editor_field_not_updatable, path, "editor fields must be updatable",
          field: field
        )
        | errors
      ]
    end
  end

  defp duplicate(errors, false, _field, _path), do: errors

  defp duplicate(errors, true, field, path),
    do: [
      Core.error(:duplicate_editor_field, path, "editor fields must be unique", field: field)
      | errors
    ]

  defp control(errors, nil, _path), do: errors
  defp control(errors, value, _path) when value in @controls, do: errors

  defp control(errors, value, path) when is_atom(value),
    do: control(errors, Atom.to_string(value), path)

  defp control(errors, value, path),
    do: [
      Core.error(:invalid_editor_control, path ++ [:control], "editor control is not available",
        control: value
      )
      | errors
    ]

  defp boolean(errors, nil, _path), do: errors
  defp boolean(errors, value, _path) when is_boolean(value), do: errors

  defp boolean(errors, value, path),
    do: [
      Core.error(:invalid_editor_boolean, path, "editor setting must be boolean", actual: value)
      | errors
    ]

  defp rows(errors, nil, _path), do: errors
  defp rows(errors, value, _path) when is_integer(value) and value in 2..20, do: errors

  defp rows(errors, value, path),
    do: [
      Core.error(:invalid_editor_rows, path ++ [:rows], "editor rows must be from 2 to 20",
        actual: value
      )
      | errors
    ]

  defp options(errors, nil, _path), do: errors

  defp options(errors, values, path) when is_list(values) and values != [] do
    Enum.with_index(values)
    |> Enum.reduce(errors, fn {option, index}, acc ->
      option_path = path ++ [:options, index]

      if is_map(option) and scalar?(get(option, :value)) and
           non_empty_string?(get(option, :label)) and
           Enum.all?(Map.keys(option), &(to_string(&1) in ~w(value label))) do
        acc
      else
        [
          Core.error(
            :invalid_editor_option,
            option_path,
            "editor options require scalar value and non-empty label"
          )
          | acc
        ]
      end
    end)
  end

  defp options(errors, values, path),
    do: [
      Core.error(
        :invalid_editor_options,
        path ++ [:options],
        "editor options must be a non-empty list",
        actual: Core.value_type(values)
      )
      | errors
    ]

  defp optional_string(errors, nil, _path), do: errors
  defp optional_string(errors, value, _path) when is_binary(value) and value != "", do: errors

  defp optional_string(errors, value, path),
    do: [
      Core.error(:invalid_editor_string, path, "editor setting must be a non-empty string",
        actual: value
      )
      | errors
    ]

  defp identifier(errors, value, path, code) do
    if field_id(value),
      do: errors,
      else: [Core.error(code, path, "value must be an identifier", actual: value) | errors]
  end

  defp reject_unknown(errors, value, allowed, path) do
    unknown = Enum.reject(Map.keys(value), &(to_string(&1) in allowed))

    if unknown == [],
      do: errors,
      else: [
        Core.error(:unknown_editor_property, path, "editor contains unknown properties",
          properties: unknown
        )
        | errors
      ]
  end

  defp fetch(value, key) when is_map(value) do
    Enum.find_value(value, fn {candidate, entry} ->
      if field_id(candidate) == field_id(key), do: entry
    end)
  end

  defp fetch(_, _), do: nil
  defp get(value, key) when is_map(value), do: Map.get(value, key, Map.get(value, to_string(key)))
  defp get(_, _), do: nil
  defp field_id(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)

  defp field_id(value) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, value), do: value
  end

  defp field_id(_), do: nil

  defp scalar?(value),
    do: is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value)

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
