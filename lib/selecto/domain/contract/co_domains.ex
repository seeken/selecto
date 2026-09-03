defmodule Selecto.Domain.Contract.CoDomains do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core

  @definition_keys ~w(domain view segments projection ordering parameters search result)
  @search_keys ~w(fields configuration mode rank)
  @result_keys ~w(value_field label_field description_fields)
  @search_modes ~w(plain phrase websearch prefix)

  def validate(errors, co_domains) when is_map(co_domains) do
    Enum.reduce(co_domains, errors, fn {id, definition}, acc ->
      validate_definition(acc, id, definition, [:co_domains, id])
    end)
  end

  def validate(errors, co_domains) do
    [
      Core.error(
        :invalid_section_shape,
        [:co_domains],
        "domain section :co_domains must be a map",
        expected: :map,
        actual: Core.value_type(co_domains)
      )
      | errors
    ]
  end

  defp validate_definition(errors, id, definition, path) when is_map(definition) do
    errors
    |> require_identifier(id, path, :invalid_co_domain_id)
    |> reject_unknown(definition, @definition_keys, path)
    |> require_identifier(
      Core.map_value(definition, :domain),
      path ++ [:domain],
      :invalid_co_domain_domain
    )
    |> validate_shape(definition, path)
    |> validate_search(Core.map_value(definition, :search), path ++ [:search])
    |> validate_result(Core.map_value(definition, :result), path ++ [:result])
  end

  defp validate_definition(errors, id, definition, path) do
    [
      Core.error(:invalid_co_domain, path, "co-domain #{inspect(id)} must be a map",
        actual: Core.value_type(definition)
      )
      | errors
    ]
  end

  defp validate_shape(errors, definition, path) do
    view? = Core.has_key?(definition, :view)
    projection? = Core.has_key?(definition, :projection)

    errors =
      if view? == projection?,
        do: [
          Core.error(
            :invalid_co_domain_shape,
            path,
            "co-domain requires exactly one of view or projection"
          )
          | errors
        ],
        else: errors

    errors =
      if view?,
        do:
          require_identifier(
            errors,
            Core.map_value(definition, :view),
            path ++ [:view],
            :invalid_co_domain_view
          ),
        else:
          require_identifier(
            errors,
            Core.map_value(definition, :projection),
            path ++ [:projection],
            :invalid_co_domain_projection
          )

    errors = optional_identifier(errors, definition, :ordering, path)
    errors = optional_identifier_list(errors, definition, :segments, path)

    errors =
      if Core.has_key?(definition, :parameters) and
           not is_map(Core.map_value(definition, :parameters)),
         do: [
           Core.error(
             :invalid_co_domain_parameters,
             path ++ [:parameters],
             "co-domain parameters must be a map"
           )
           | errors
         ],
         else: errors

    if view? and (Core.has_key?(definition, :segments) or Core.has_key?(definition, :ordering)) do
      [
        Core.error(
          :invalid_co_domain_shape,
          path,
          "co-domain view cannot be combined with segments or ordering"
        )
        | errors
      ]
    else
      errors
    end
  end

  defp validate_search(errors, search, path) when is_map(search) do
    errors = reject_unknown(errors, search, @search_keys, path)
    fields = Core.map_value(search, :fields)
    errors = validate_nonempty_field_list(errors, fields, path ++ [:fields])
    mode = Core.map_value(search, :mode) || "plain"

    errors =
      if (is_atom(mode) or is_binary(mode)) and to_string(mode) in @search_modes,
        do: errors,
        else: [
          Core.error(
            :invalid_co_domain_search_mode,
            path ++ [:mode],
            "co-domain search mode is not supported"
          )
          | errors
        ]

    rank = Core.map_value(search, :rank)

    if is_nil(rank) or is_boolean(rank),
      do: errors,
      else: [
        Core.error(
          :invalid_co_domain_search_rank,
          path ++ [:rank],
          "co-domain search rank must be boolean"
        )
        | errors
      ]
  end

  defp validate_search(errors, _search, path),
    do: [Core.error(:invalid_co_domain_search, path, "co-domain search must be a map") | errors]

  defp validate_result(errors, result, path) when is_map(result) do
    errors
    |> reject_unknown(result, @result_keys, path)
    |> require_identifier(
      Core.map_value(result, :value_field),
      path ++ [:value_field],
      :invalid_co_domain_result_field,
      true
    )
    |> require_identifier(
      Core.map_value(result, :label_field),
      path ++ [:label_field],
      :invalid_co_domain_result_field,
      true
    )
    |> validate_optional_field_list(
      Core.map_value(result, :description_fields),
      path ++ [:description_fields]
    )
  end

  defp validate_result(errors, _result, path),
    do: [Core.error(:invalid_co_domain_result, path, "co-domain result must be a map") | errors]

  defp reject_unknown(errors, map, allowed, path) do
    Enum.reduce(Map.keys(map), errors, fn key, acc ->
      if to_string(key) in allowed,
        do: acc,
        else: [
          Core.error(
            :unknown_co_domain_key,
            path ++ [key],
            "unknown co-domain key #{inspect(key)}"
          )
          | acc
        ]
    end)
  end

  defp optional_identifier(errors, map, key, path) do
    if Core.has_key?(map, key),
      do:
        require_identifier(
          errors,
          Core.map_value(map, key),
          path ++ [key],
          :invalid_co_domain_reference
        ),
      else: errors
  end

  defp optional_identifier_list(errors, map, key, path) do
    if Core.has_key?(map, key) do
      case Core.map_value(map, key) do
        values when is_list(values) ->
          Enum.reduce(
            values,
            errors,
            &require_identifier(&2, &1, path ++ [key], :invalid_co_domain_reference)
          )

        _ ->
          [
            Core.error(
              :invalid_co_domain_reference,
              path ++ [key],
              "co-domain #{key} must be a list"
            )
            | errors
          ]
      end
    else
      errors
    end
  end

  defp validate_nonempty_field_list(errors, fields, path) when is_list(fields) and fields != [],
    do:
      Enum.reduce(
        fields,
        errors,
        &require_identifier(&2, &1, path, :invalid_co_domain_field, true)
      )

  defp validate_nonempty_field_list(errors, _fields, path),
    do: [
      Core.error(
        :invalid_co_domain_field,
        path,
        "co-domain search fields must be a non-empty list"
      )
      | errors
    ]

  defp validate_optional_field_list(errors, nil, _path), do: errors

  defp validate_optional_field_list(errors, fields, path) when is_list(fields),
    do:
      Enum.reduce(
        fields,
        errors,
        &require_identifier(&2, &1, path, :invalid_co_domain_result_field, true)
      )

  defp validate_optional_field_list(errors, _fields, path),
    do: [
      Core.error(
        :invalid_co_domain_result_field,
        path,
        "co-domain description fields must be a list"
      )
      | errors
    ]

  defp require_identifier(errors, value, path, code, dotted \\ false) do
    pattern =
      if dotted,
        do: ~r/^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/,
        else: ~r/^[a-z][a-z0-9_]*$/

    text = if is_atom(value) and not is_nil(value), do: Atom.to_string(value), else: value

    if is_binary(text) and Regex.match?(pattern, text),
      do: errors,
      else: [Core.error(code, path, "co-domain value must be a valid identifier") | errors]
  end
end
