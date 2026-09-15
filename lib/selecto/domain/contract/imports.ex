defmodule Selecto.Domain.Contract.Imports do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core

  @contract_keys ~w(contract_version enabled field_policy fields actions key_sets idempotency)
  @mapping_keys ~w(sources header_aliases transforms blank_policy trusted_provider match_only)
  @action_mapping_keys ~w(sources header_aliases transforms blank_policy trusted_provider)
  @key_set_keys ~w(id label fields cardinality allowed_on_match allowed_on_missing default_on_match default_on_missing)
  @sources ~w(column static parameter trusted)
  @transforms ~w(trim uppercase lowercase normalize_whitespace empty_to_null)
  @blank_policies ~w(omit empty null error)
  @match_decisions ~w(update skip error)
  @missing_decisions ~w(insert skip error)

  def validate(errors, imports, _source, _writes, _actions) when imports == %{}, do: errors

  def validate(errors, imports, source, writes, actions) when is_map(imports) do
    source_fields = source |> Core.relation_fields() |> MapSet.new()

    errors
    |> reject_unknown(imports, @contract_keys, [:imports])
    |> require_contract_version(imports)
    |> require_enabled(imports)
    |> require_declared_only(imports)
    |> validate_fields(Core.map_value(imports, :fields), source_fields, writes)
    |> validate_actions(Core.map_value(imports, :actions), actions)
    |> validate_key_sets(Core.map_value(imports, :key_sets), Core.map_value(imports, :fields))
    |> validate_idempotency(Core.map_value(imports, :idempotency))
  end

  def validate(errors, imports, _source, _writes, _actions) do
    [
      Core.error(
        :invalid_section_shape,
        [:imports],
        "domain section :imports must be a map",
        expected: :map,
        actual: Core.value_type(imports)
      )
      | errors
    ]
  end

  defp require_contract_version(errors, imports) do
    if Core.map_value(imports, :contract_version) == 1 do
      errors
    else
      [
        Core.error(
          :invalid_import_contract_version,
          [:imports, :contract_version],
          "imports.contract_version must be 1",
          expected: 1,
          actual: Core.map_value(imports, :contract_version)
        )
        | errors
      ]
    end
  end

  defp require_enabled(errors, imports) do
    case Core.map_value(imports, :enabled) do
      true ->
        errors

      value ->
        [
          Core.error(
            :invalid_import_enabled,
            [:imports, :enabled],
            "a published imports contract must set enabled to true",
            expected: true,
            actual: value
          )
          | errors
        ]
    end
  end

  defp require_declared_only(errors, imports) do
    if Core.enum_value?(Core.map_value(imports, :field_policy), [:declared_only]) do
      errors
    else
      [
        Core.error(
          :invalid_import_field_policy,
          [:imports, :field_policy],
          "imports.field_policy must be declared_only",
          expected: :declared_only,
          actual: Core.map_value(imports, :field_policy)
        )
        | errors
      ]
    end
  end

  defp validate_fields(errors, fields, source_fields, writes)
       when is_map(fields) and map_size(fields) > 0 do
    Enum.reduce(fields, errors, fn {field, spec}, acc ->
      path = [:imports, :fields, field]

      acc
      |> validate_identifier(field, path, :invalid_import_field_id, "import field ids")
      |> validate_root_field(field, source_fields, path)
      |> validate_field_spec(field, spec, writes, path)
    end)
  end

  defp validate_fields(errors, fields, _source_fields, _writes) do
    [
      Core.error(
        :invalid_import_fields,
        [:imports, :fields],
        "imports.fields must be a non-empty map",
        expected: :non_empty_map,
        actual: Core.value_type(fields)
      )
      | errors
    ]
  end

  defp validate_root_field(errors, field, source_fields, path) do
    if valid_identifier?(field) and MapSet.member?(source_fields, Core.field_id(field)) do
      errors
    else
      [
        Core.error(
          :import_field_not_found,
          path,
          "import fields must reference direct root-domain fields",
          field: field
        )
        | errors
      ]
    end
  end

  defp validate_field_spec(errors, field, spec, writes, path) when is_map(spec) do
    match_only = Core.map_value(spec, :match_only) == true

    errors
    |> reject_unknown(spec, @mapping_keys, path)
    |> validate_boolean(Core.map_value(spec, :match_only), path ++ [:match_only], true)
    |> validate_write_authority(field, match_only, writes, path)
    |> validate_mapping_spec(spec, path)
  end

  defp validate_field_spec(errors, field, spec, _writes, path) do
    [
      Core.error(
        :invalid_import_field_spec,
        path,
        "import field #{inspect(field)} must be a map",
        field: field,
        actual: Core.value_type(spec)
      )
      | errors
    ]
  end

  defp validate_write_authority(errors, _field, true, _writes, _path), do: errors

  defp validate_write_authority(errors, field, false, writes, path) do
    write_fields = Core.map_value(writes, :fields)

    case fetch_entry(write_fields, field) do
      spec when is_map(spec) ->
        if Core.map_value(spec, :insertable) == true or Core.map_value(spec, :updatable) == true do
          errors
        else
          missing_write_authority(errors, field, path)
        end

      _ ->
        missing_write_authority(errors, field, path)
    end
  end

  defp missing_write_authority(errors, field, path) do
    [
      Core.error(
        :import_field_not_write_enabled,
        path,
        "non-match import fields must be insertable or updatable in writes.fields",
        field: field
      )
      | errors
    ]
  end

  defp validate_actions(errors, nil, _actions), do: errors

  defp validate_actions(errors, import_actions, actions) when is_map(import_actions) do
    Enum.reduce(import_actions, errors, fn {action_id, spec}, acc ->
      path = [:imports, :actions, action_id]
      action = fetch_entry(actions, action_id)

      acc
      |> validate_identifier(action_id, path, :invalid_import_action_id, "import action ids")
      |> validate_published_action(action_id, action, path)
      |> validate_import_action_spec(action_id, spec, action, path)
    end)
  end

  defp validate_actions(errors, import_actions, _actions) do
    [
      Core.error(
        :invalid_import_actions,
        [:imports, :actions],
        "imports.actions must be a map",
        expected: :map,
        actual: Core.value_type(import_actions)
      )
      | errors
    ]
  end

  defp validate_published_action(errors, _action_id, action, _path) when is_map(action),
    do: errors

  defp validate_published_action(errors, action_id, _action, path) do
    [
      Core.error(
        :import_action_not_found,
        path,
        "import action must reference a published domain action",
        action: action_id
      )
      | errors
    ]
  end

  defp validate_import_action_spec(errors, action_id, spec, action, path) when is_map(spec) do
    action_inputs = if is_map(action), do: Core.map_value(action, :inputs), else: %{}
    import_inputs = Core.map_value(spec, :inputs)

    errors
    |> reject_unknown(spec, ["inputs"], path)
    |> validate_import_action_inputs(action_id, import_inputs, action_inputs, path)
    |> require_published_action_inputs(action_id, import_inputs, action_inputs, path)
  end

  defp validate_import_action_spec(errors, action_id, spec, _action, path) do
    [
      Core.error(
        :invalid_import_action_spec,
        path,
        "import action #{inspect(action_id)} must be a map",
        action: action_id,
        actual: Core.value_type(spec)
      )
      | errors
    ]
  end

  defp validate_import_action_inputs(errors, action_id, inputs, action_inputs, path)
       when is_map(inputs) do
    Enum.reduce(inputs, errors, fn {input_id, spec}, acc ->
      input_path = path ++ [:inputs, input_id]

      acc
      |> validate_identifier(
        input_id,
        input_path,
        :invalid_import_action_input_id,
        "import action input ids"
      )
      |> validate_action_input_exists(action_id, input_id, action_inputs, input_path)
      |> validate_action_input_spec(action_id, input_id, spec, input_path)
    end)
  end

  defp validate_import_action_inputs(errors, action_id, inputs, _action_inputs, path) do
    [
      Core.error(
        :invalid_import_action_inputs,
        path ++ [:inputs],
        "import action #{inspect(action_id)} inputs must be a map",
        action: action_id,
        actual: Core.value_type(inputs)
      )
      | errors
    ]
  end

  defp validate_action_input_exists(errors, _action_id, input_id, action_inputs, path)
       when is_map(action_inputs) do
    if is_map(fetch_entry(action_inputs, input_id)) do
      errors
    else
      [
        Core.error(
          :import_action_input_not_found,
          path,
          "import action input must be declared by the published action",
          input: input_id
        )
        | errors
      ]
    end
  end

  defp validate_action_input_exists(errors, _action_id, input_id, _action_inputs, path) do
    [
      Core.error(
        :import_action_input_not_found,
        path,
        "import action input must be declared by the published action",
        input: input_id
      )
      | errors
    ]
  end

  defp validate_action_input_spec(errors, _action_id, _input_id, spec, path) when is_map(spec) do
    errors
    |> reject_unknown(spec, @action_mapping_keys, path)
    |> validate_mapping_spec(spec, path)
  end

  defp validate_action_input_spec(errors, action_id, input_id, spec, path) do
    [
      Core.error(
        :invalid_import_action_input_spec,
        path,
        "import action input #{inspect(action_id)}.#{inspect(input_id)} must be a map",
        action: action_id,
        input: input_id,
        actual: Core.value_type(spec)
      )
      | errors
    ]
  end

  defp require_published_action_inputs(errors, action_id, import_inputs, action_inputs, path)
       when is_map(import_inputs) and is_map(action_inputs) do
    Enum.reduce(action_inputs, errors, fn {input_id, spec}, acc ->
      if is_map(spec) and Core.map_value(spec, :required) == true and
           not is_map(fetch_entry(import_inputs, input_id)) do
        [
          Core.error(
            :required_import_action_input_missing,
            path ++ [:inputs, input_id],
            "required action inputs must be declared by the imports contract",
            action: action_id,
            input: input_id
          )
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp require_published_action_inputs(errors, _action_id, _import_inputs, _action_inputs, _path),
    do: errors

  defp validate_mapping_spec(errors, spec, path) do
    sources = Core.map_value(spec, :sources)

    errors
    |> validate_enum_list(sources, @sources, path ++ [:sources], false)
    |> validate_string_list(Core.map_value(spec, :header_aliases), path ++ [:header_aliases])
    |> validate_enum_list(
      Core.map_value(spec, :transforms),
      @transforms,
      path ++ [:transforms],
      true
    )
    |> validate_optional_enum(
      Core.map_value(spec, :blank_policy),
      @blank_policies,
      path ++ [:blank_policy]
    )
    |> validate_trusted_provider(spec, sources, path)
  end

  defp validate_trusted_provider(errors, spec, sources, path) do
    provider = Core.map_value(spec, :trusted_provider)
    trusted? = is_list(sources) and Enum.any?(sources, &(to_string(&1) == "trusted"))

    cond do
      trusted? and not Core.non_empty_atom_or_string?(provider) ->
        [
          Core.error(
            :missing_import_trusted_provider,
            path ++ [:trusted_provider],
            "trusted import sources require a non-empty trusted_provider"
          )
          | errors
        ]

      not is_nil(provider) and not Core.non_empty_atom_or_string?(provider) ->
        [
          Core.error(
            :invalid_import_trusted_provider,
            path ++ [:trusted_provider],
            "trusted_provider must be a non-empty atom or string"
          )
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_key_sets(errors, key_sets, fields) when is_list(key_sets) and key_sets != [] do
    {errors, _ids} =
      Enum.reduce(Enum.with_index(key_sets), {errors, MapSet.new()}, fn {spec, index},
                                                                        {acc, ids} ->
        path = [:imports, :key_sets, index]
        id = if is_map(spec), do: Core.map_value(spec, :id)

        next =
          acc
          |> validate_key_set(spec, fields, path)
          |> validate_unique_key_set_id(id, ids, path)

        {next, if(valid_identifier?(id), do: MapSet.put(ids, Core.field_id(id)), else: ids)}
      end)

    errors
  end

  defp validate_key_sets(errors, key_sets, _fields) do
    [
      Core.error(
        :invalid_import_key_sets,
        [:imports, :key_sets],
        "imports.key_sets must be a non-empty list",
        expected: :non_empty_list,
        actual: Core.value_type(key_sets)
      )
      | errors
    ]
  end

  defp validate_key_set(errors, spec, fields, path) when is_map(spec) do
    allowed_match = Core.map_value(spec, :allowed_on_match) || @match_decisions
    allowed_missing = Core.map_value(spec, :allowed_on_missing) || @missing_decisions
    default_match = Core.map_value(spec, :default_on_match) || List.first(allowed_match)
    default_missing = Core.map_value(spec, :default_on_missing) || List.first(allowed_missing)

    errors
    |> reject_unknown(spec, @key_set_keys, path)
    |> validate_identifier(
      Core.map_value(spec, :id),
      path ++ [:id],
      :invalid_import_key_set_id,
      "import key set ids"
    )
    |> validate_optional_label(Core.map_value(spec, :label), path ++ [:label])
    |> validate_key_fields(Core.map_value(spec, :fields), fields, path ++ [:fields])
    |> validate_required_enum(
      Core.map_value(spec, :cardinality) || :zero_or_one,
      ["zero_or_one"],
      path ++ [:cardinality]
    )
    |> validate_enum_list(allowed_match, @match_decisions, path ++ [:allowed_on_match], false)
    |> validate_enum_list(
      allowed_missing,
      @missing_decisions,
      path ++ [:allowed_on_missing],
      false
    )
    |> validate_default_decision(default_match, allowed_match, path ++ [:default_on_match])
    |> validate_default_decision(default_missing, allowed_missing, path ++ [:default_on_missing])
  end

  defp validate_key_set(errors, spec, _fields, path) do
    [
      Core.error(:invalid_import_key_set, path, "each import key set must be a map",
        actual: Core.value_type(spec)
      )
      | errors
    ]
  end

  defp validate_unique_key_set_id(errors, id, ids, path) do
    if valid_identifier?(id) and MapSet.member?(ids, Core.field_id(id)) do
      [
        Core.error(
          :duplicate_import_key_set_id,
          path ++ [:id],
          "import key set ids must be unique",
          id: id
        )
        | errors
      ]
    else
      errors
    end
  end

  defp validate_key_fields(errors, key_fields, fields, path)
       when is_list(key_fields) and key_fields != [] and is_map(fields) do
    Enum.reduce(key_fields, errors, fn field, acc ->
      if valid_identifier?(field) and is_map(fetch_entry(fields, field)) do
        acc
      else
        [
          Core.error(
            :import_key_field_not_found,
            path,
            "key-set fields must reference declared import fields",
            field: field
          )
          | acc
        ]
      end
    end)
    |> validate_unique_list(key_fields, path, :duplicate_import_key_field)
  end

  defp validate_key_fields(errors, key_fields, _fields, path) do
    [
      Core.error(
        :invalid_import_key_fields,
        path,
        "import key-set fields must be a non-empty list",
        actual: Core.value_type(key_fields)
      )
      | errors
    ]
  end

  defp validate_default_decision(errors, value, allowed, path) do
    if valid_identifier?(value) and is_list(allowed) and
         Enum.any?(allowed, &(Core.field_id(&1) == Core.field_id(value))) do
      errors
    else
      [
        Core.error(
          :invalid_import_default_decision,
          path,
          "default import decisions must be included in the corresponding allowed decision list",
          actual: value
        )
        | errors
      ]
    end
  end

  defp validate_idempotency(errors, nil), do: errors

  defp validate_idempotency(errors, idempotency) when is_map(idempotency) do
    errors
    |> reject_unknown(idempotency, ["supported"], [:imports, :idempotency])
    |> validate_boolean(
      Core.map_value(idempotency, :supported),
      [:imports, :idempotency, :supported],
      false
    )
  end

  defp validate_idempotency(errors, idempotency) do
    [
      Core.error(
        :invalid_import_idempotency,
        [:imports, :idempotency],
        "imports.idempotency must be a map",
        actual: Core.value_type(idempotency)
      )
      | errors
    ]
  end

  defp validate_enum_list(errors, nil, _allowed, _path, true), do: errors
  defp validate_enum_list(errors, [], _allowed, _path, true), do: errors

  defp validate_enum_list(errors, values, allowed, path, _optional)
       when is_list(values) and values != [] do
    invalid =
      Enum.reject(values, fn value -> valid_identifier?(value) and to_string(value) in allowed end)

    errors =
      if invalid == [],
        do: errors,
        else: [
          Core.error(
            :invalid_import_enum_list,
            path,
            "import option list contains unsupported values",
            supported: allowed,
            actual: invalid
          )
          | errors
        ]

    validate_unique_list(errors, values, path, :duplicate_import_option)
  end

  defp validate_enum_list(errors, values, _allowed, path, optional) do
    expectation = if optional, do: "a list", else: "a non-empty list"

    [
      Core.error(:invalid_import_enum_list, path, "import option must be #{expectation}",
        actual: Core.value_type(values)
      )
      | errors
    ]
  end

  defp validate_string_list(errors, nil, _path), do: errors

  defp validate_string_list(errors, values, path) when is_list(values) do
    invalid = Enum.reject(values, &Core.non_empty_string?/1)

    errors =
      if invalid == [],
        do: errors,
        else: [
          Core.error(
            :invalid_import_header_alias,
            path,
            "header aliases must be non-empty strings"
          )
          | errors
        ]

    validate_unique_list(errors, values, path, :duplicate_import_header_alias)
  end

  defp validate_string_list(errors, values, path) do
    [
      Core.error(:invalid_import_header_aliases, path, "header_aliases must be a list",
        actual: Core.value_type(values)
      )
      | errors
    ]
  end

  defp validate_optional_enum(errors, nil, _allowed, _path), do: errors

  defp validate_optional_enum(errors, value, allowed, path) do
    if valid_identifier?(value) and to_string(value) in allowed do
      errors
    else
      [
        Core.error(:invalid_import_option, path, "import option is unsupported",
          supported: allowed,
          actual: value
        )
        | errors
      ]
    end
  end

  defp validate_required_enum(errors, value, allowed, path),
    do: validate_optional_enum(errors, value, allowed, path)

  defp validate_optional_label(errors, nil, _path), do: errors

  defp validate_optional_label(errors, value, _path) when is_binary(value) and value != "",
    do: errors

  defp validate_optional_label(errors, value, path),
    do: [
      Core.error(:invalid_import_label, path, "import labels must be non-empty strings",
        actual: value
      )
      | errors
    ]

  defp validate_boolean(errors, nil, _path, true), do: errors
  defp validate_boolean(errors, value, _path, _optional) when is_boolean(value), do: errors

  defp validate_boolean(errors, value, path, _optional),
    do: [
      Core.error(:invalid_import_boolean, path, "import option must be boolean", actual: value)
      | errors
    ]

  defp validate_identifier(errors, value, _path, _code, _label)
       when (is_atom(value) and not is_nil(value)) or (is_binary(value) and value != ""),
       do: errors

  defp validate_identifier(errors, value, path, code, label),
    do: [
      Core.error(code, path, "#{label} must be non-empty atoms or strings", actual: value)
      | errors
    ]

  defp validate_unique_list(errors, values, path, code) do
    normalized = Enum.map(values, &Core.field_id/1)

    if length(normalized) == length(Enum.uniq(normalized)),
      do: errors,
      else: [Core.error(code, path, "import option values must be unique") | errors]
  end

  defp reject_unknown(errors, map, allowed, path) do
    unknown = Enum.reject(Map.keys(map), &(Core.field_id(&1) in allowed))

    if unknown == [],
      do: errors,
      else: [
        Core.error(:unknown_import_property, path, "imports contract contains unknown properties",
          properties: unknown
        )
        | errors
      ]
  end

  defp fetch_entry(registry, key) when is_map(registry) do
    Enum.find_value(registry, fn {candidate, value} ->
      if Core.field_id(candidate) == Core.field_id(key), do: value
    end)
  end

  defp fetch_entry(_registry, _key), do: nil

  defp valid_identifier?(value), do: Core.non_empty_atom_or_string?(value)
end
