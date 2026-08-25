defmodule Selecto.Domain.Contract.Writes do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core

  def validate(errors, writes, field_index) do
    validate_writes(errors, writes, field_index)
  end

  def validate_writes(errors, writes, field_index) when is_map(writes) do
    errors
    |> validate_operations(Core.map_value(writes, :operations), field_index)
    |> validate_fields(Core.map_value(writes, :fields), field_index)
    |> validate_scope(
      Core.map_value(writes, :scopes) || Core.map_value(writes, :scope),
      field_index
    )
    |> validate_relationships(Core.map_value(writes, :relationships))
    |> validate_constraints(Core.map_value(writes, :constraints), field_index)
    |> validate_transitions(Core.map_value(writes, :transitions), field_index)
  end

  def validate_writes(errors, writes, _field_index) do
    [
      Core.error(
        :invalid_section_shape,
        [:writes],
        "domain section :writes must be a map",
        expected: :map,
        actual: Core.value_type(writes)
      )
      | errors
    ]
  end

  @known_operations [:insert, :update, :delete, :upsert]

  @known_field_flags [:insertable, :updatable, :immutable, :write_once, :server_managed]
  @known_relationship_cardinality [:one, :many]
  @known_ownership [
    :composition,
    :shared_association,
    :join_association,
    :derived,
    :deferred,
    # Compatibility aliases used by the delivered NestedGraph contract.
    :owned,
    :shared_reference,
    :join_only
  ]
  @known_mutation_modes [:append_only, :delta, :full_set, :replace_one, :link_delta]
  @known_omission_policies [:unchanged, :delete_missing, :reject_missing, :retain_missing]
  @known_tenant_policies [:recursive, :membership, :explicit, :none]

  defp validate_operations(errors, nil, _field_index), do: errors

  defp validate_operations(errors, operations, field_index) when is_map(operations) do
    errors
    |> reject_normalized_registry_duplicates(
      operations,
      [:writes, :operations],
      :duplicate_write_operation_id,
      "write operation"
    )
    |> then(fn errors ->
      Enum.reduce(operations, errors, fn {operation, spec}, acc ->
        path = [:writes, :operations, operation]

        acc
        |> validate_operation_id(operation, path)
        |> validate_operation_spec(operation, spec, path, field_index)
      end)
    end)
  end

  defp validate_operations(errors, operations, _field_index) do
    [
      Core.error(
        :invalid_section_shape,
        [:writes, :operations],
        "domain section writes.operations must be a map",
        expected: :map,
        actual: Core.value_type(operations)
      )
      | errors
    ]
  end

  defp validate_operation_id(errors, operation, _path)
       when is_atom(operation) and operation in @known_operations,
       do: errors

  defp validate_operation_id(errors, operation, _path) when is_binary(operation) do
    if Enum.any?(@known_operations, &(Atom.to_string(&1) == operation)) do
      errors
    else
      [
        Core.error(
          :unknown_write_operation,
          [:writes, :operations, operation],
          "unknown write operation #{inspect(operation)}",
          operation: operation
        )
        | errors
      ]
    end
  end

  defp validate_operation_id(errors, operation, path) do
    [
      Core.error(
        :invalid_write_operation,
        path,
        "write operation ids must be known atoms or strings",
        operation: operation,
        actual: Core.value_type(operation)
      )
      | errors
    ]
  end

  defp validate_operation_spec(errors, operation, spec, path, _field_index)
       when not is_map(spec) do
    [
      Core.error(
        :invalid_write_operation_spec,
        path,
        "write operation #{inspect(operation)} must be a map",
        expected: :map,
        actual: Core.value_type(spec),
        operation: operation
      )
      | errors
    ]
  end

  defp validate_operation_spec(errors, operation, spec, path, field_index) do
    errors
    |> validate_boolean_option(operation, spec, path, :enabled)
    |> validate_boolean_option(operation, spec, path, :bulk)
    |> validate_boolean_option(operation, spec, path, :require_filter)
    |> validate_expected_cardinality(operation, spec, path)
    |> validate_operation_fields(operation, spec, path, field_index)
    |> reject_unsafe_terms(spec, path)
  end

  defp validate_boolean_option(errors, operation, spec, path, key) do
    case Core.map_value(spec, key) do
      nil ->
        errors

      value when is_boolean(value) ->
        errors

      value ->
        [
          Core.error(
            :invalid_write_operation_option,
            path ++ [key],
            "write operation #{inspect(operation)} option #{inspect(key)} must be boolean",
            operation: operation,
            key: key,
            actual: Core.value_type(value)
          )
          | errors
        ]
    end
  end

  defp validate_expected_cardinality(errors, operation, spec, path) do
    case Core.map_value(spec, :expected_cardinality) do
      nil ->
        errors

      :many ->
        errors

      "many" ->
        errors

      {:exactly, value} when is_integer(value) and value > 0 ->
        errors

      {:at_most, value} when is_integer(value) and value >= 0 ->
        errors

      {:at_least, value} when is_integer(value) and value >= 0 ->
        errors

      {:between, minimum, maximum}
      when is_integer(minimum) and is_integer(maximum) and minimum >= 0 and maximum >= minimum ->
        errors

      value ->
        [
          Core.error(
            :invalid_write_cardinality,
            path ++ [:expected_cardinality],
            "write operation #{inspect(operation)} has an invalid expected cardinality",
            operation: operation,
            value: value
          )
          | errors
        ]
    end
  end

  defp validate_operation_fields(errors, operation, spec, path, field_index) do
    case Core.map_value(spec, :fields) do
      nil ->
        errors

      fields when is_list(fields) ->
        Enum.reduce(fields, errors, fn field, acc ->
          if Core.field_ref?(field) and Core.known_field?(field_index, field) do
            acc
          else
            [
              Core.error(
                :write_operation_field_not_found,
                path ++ [:fields],
                "write operation #{inspect(operation)} references an unknown field",
                operation: operation,
                field: field
              )
              | acc
            ]
          end
        end)

      fields ->
        [
          Core.error(
            :invalid_write_operation_fields,
            path ++ [:fields],
            "write operation fields must be a list",
            operation: operation,
            actual: Core.value_type(fields)
          )
          | errors
        ]
    end
  end

  defp validate_fields(errors, nil, _field_index), do: errors

  defp validate_fields(errors, fields, field_index) when is_map(fields) do
    errors
    |> reject_normalized_registry_duplicates(
      fields,
      [:writes, :fields],
      :duplicate_write_field_id,
      "write field"
    )
    |> then(fn errors ->
      Enum.reduce(fields, errors, fn {field, spec}, acc ->
        path = [:writes, :fields, field]

        acc
        |> validate_write_field_id(field, path, field_index)
        |> validate_write_field_spec(field, spec, path)
      end)
    end)
  end

  defp validate_fields(errors, fields, _field_index) do
    [
      Core.error(
        :invalid_section_shape,
        [:writes, :fields],
        "domain section writes.fields must be a map",
        expected: :map,
        actual: Core.value_type(fields)
      )
      | errors
    ]
  end

  defp validate_write_field_id(errors, field, path, field_index) do
    if Core.field_ref?(field) and Core.known_field?(field_index, field) do
      errors
    else
      [
        Core.error(
          :write_field_not_found,
          path,
          "write field #{inspect(field)} is not defined in the domain",
          field: field
        )
        | errors
      ]
    end
  end

  defp validate_write_field_spec(errors, field, spec, path) when not is_map(spec) do
    [
      Core.error(
        :invalid_write_field_spec,
        path,
        "write field #{inspect(field)} must have a map specification",
        field: field,
        actual: Core.value_type(spec)
      )
      | errors
    ]
  end

  defp validate_write_field_spec(errors, field, spec, path) do
    @known_field_flags
    |> Enum.reduce(errors, fn flag, acc ->
      case Core.map_value(spec, flag) do
        nil ->
          acc

        value when is_boolean(value) ->
          acc

        value ->
          [
            Core.error(
              :invalid_write_field_option,
              path ++ [flag],
              "write field #{inspect(field)} option #{inspect(flag)} must be boolean",
              field: field,
              option: flag,
              actual: Core.value_type(value)
            )
            | acc
          ]
      end
    end)
    |> reject_unsafe_terms(spec, path)
  end

  defp reject_normalized_registry_duplicates(errors, registry, path, code, label) do
    registry
    |> Enum.filter(fn {id, _spec} -> Core.field_ref?(id) end)
    |> Enum.group_by(fn {id, _spec} -> Core.field_id(id) end, fn {id, _spec} -> id end)
    |> Enum.filter(fn {_normalized_id, authored_ids} -> length(authored_ids) > 1 end)
    |> Enum.sort_by(fn {normalized_id, _authored_ids} -> normalized_id end)
    |> Enum.reduce(errors, fn {normalized_id, authored_ids}, acc ->
      authored_ids = Enum.sort_by(authored_ids, &inspect/1)

      [
        Core.error(
          code,
          path,
          "#{label} ids #{inspect(authored_ids)} normalize to the same identifier #{inspect(normalized_id)}",
          normalized_id: normalized_id,
          authored_ids: authored_ids
        )
        | acc
      ]
    end)
  end

  defp validate_scope(errors, nil, _field_index), do: errors

  defp validate_scope(errors, scope, field_index) when is_map(scope) do
    case Core.map_value(scope, :tenant) do
      nil ->
        errors

      tenant when is_map(tenant) ->
        errors
        |> validate_tenant_required(tenant)
        |> validate_tenant_field(tenant, field_index)
        |> reject_unsafe_terms(tenant, [:writes, :scope, :tenant])

      tenant ->
        [
          Core.error(
            :invalid_tenant_scope,
            [:writes, :scope, :tenant],
            "write tenant scope must be a map",
            expected: :map,
            actual: Core.value_type(tenant)
          )
          | errors
        ]
    end
  end

  defp validate_scope(errors, scope, _field_index) do
    [
      Core.error(
        :invalid_section_shape,
        [:writes, :scope],
        "domain section writes.scope must be a map",
        expected: :map,
        actual: Core.value_type(scope)
      )
      | errors
    ]
  end

  defp validate_tenant_required(errors, tenant) do
    case Core.map_value(tenant, :required) do
      nil ->
        errors

      value when is_boolean(value) ->
        errors

      value ->
        [
          Core.error(
            :invalid_tenant_required,
            [:writes, :scope, :tenant, :required],
            "write tenant required must be boolean",
            actual: Core.value_type(value)
          )
          | errors
        ]
    end
  end

  defp validate_tenant_field(errors, tenant, field_index) do
    case Core.map_value(tenant, :field) do
      nil ->
        errors

      field ->
        if Core.field_ref?(field) and Core.known_field?(field_index, field) do
          errors
        else
          [
            Core.error(
              :tenant_scope_field_not_found,
              [:writes, :scope, :tenant, :field],
              "write tenant scope field is not defined in the domain",
              field: field
            )
            | errors
          ]
        end
    end
  end

  defp validate_relationships(errors, nil), do: errors

  defp validate_relationships(errors, relationships) when is_map(relationships) do
    errors =
      reject_normalized_registry_duplicates(
        errors,
        relationships,
        [:writes, :relationships],
        :duplicate_write_relationship_id,
        "write relationship"
      )

    Enum.reduce(relationships, errors, fn {relationship, spec}, acc ->
      path = [:writes, :relationships, relationship]

      if is_map(spec) do
        acc
        |> validate_relationship_enum(
          relationship,
          spec,
          path,
          :cardinality,
          @known_relationship_cardinality
        )
        |> validate_relationship_enum(relationship, spec, path, :ownership, @known_ownership)
        |> validate_boolean_option(relationship, spec, path, :enabled)
        |> validate_boolean_option(relationship, spec, path, :writable)
        |> validate_boolean_option(relationship, spec, path, :delete_missing)
        |> validate_relationship_operations(relationship, spec, path)
        |> validate_relationship_strategy(relationship, spec, path)
        |> validate_relationship_field_list(relationship, spec, path, :identity_fields)
        |> validate_relationship_field_ref(relationship, spec, path, :child_key)
        |> validate_relationship_field_ref(relationship, spec, path, :parent_key)
        |> validate_relationship_domain(relationship, spec, path)
        |> validate_relationship_path_id(relationship, spec, path)
        |> validate_relationship_read_policy(relationship, spec, path)
        |> validate_relationship_write_contract(relationship, spec, path)
        |> validate_relationship_capabilities(relationship, spec, path)
        |> validate_relationship_tenant_policy(relationship, spec, path)
        |> validate_relationship_policy_map(relationship, spec, path, :ordering)
        |> validate_relationship_policy_map(relationship, spec, path, :conflict)
        |> validate_relationship_policy_map(relationship, spec, path, :idempotency)
        |> validate_relationship_policy_map(relationship, spec, path, :offline)
        |> validate_relationship_policy_map(relationship, spec, path, :validation)
        |> validate_relationship_policy_map(relationship, spec, path, :assurance)
        |> validate_relationship_policy_map(relationship, spec, path, :output)
        |> validate_relationship_semantics(relationship, spec, path)
        |> require_relationship_write_policy(relationship, spec, path)
        |> reject_unsafe_terms(spec, path)
      else
        [
          Core.error(
            :invalid_write_relationship,
            path,
            "write relationship #{inspect(relationship)} must be a map",
            expected: :map,
            actual: Core.value_type(spec)
          )
          | acc
        ]
      end
    end)
  end

  defp validate_relationships(errors, relationships) do
    [
      Core.error(
        :invalid_section_shape,
        [:writes, :relationships],
        "domain section writes.relationships must be a map",
        expected: :map,
        actual: Core.value_type(relationships)
      )
      | errors
    ]
  end

  defp require_relationship_write_policy(errors, relationship, spec, path) do
    write = Core.map_value(spec, :write)

    writable? =
      Core.map_value(spec, :writable) == true or Core.map_value(spec, :enabled) == true or
        (is_map(write) and List.wrap(Core.map_value(write, :modes)) != [])

    if writable? do
      errors
      |> require_relationship_option(relationship, spec, path, :cardinality)
      |> require_relationship_option(relationship, spec, path, :ownership)
    else
      errors
    end
  end

  defp require_relationship_option(errors, relationship, spec, path, key) do
    if is_nil(Core.map_value(spec, key)) do
      [
        Core.error(
          :missing_write_relationship_policy,
          path ++ [key],
          "writable relationship #{inspect(relationship)} must declare #{inspect(key)}",
          relationship: relationship,
          option: key
        )
        | errors
      ]
    else
      errors
    end
  end

  defp validate_relationship_enum(errors, relationship, spec, path, key, allowed) do
    value = Core.map_value(spec, key)

    cond do
      is_nil(value) ->
        errors

      Core.enum_value?(value, allowed) ->
        errors

      true ->
        [
          Core.error(
            :invalid_write_relationship_option,
            path ++ [key],
            "write relationship #{inspect(relationship)} option #{inspect(key)} is invalid",
            relationship: relationship,
            option: key,
            value: value
          )
          | errors
        ]
    end
  end

  defp validate_relationship_operations(errors, relationship, spec, path) do
    case Core.map_value(spec, :allowed_ops) do
      nil ->
        errors

      operations when is_list(operations) ->
        Enum.reduce(operations, errors, fn operation, acc ->
          if Core.enum_value?(operation, @known_operations) do
            acc
          else
            [
              Core.error(
                :invalid_write_relationship_operation,
                path ++ [:allowed_ops],
                "write relationship #{inspect(relationship)} has an invalid allowed operation",
                relationship: relationship,
                operation: operation
              )
              | acc
            ]
          end
        end)

      operations ->
        [
          Core.error(
            :invalid_write_relationship_option,
            path ++ [:allowed_ops],
            "write relationship #{inspect(relationship)} allowed_ops must be a list",
            relationship: relationship,
            actual: Core.value_type(operations)
          )
          | errors
        ]
    end
  end

  defp validate_relationship_strategy(errors, relationship, spec, path) do
    case Core.map_value(spec, :strategy) do
      nil ->
        errors

      strategy when strategy in [:sync, "sync"] ->
        errors

      strategy ->
        [
          Core.error(
            :invalid_write_relationship_option,
            path ++ [:strategy],
            "write relationship #{inspect(relationship)} strategy must be :sync",
            relationship: relationship,
            value: strategy
          )
          | errors
        ]
    end
  end

  defp validate_relationship_field_list(errors, relationship, spec, path, key) do
    case Core.map_value(spec, key) do
      nil ->
        errors

      fields when is_list(fields) ->
        if fields != [] and Enum.all?(fields, &Core.field_ref?/1) do
          errors
        else
          [
            Core.error(
              :invalid_write_relationship_option,
              path ++ [key],
              "write relationship #{inspect(relationship)} #{key} must be a non-empty field list",
              relationship: relationship,
              value: fields
            )
            | errors
          ]
        end

      fields ->
        [
          Core.error(
            :invalid_write_relationship_option,
            path ++ [key],
            "write relationship #{inspect(relationship)} #{key} must be a field list",
            relationship: relationship,
            actual: Core.value_type(fields)
          )
          | errors
        ]
    end
  end

  defp validate_relationship_field_ref(errors, relationship, spec, path, key) do
    case Core.map_value(spec, key) do
      nil ->
        errors

      field ->
        if Core.field_ref?(field) do
          errors
        else
          [
            Core.error(
              :invalid_write_relationship_option,
              path ++ [key],
              "write relationship #{inspect(relationship)} #{key} must be a field reference",
              relationship: relationship,
              value: field
            )
            | errors
          ]
        end
    end
  end

  defp validate_relationship_domain(errors, relationship, spec, path) do
    case Core.map_value(spec, :domain) do
      nil ->
        errors

      domain when is_map(domain) ->
        errors

      domain ->
        [
          Core.error(
            :invalid_write_relationship_option,
            path ++ [:domain],
            "write relationship #{inspect(relationship)} domain must be a map",
            relationship: relationship,
            actual: Core.value_type(domain)
          )
          | errors
        ]
    end
  end

  defp validate_relationship_path_id(errors, relationship, spec, path) do
    case Core.map_value(spec, :path_id) do
      nil ->
        errors

      value when is_binary(value) ->
        if String.trim(value) == "" do
          relationship_option_error(
            errors,
            relationship,
            path ++ [:path_id],
            :path_id,
            value,
            "must be a non-empty string"
          )
        else
          errors
        end

      value ->
        relationship_option_error(
          errors,
          relationship,
          path ++ [:path_id],
          :path_id,
          value,
          "must be a non-empty string"
        )
    end
  end

  defp validate_relationship_read_policy(errors, relationship, spec, path) do
    case Core.map_value(spec, :read) do
      nil ->
        errors

      read when is_map(read) ->
        errors
        |> validate_relationship_policy_boolean(relationship, read, path ++ [:read], :allowed)
        |> validate_relationship_policy_non_negative_integer(
          relationship,
          read,
          path ++ [:read],
          :default_depth
        )
        |> validate_relationship_policy_positive_integer(
          relationship,
          read,
          path ++ [:read],
          :max_depth
        )
        |> validate_relationship_policy_positive_integer(
          relationship,
          read,
          path ++ [:read],
          :max_rows
        )
        |> validate_relationship_policy_positive_integer(
          relationship,
          read,
          path ++ [:read],
          :max_bytes
        )
        |> validate_relationship_policy_positive_integer(
          relationship,
          read,
          path ++ [:read],
          :max_complexity
        )

      value ->
        relationship_option_error(
          errors,
          relationship,
          path ++ [:read],
          :read,
          value,
          "must be a map"
        )
    end
  end

  defp validate_relationship_write_contract(errors, relationship, spec, path) do
    case Core.map_value(spec, :write) do
      nil ->
        validate_legacy_relationship_bounds(errors, relationship, spec, path)

      write when is_map(write) ->
        errors
        |> validate_relationship_mutation_modes(relationship, write, path ++ [:write])
        |> validate_relationship_policy_enum(
          relationship,
          write,
          path ++ [:write],
          :omission,
          @known_omission_policies
        )
        |> validate_relationship_policy_booleans(
          relationship,
          write,
          path ++ [:write],
          [:create, :update, :delete, :reorder, :link, :unlink]
        )
        |> validate_relationship_policy_non_negative_integer(
          relationship,
          write,
          path ++ [:write],
          :min_items
        )
        |> validate_relationship_policy_positive_integer(
          relationship,
          write,
          path ++ [:write],
          :max_items
        )
        |> validate_relationship_policy_positive_integer(
          relationship,
          write,
          path ++ [:write],
          :max_mutations
        )
        |> validate_relationship_bounds(relationship, write, path ++ [:write])

      value ->
        relationship_option_error(
          errors,
          relationship,
          path ++ [:write],
          :write,
          value,
          "must be a map"
        )
    end
  end

  defp validate_relationship_mutation_modes(errors, relationship, write, path) do
    case Core.map_value(write, :modes) do
      nil ->
        errors

      modes when is_list(modes) and modes != [] ->
        Enum.reduce(modes, errors, fn mode, acc ->
          if Core.enum_value?(mode, @known_mutation_modes) do
            acc
          else
            relationship_option_error(
              acc,
              relationship,
              path ++ [:modes],
              :modes,
              mode,
              "contains an unsupported mutation mode"
            )
          end
        end)

      modes ->
        relationship_option_error(
          errors,
          relationship,
          path ++ [:modes],
          :modes,
          modes,
          "must be a non-empty list"
        )
    end
  end

  defp validate_relationship_capabilities(errors, relationship, spec, path) do
    case Core.map_value(spec, :capabilities) do
      nil ->
        errors

      capabilities when is_map(capabilities) ->
        Enum.reduce(capabilities, errors, fn {operation, capability}, acc ->
          if valid_policy_identifier?(operation) and valid_policy_identifier?(capability) do
            acc
          else
            relationship_option_error(
              acc,
              relationship,
              path ++ [:capabilities, operation],
              :capabilities,
              capability,
              "must map operation identifiers to non-empty capability identifiers"
            )
          end
        end)

      value ->
        relationship_option_error(
          errors,
          relationship,
          path ++ [:capabilities],
          :capabilities,
          value,
          "must be a map"
        )
    end
  end

  defp validate_relationship_tenant_policy(errors, relationship, spec, path) do
    case Core.map_value(spec, :tenant_scope) do
      nil ->
        errors

      value when is_map(value) ->
        validate_relationship_policy_enum(
          errors,
          relationship,
          value,
          path ++ [:tenant_scope],
          :mode,
          @known_tenant_policies
        )

      value ->
        if Core.enum_value?(value, @known_tenant_policies) do
          errors
        else
          relationship_option_error(
            errors,
            relationship,
            path ++ [:tenant_scope],
            :tenant_scope,
            value,
            "must be a known tenant policy or a policy map"
          )
        end
    end
  end

  defp validate_relationship_policy_map(errors, relationship, spec, path, key) do
    case Core.map_value(spec, key) do
      nil ->
        errors

      value when is_map(value) ->
        errors

      value ->
        relationship_option_error(
          errors,
          relationship,
          path ++ [key],
          key,
          value,
          "must be a map"
        )
    end
  end

  defp validate_relationship_semantics(errors, relationship, spec, path) do
    ownership = canonical_ownership(Core.map_value(spec, :ownership))
    cardinality = canonical_enum(Core.map_value(spec, :cardinality))
    write = Core.map_value(spec, :write)

    # The delivered NestedGraph vocabulary predates the general composition
    # contract. Preserve that compatibility surface; the stricter semantic
    # checks apply when an author opts into the explicit `write` policy map.
    if is_map(write) do
      modes = mutation_modes(spec, write)
      operations = relationship_operations(spec, write)
      identity_fields = Core.map_value(spec, :identity_fields) |> List.wrap()
      read = Core.map_value(spec, :read)
      offline = Core.map_value(spec, :offline)
      idempotency = Core.map_value(spec, :idempotency)
      conflict = Core.map_value(spec, :conflict)

      errors
      |> reject_shared_target_mutation(relationship, ownership, operations, path)
      |> reject_read_only_mutation(relationship, ownership, modes, operations, path)
      |> reject_invalid_link_modes(relationship, ownership, modes, path)
      |> reject_invalid_cardinality_modes(relationship, cardinality, modes, path)
      |> require_stable_identity(relationship, identity_fields, modes, operations, path)
      |> require_explicit_omission(relationship, spec, write, modes, path)
      |> require_read_bounds(relationship, read, path)
      |> require_offline_controls(
        relationship,
        offline,
        idempotency,
        conflict,
        modes,
        path
      )
    else
      errors
    end
  end

  defp reject_shared_target_mutation(errors, relationship, ownership, operations, path) do
    if ownership in [:shared_association, :join_association] and
         Enum.any?(operations, &(&1 in [:create, :update, :delete])) do
      [
        Core.error(
          :shared_relationship_target_mutation,
          path ++ [:write],
          "shared and join associations may only link or unlink existing targets",
          relationship: relationship,
          ownership: ownership,
          operations: operations
        )
        | errors
      ]
    else
      errors
    end
  end

  defp reject_read_only_mutation(errors, relationship, ownership, modes, operations, path) do
    if ownership == :derived and (modes != [] or operations != []) do
      [
        Core.error(
          :read_only_relationship_mutation,
          path ++ [:write],
          "derived relationships are read-only unless exposed by a separately named Operation",
          relationship: relationship
        )
        | errors
      ]
    else
      errors
    end
  end

  defp reject_invalid_link_modes(errors, relationship, ownership, modes, path) do
    cond do
      :link_delta in modes and ownership not in [:shared_association, :join_association] ->
        [
          Core.error(
            :invalid_link_delta_ownership,
            path ++ [:write, :modes],
            "link_delta is only valid for shared or join associations",
            relationship: relationship,
            ownership: ownership
          )
          | errors
        ]

      ownership in [:shared_association, :join_association] and
          Enum.any?(modes, &(&1 != :link_delta)) ->
        [
          Core.error(
            :invalid_association_mutation_mode,
            path ++ [:write, :modes],
            "shared and join associations only accept link_delta",
            relationship: relationship,
            ownership: ownership,
            modes: modes
          )
          | errors
        ]

      true ->
        errors
    end
  end

  defp reject_invalid_cardinality_modes(errors, relationship, cardinality, modes, path) do
    invalid? =
      (cardinality == :one and Enum.any?(modes, &(&1 in [:append_only, :full_set]))) or
        (cardinality == :many and :replace_one in modes)

    if invalid? do
      [
        Core.error(
          :invalid_relationship_cardinality_mode,
          path ++ [:write, :modes],
          "relationship mutation mode is incompatible with its cardinality",
          relationship: relationship,
          cardinality: cardinality,
          modes: modes
        )
        | errors
      ]
    else
      errors
    end
  end

  defp require_stable_identity(errors, relationship, identity_fields, modes, operations, path) do
    identity_required? =
      Enum.any?(modes, &(&1 in [:delta, :full_set, :replace_one, :link_delta])) or
        Enum.any?(operations, &(&1 in [:update, :delete, :link, :unlink]))

    if identity_required? and identity_fields == [] do
      [
        Core.error(
          :nested_identity_required,
          path ++ [:identity_fields],
          "nested update, replacement, and link semantics require stable identity fields",
          relationship: relationship,
          modes: modes,
          operations: operations
        )
        | errors
      ]
    else
      errors
    end
  end

  defp require_explicit_omission(errors, relationship, spec, write, modes, path) do
    omission = if is_map(write), do: Core.map_value(write, :omission)
    legacy_delete_missing = Core.map_value(spec, :delete_missing)

    if :full_set in modes and is_nil(omission) and is_nil(legacy_delete_missing) do
      [
        Core.error(
          :nested_omission_policy_required,
          path ++ [:write, :omission],
          "full_set mutation requires an explicit omitted-child policy",
          relationship: relationship
        )
        | errors
      ]
    else
      errors
    end
  end

  defp require_read_bounds(errors, relationship, read, path) when is_map(read) do
    if Core.map_value(read, :allowed) == true and
         (is_nil(Core.map_value(read, :max_depth)) or is_nil(Core.map_value(read, :max_rows))) do
      [
        Core.error(
          :nested_read_bounds_required,
          path ++ [:read],
          "nested reads require explicit max_depth and max_rows bounds",
          relationship: relationship
        )
        | errors
      ]
    else
      errors
    end
  end

  defp require_read_bounds(errors, _relationship, _read, _path), do: errors

  defp require_offline_controls(
         errors,
         relationship,
         offline,
         idempotency,
         conflict,
         modes,
         path
       )
       when is_map(offline) do
    if Core.map_value(offline, :eligible) == true and modes != [] and
         (not is_map(idempotency) or not is_map(conflict)) do
      [
        Core.error(
          :offline_nested_controls_required,
          path ++ [:offline],
          "offline nested mutation requires explicit idempotency and conflict policies",
          relationship: relationship
        )
        | errors
      ]
    else
      errors
    end
  end

  defp require_offline_controls(
         errors,
         _relationship,
         _offline,
         _idempotency,
         _conflict,
         _modes,
         _path
       ),
       do: errors

  defp validate_legacy_relationship_bounds(errors, relationship, spec, path) do
    errors
    |> validate_relationship_policy_non_negative_integer(relationship, spec, path, :min_items)
    |> validate_relationship_policy_positive_integer(relationship, spec, path, :max_items)
    |> validate_relationship_bounds(relationship, spec, path)
  end

  defp validate_relationship_bounds(errors, relationship, policy, path) do
    minimum = Core.map_value(policy, :min_items)
    maximum = Core.map_value(policy, :max_items)

    if is_integer(minimum) and is_integer(maximum) and maximum < minimum do
      relationship_option_error(
        errors,
        relationship,
        path ++ [:max_items],
        :max_items,
        maximum,
        "must be greater than or equal to min_items"
      )
    else
      errors
    end
  end

  defp validate_relationship_policy_booleans(errors, relationship, policy, path, keys) do
    Enum.reduce(keys, errors, fn key, acc ->
      validate_relationship_policy_boolean(acc, relationship, policy, path, key)
    end)
  end

  defp validate_relationship_policy_boolean(errors, relationship, policy, path, key) do
    case Core.map_value(policy, key) do
      nil ->
        errors

      value when is_boolean(value) ->
        errors

      value ->
        relationship_option_error(
          errors,
          relationship,
          path ++ [key],
          key,
          value,
          "must be boolean"
        )
    end
  end

  defp validate_relationship_policy_non_negative_integer(
         errors,
         relationship,
         policy,
         path,
         key
       ) do
    case Core.map_value(policy, key) do
      nil ->
        errors

      value when is_integer(value) and value >= 0 ->
        errors

      value ->
        relationship_option_error(
          errors,
          relationship,
          path ++ [key],
          key,
          value,
          "must be a non-negative integer"
        )
    end
  end

  defp validate_relationship_policy_positive_integer(
         errors,
         relationship,
         policy,
         path,
         key
       ) do
    case Core.map_value(policy, key) do
      nil ->
        errors

      value when is_integer(value) and value > 0 ->
        errors

      value ->
        relationship_option_error(
          errors,
          relationship,
          path ++ [key],
          key,
          value,
          "must be a positive integer"
        )
    end
  end

  defp validate_relationship_policy_enum(errors, relationship, policy, path, key, allowed) do
    case Core.map_value(policy, key) do
      nil ->
        errors

      value ->
        if Core.enum_value?(value, allowed) do
          errors
        else
          relationship_option_error(
            errors,
            relationship,
            path ++ [key],
            key,
            value,
            "contains an unsupported value"
          )
        end
    end
  end

  defp relationship_option_error(errors, relationship, path, option, value, suffix) do
    [
      Core.error(
        :invalid_write_relationship_option,
        path,
        "write relationship #{inspect(relationship)} option #{inspect(option)} #{suffix}",
        relationship: relationship,
        option: option,
        value: value
      )
      | errors
    ]
  end

  defp mutation_modes(_spec, write) do
    write
    |> Core.map_value(:modes)
    |> List.wrap()
    |> Enum.map(&canonical_enum/1)
    |> Enum.reject(&is_nil/1)
  end

  defp relationship_operations(spec, write) do
    explicit =
      if is_map(write) do
        [:create, :update, :delete, :reorder, :link, :unlink]
        |> Enum.filter(&(Core.map_value(write, &1) == true))
      else
        []
      end

    legacy =
      spec
      |> Core.map_value(:allowed_ops)
      |> List.wrap()
      |> Enum.map(fn
        value when value in [:insert, "insert", :nested_insert, "nested_insert"] -> :create
        value when value in [:update, "update", :nested_update, "nested_update"] -> :update
        value when value in [:delete, "delete"] -> :delete
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    Enum.uniq(explicit ++ legacy)
  end

  defp canonical_ownership(value) do
    case canonical_enum(value) do
      :owned -> :composition
      :shared_reference -> :shared_association
      :join_only -> :join_association
      other -> other
    end
  end

  defp canonical_enum(value) when is_atom(value), do: value

  defp canonical_enum(value) when is_binary(value) do
    Enum.find(
      @known_ownership ++ @known_mutation_modes ++ @known_relationship_cardinality,
      &(Atom.to_string(&1) == value)
    )
  end

  defp canonical_enum(_value), do: nil

  defp valid_policy_identifier?(value) when is_atom(value), do: true
  defp valid_policy_identifier?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_policy_identifier?(_value), do: false

  defp validate_constraints(errors, nil, _field_index), do: errors

  defp validate_constraints(errors, constraints, _field_index) when is_list(constraints),
    do: errors

  defp validate_constraints(errors, constraints, field_index) when is_map(constraints) do
    errors
    |> validate_optimistic_lock(Core.map_value(constraints, :optimistic_lock), field_index)
    |> validate_foreign_keys(Core.map_value(constraints, :foreign_keys), field_index)
    |> reject_unsafe_terms(constraints, [:writes, :constraints])
  end

  defp validate_constraints(errors, constraints, _field_index) do
    [
      Core.error(
        :invalid_section_shape,
        [:writes, :constraints],
        "domain section writes.constraints must be a list or map",
        expected: "list or map",
        actual: Core.value_type(constraints)
      )
      | errors
    ]
  end

  defp validate_optimistic_lock(errors, nil, _field_index), do: errors

  defp validate_optimistic_lock(errors, lock, field_index) when is_map(lock) do
    field = Core.map_value(lock, :field)

    if Core.field_ref?(field) and Core.known_field?(field_index, field) do
      errors
    else
      [
        Core.error(
          :optimistic_lock_field_not_found,
          [:writes, :constraints, :optimistic_lock, :field],
          "optimistic lock field is not defined in the domain",
          field: field
        )
        | errors
      ]
    end
  end

  defp validate_optimistic_lock(errors, lock, _field_index) do
    [
      Core.error(
        :invalid_optimistic_lock,
        [:writes, :constraints, :optimistic_lock],
        "optimistic lock must be a map",
        actual: Core.value_type(lock)
      )
      | errors
    ]
  end

  defp validate_foreign_keys(errors, nil, _field_index), do: errors

  defp validate_foreign_keys(errors, foreign_keys, field_index) when is_map(foreign_keys) do
    Enum.reduce(foreign_keys, errors, fn {field, spec}, acc ->
      path = [:writes, :constraints, :foreign_keys, field]

      cond do
        not (Core.field_ref?(field) and Core.known_field?(field_index, field)) ->
          [
            Core.error(
              :foreign_key_field_not_found,
              path,
              "foreign key field is not defined in the domain",
              field: field
            )
            | acc
          ]

        not is_map(spec) ->
          [
            Core.error(
              :invalid_foreign_key_constraint,
              path,
              "foreign key constraint must be a map",
              actual: Core.value_type(spec)
            )
            | acc
          ]

        true ->
          acc
          |> validate_foreign_key_source(field, spec, path)
          |> validate_foreign_key_reference(field, spec, path)
          |> validate_foreign_key_required(field, spec, path)
          |> reject_unsafe_terms(spec, path)
      end
    end)
  end

  defp validate_foreign_keys(errors, foreign_keys, _field_index) do
    [
      Core.error(
        :invalid_foreign_keys,
        [:writes, :constraints, :foreign_keys],
        "foreign key constraints must be a map",
        actual: Core.value_type(foreign_keys)
      )
      | errors
    ]
  end

  defp validate_foreign_key_source(errors, field, spec, path) do
    case Core.map_value(spec, :source) do
      :input ->
        errors

      "input" ->
        errors

      {:context, key} when is_atom(key) or (is_binary(key) and byte_size(key) > 0) ->
        errors

      %{kind: kind, key: key}
      when kind in [:context, "context"] and
             (is_atom(key) or (is_binary(key) and byte_size(key) > 0)) ->
        errors

      %{"kind" => kind, "key" => key}
      when kind in [:context, "context"] and
             (is_atom(key) or (is_binary(key) and byte_size(key) > 0)) ->
        errors

      nil ->
        [
          Core.error(
            :missing_foreign_key_source,
            path ++ [:source],
            "foreign key #{inspect(field)} must declare :input or {:context, key}",
            field: field
          )
          | errors
        ]

      value ->
        [
          Core.error(
            :invalid_foreign_key_source,
            path ++ [:source],
            "foreign key #{inspect(field)} source must be :input or {:context, key}",
            field: field,
            actual: Core.value_type(value)
          )
          | errors
        ]
    end
  end

  defp validate_foreign_key_reference(errors, field, spec, path) do
    case Core.map_value(spec, :references) do
      reference when is_map(reference) ->
        relation = Core.map_value(reference, :relation)
        target_field = Core.map_value(reference, :field)

        if relation_ref?(relation) and Core.field_ref?(target_field) do
          errors
        else
          [
            Core.error(
              :invalid_foreign_key_reference,
              path ++ [:references],
              "foreign key #{inspect(field)} references must declare relation and field",
              field: field
            )
            | errors
          ]
        end

      _ ->
        [
          Core.error(
            :missing_foreign_key_reference,
            path ++ [:references],
            "foreign key #{inspect(field)} must declare a referenced relation and field",
            field: field
          )
          | errors
        ]
    end
  end

  defp validate_foreign_key_required(errors, field, spec, path) do
    case Core.map_value(spec, :required) do
      nil ->
        errors

      value when is_boolean(value) ->
        errors

      value ->
        [
          Core.error(
            :invalid_foreign_key_required,
            path ++ [:required],
            "foreign key #{inspect(field)} required must be boolean",
            field: field,
            actual: Core.value_type(value)
          )
          | errors
        ]
    end
  end

  defp relation_ref?(value) when is_atom(value), do: true
  defp relation_ref?(value) when is_binary(value), do: String.trim(value) != ""
  defp relation_ref?(_value), do: false

  defp validate_transitions(errors, nil, _field_index), do: errors

  defp validate_transitions(errors, transitions, field_index) when is_map(transitions) do
    validate_transition_graphs(errors, transitions, field_index)
  end

  defp validate_transitions(errors, transitions, _field_index) do
    [
      Core.error(
        :invalid_section_shape,
        [:writes, :transitions],
        "domain section writes.transitions must be a map",
        expected: :map,
        actual: Core.value_type(transitions)
      )
      | errors
    ]
  end

  defp reject_unsafe_terms(errors, value, path) do
    if contains_unsafe_sql?(value) do
      [
        Core.error(
          :unsafe_write_fragment,
          path,
          "portable write metadata may not contain raw SQL fragments"
        )
        | errors
      ]
    else
      errors
    end
  end

  defp contains_unsafe_sql?({:unsafe_sql, _}), do: true
  defp contains_unsafe_sql?({:unsafe_fragment, _}), do: true

  defp contains_unsafe_sql?(map) when is_map(map),
    do:
      Enum.any?(map, fn {key, value} ->
        contains_unsafe_sql?(key) or contains_unsafe_sql?(value)
      end)

  defp contains_unsafe_sql?(list) when is_list(list), do: Enum.any?(list, &contains_unsafe_sql?/1)

  defp contains_unsafe_sql?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&contains_unsafe_sql?/1)

  defp contains_unsafe_sql?(_value), do: false

  def validate_transition_graphs(errors, transitions, field_index) do
    Enum.reduce(transitions, errors, fn {field, graph}, acc ->
      acc
      |> validate_transition_field(field, field_index)
      |> validate_transition_graph(field, graph)
    end)
  end

  def validate_transition_field(errors, field, field_index) do
    cond do
      not Core.field_ref?(field) ->
        [
          Core.error(
            :invalid_transition_field,
            [:writes, :transitions, field],
            "write transition fields must be atoms or strings",
            expected: "atom or string",
            actual: Core.value_type(field),
            field: field
          )
          | errors
        ]

      Core.known_field?(field_index, field) ->
        errors

      true ->
        [
          Core.error(
            :transition_field_not_found,
            [:writes, :transitions, field],
            "write transition field #{inspect(field)} is not defined in source, schemas, or custom columns",
            field: field
          )
          | errors
        ]
    end
  end

  def validate_transition_graph(errors, field, graph) when is_map(graph) do
    Enum.reduce(graph, errors, fn {from_state, target_states}, acc ->
      state_path = [:writes, :transitions, field, from_state]

      acc
      |> validate_transition_state(from_state, state_path)
      |> validate_transition_targets(target_states, state_path)
    end)
  end

  def validate_transition_graph(errors, field, graph) do
    [
      Core.error(
        :invalid_section_shape,
        [:writes, :transitions, field],
        "write transition graph for #{inspect(field)} must be a map",
        expected: :map,
        actual: Core.value_type(graph),
        field: field
      )
      | errors
    ]
  end

  def validate_transition_targets(errors, target_states, path) when is_list(target_states) do
    target_states
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {target_state, index}, acc ->
      validate_transition_state(acc, target_state, path ++ [index])
    end)
  end

  def validate_transition_targets(errors, target_states, path) do
    [
      Core.error(
        :invalid_transition_targets,
        path,
        "write transition targets must be a list of atoms or strings",
        expected: :list,
        actual: Core.value_type(target_states)
      )
      | errors
    ]
  end

  def validate_transition_state(errors, state, _path) when is_atom(state) or is_binary(state) do
    errors
  end

  def validate_transition_state(errors, state, path) do
    [
      Core.error(
        :invalid_transition_state,
        path,
        "write transition states must be atoms or strings",
        expected: "atom or string",
        actual: Core.value_type(state),
        state: state
      )
      | errors
    ]
  end
end
