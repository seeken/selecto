defmodule Selecto.Domain.EditorNormalization do
  @moduledoc false

  alias Selecto.Domain.Shared.Map, as: MapHelpers

  def normalize(domain) do
    domain
    |> normalize_section(:editors, &normalize_editor/1)
    |> normalize_section(:detail_actions, &normalize_action(&1, domain))
  end

  defp normalize_section(domain, key, normalize) do
    case MapHelpers.fetch_section(domain, key) do
      {:ok, section} when is_map(section) ->
        MapHelpers.put_section(
          domain,
          key,
          Map.new(section, fn {id, value} -> {id, normalize.(value)} end)
        )

      _ ->
        domain
    end
  end

  defp normalize_editor(editor) when is_map(editor) do
    editor
    |> normalize_list(:fields, fn
      field when is_atom(field) or is_binary(field) -> %{field: field}
      entry -> entry
    end)
    |> deduplicate(:actions)
  end

  defp normalize_editor(editor), do: editor

  defp normalize_action(action, domain) when is_map(action) do
    if MapHelpers.map_value(action, :type) in [:record_editor, "record_editor"] do
      action = deduplicate(action, :required_fields)
      source = MapHelpers.section(domain, :source, %{})

      case MapHelpers.map_value(action, :payload) do
        payload when is_map(payload) ->
          payload =
            payload
            |> default(:target_field, MapHelpers.map_value(source, :primary_key) || :id)
            |> default(:title, MapHelpers.map_value(action, :name))
            |> default(:size, "lg")
            |> default_navigation()

          MapHelpers.put_map_value(action, :payload, payload)

        _ ->
          action
      end
    else
      action
    end
  end

  defp normalize_action(action, _domain), do: action

  defp default_navigation(payload) do
    if MapHelpers.has_key_variant?(payload, :navigation_enabled),
      do: payload,
      else: MapHelpers.put_map_value(payload, :navigation_enabled, true)
  end

  defp default(map, key, value) do
    if is_nil(MapHelpers.map_value(map, key)),
      do: MapHelpers.put_map_value(map, key, value),
      else: map
  end

  defp normalize_list(map, key, normalize) do
    case MapHelpers.map_value(map, key) do
      values when is_list(values) ->
        MapHelpers.put_map_value(map, key, Enum.map(values, normalize))

      _ ->
        map
    end
  end

  defp deduplicate(map, key) do
    case MapHelpers.map_value(map, key) do
      values when is_list(values) ->
        values = Enum.uniq_by(values, &identifier/1)
        MapHelpers.put_map_value(map, key, values)

      _ ->
        map
    end
  end

  defp identifier(value) when is_atom(value) or is_binary(value), do: {:id, to_string(value)}
  defp identifier(value), do: {:invalid, value}
end
