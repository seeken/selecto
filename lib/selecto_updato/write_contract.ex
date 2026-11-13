defmodule SelectoUpdato.WriteContract do
  @moduledoc """
  Normalizes domain-driven write metadata.

  This module normalizes and validates the portable `writes.*` schema. The only
  executable operation declarations are insert, update, upsert, and delete.
  """

  alias SelectoUpdato.{DomainInput, KeyNormalizer}

  @known_operations [:insert, :update, :upsert, :delete]

  @known_field_keys [
    :insertable,
    :updatable,
    :immutable,
    :write_once,
    :server_managed,
    :default,
    :default_provider,
    :required_on,
    :forbidden_on,
    :type,
    :coercion,
    :validators,
    :constraints
  ]

  @known_relationship_keys [
    :enabled,
    :writable,
    :cardinality,
    :allowed_ops,
    :ownership,
    :domain,
    :child_key,
    :parent_key,
    :strategy,
    :identity_fields,
    :delete_missing,
    :foreign_key,
    :required,
    :min_items,
    :max_items,
    :unique_by,
    :orphan_strategy,
    :cascade_delete,
    :cascade_update,
    :path_id,
    :target,
    :child_identity,
    :client_identity,
    :physical_provenance,
    :read,
    :write,
    :capabilities,
    :tenant_scope,
    :ordering,
    :conflict,
    :idempotency,
    :offline,
    :validation,
    :assurance,
    :output
  ]

  @known_operation_keys [
    :enabled,
    :bulk,
    :require_filter,
    :returning,
    :expected_cardinality,
    :conflict_targets
  ]
  @known_scope_keys [:tenant]
  @known_tenant_scope_keys [:required, :field, :tenant_field, :satisfied_by, :sources]
  @known_tenant_scope_sources [:trusted_context, :prefix, :filter, :payload]
  @default_tenant_scope_sources [:trusted_context, :prefix]

  @known_hook_types [
    :before_insert_write_state,
    :before_insert,
    :after_insert,
    :before_update_write_state,
    :before_update,
    :after_update,
    :before_delete,
    :after_delete,
    :after_nested
  ]

  @spec validate_writes_shape(map()) :: :ok | {:error, SelectoUpdato.Error.t()}
  def validate_writes_shape(domain) when is_map(domain) do
    with {:ok, domain} <- DomainInput.normalize_write_authoring(domain) do
      errors =
        []
        |> validate_operation_shapes(domain)
        |> validate_field_shapes(domain)
        |> validate_relationship_shapes(domain)
        |> validate_validations_shapes(domain)
        |> validate_constraints_shapes(domain)
        |> validate_transitions_shapes(domain)
        |> validate_scope_shapes(domain)
        |> validate_hooks_shapes(domain)

      if errors == [] do
        :ok
      else
        {:error,
         SelectoUpdato.Error.new(:invalid_operation, "Invalid writes contract shape",
           details: %{errors: errors}
         )}
      end
    end
  end

  @spec operation_supported?(map(), atom()) :: boolean()
  def operation_supported?(domain, operation) when is_map(domain) and is_atom(operation) do
    domain
    |> operation_specs()
    |> Map.get(operation, %{})
    |> Map.get(:enabled, false)
  end

  @spec operation_spec(map(), atom()) :: map()
  def operation_spec(domain, operation) when is_map(domain) and is_atom(operation) do
    domain
    |> operation_specs()
    |> Map.get(operation, %{})
  end

  @spec operation_specs(map()) :: %{optional(atom()) => map()}
  def operation_specs(domain) when is_map(domain) do
    domain = DomainInput.canonical_domain(domain)

    domain
    |> config_value(:writes, %{})
    |> config_value(:operations, %{})
    |> Enum.reduce(%{}, fn {operation_name, spec}, acc ->
      case normalize_operation_name(operation_name) do
        nil -> acc
        operation -> Map.put(acc, operation, normalize_operation_spec(spec, domain, operation))
      end
    end)
  end

  @doc """
  The relation a write names: `source_table`, in `source_schema` when the
  domain declares one, so one domain reads and writes the same relation.
  """
  @spec relation_name(map()) :: atom() | String.t() | nil
  def relation_name(source) when is_map(source) do
    relation =
      source[:source_table] || source["source_table"] || source[:table] || source["table"]

    schema = declared_schema(source)

    if is_nil(schema) or is_nil(relation) or dotted?(relation),
      do: relation,
      else: "#{schema}.#{relation}"
  end

  @doc """
  Whether a relation's source can be written as the read would name it: a
  dotted `source_table` is no table name to a read, so its schema belongs in
  `source_schema`, where a contradiction cannot hide.
  """
  @spec relation_valid?(map()) :: boolean()
  def relation_valid?(source) when is_map(source) do
    relation =
      source[:source_table] || source["source_table"] || source[:table] || source["table"]

    is_nil(relation) or not dotted?(relation)
  end

  @doc """
  A domain relation's name under its root (R59): its own declared schema, else
  the root's, so a schema entry with none never falls to the connection's path.
  """
  @spec relation_under(map(), map()) :: atom() | String.t() | nil
  def relation_under(source, root) when is_map(source) and is_map(root) do
    case {declared_schema(source), declared_schema(root)} do
      {nil, schema} when is_binary(schema) ->
        relation_name(Map.put(source, :source_schema, schema))

      _ ->
        relation_name(source)
    end
  end

  @doc "The schema a relation declares (a string or atom), or nil."
  @spec declared_schema(map()) :: String.t() | nil
  def declared_schema(source) when is_map(source) do
    case source[:source_schema] || source["source_schema"] do
      schema when is_binary(schema) and schema != "" -> schema
      schema when is_atom(schema) and not is_nil(schema) -> Atom.to_string(schema)
      _other -> nil
    end
  end

  defp dotted?(relation), do: relation |> to_string() |> String.contains?(".")

  @spec conflict_targets(map(), atom()) :: [[atom()]]
  def conflict_targets(domain, :upsert) when is_map(domain) do
    case operation_spec(domain, :upsert) do
      %{conflict_targets: targets} when is_list(targets) ->
        Enum.filter(targets, &conflict_target_field_list?/1)

      _other ->
        []
    end
  end

  def conflict_targets(domain, _operation) when is_map(domain), do: []

  @spec relationship_specs(map()) :: %{optional(atom()) => map()}
  def relationship_specs(domain) when is_map(domain) do
    domain = DomainInput.canonical_domain(domain)

    domain
    |> Map.get(:writes, %{})
    |> Map.get(:relationships, %{})
    |> Enum.reduce(%{}, fn {relationship_name, spec}, acc ->
      normalized_key = normalize_key_name(relationship_name)

      if is_nil(normalized_key) do
        acc
      else
        Map.put(acc, normalized_key, normalize_relationship_spec(spec))
      end
    end)
  end

  @spec validations(map()) :: list()
  def validations(domain) when is_map(domain) do
    domain = DomainInput.canonical_domain(domain)

    domain
    |> Map.get(:writes, %{})
    |> Map.get(:validations, [])
    |> List.wrap()
  end

  @spec transitions(map()) :: %{optional(atom()) => map()}
  def transitions(domain) when is_map(domain) do
    domain = DomainInput.canonical_domain(domain)

    raw =
      domain
      |> Map.get(:writes, %{})
      |> Map.get(:transitions, Map.get(domain, :transitions, %{}))

    Enum.reduce(raw, %{}, fn {field_name, rules}, acc ->
      field = normalize_known_field(field_name, known_fields(domain))

      if is_nil(field) or not is_map(rules) do
        acc
      else
        normalized_rules =
          Enum.reduce(rules, %{}, fn {from_value, targets}, rules_acc ->
            Map.put(rules_acc, from_value, List.wrap(targets))
          end)

        Map.put(acc, field, normalized_rules)
      end
    end)
  end

  @spec constraints(map()) :: list()
  def constraints(domain) when is_map(domain) do
    domain = DomainInput.canonical_domain(domain)

    domain
    |> Map.get(:writes, %{})
    |> Map.get(:constraints, [])
    |> List.wrap()
  end

  @spec writable_fields(map()) :: [atom()]
  def writable_fields(domain) when is_map(domain) do
    domain
    |> field_specs()
    |> Enum.filter(fn {_field, spec} -> insertable?(spec) or updatable?(spec) end)
    |> Enum.map(fn {field, _spec} -> field end)
  end

  @spec required_fields(map(), atom()) :: [atom()]
  def required_fields(domain, operation_type) when is_map(domain) and is_atom(operation_type) do
    domain
    |> field_specs()
    |> Enum.filter(fn {_field, spec} ->
      operation_type in Map.get(spec, :required_on, [])
    end)
    |> Enum.map(fn {field, _spec} -> field end)
  end

  @spec field_specs(map()) :: %{optional(atom()) => map()}
  def field_specs(domain) when is_map(domain) do
    domain = DomainInput.canonical_domain(domain)
    known_fields = known_fields(domain)

    domain
    |> write_fields_config()
    |> Enum.reduce(%{}, fn {field_name, spec}, acc ->
      case normalize_known_field(field_name, known_fields) do
        nil -> acc
        field -> Map.put(acc, field, normalize_field_spec(spec))
      end
    end)
  end

  @spec field_type(map(), atom()) :: term() | nil
  def field_type(domain, field) when is_map(domain) and is_atom(field) do
    domain = DomainInput.canonical_domain(domain)

    field_config(domain, field)
    |> Map.get(:type)
  end

  @spec field_validators(map(), atom()) :: list()
  def field_validators(domain, field) when is_map(domain) and is_atom(field) do
    domain = DomainInput.canonical_domain(domain)

    field_config(domain, field)
    |> Map.get(:validators, [])
  end

  @spec field_immutable?(map(), atom()) :: boolean()
  def field_immutable?(domain, field) when is_map(domain) and is_atom(field) do
    domain = DomainInput.canonical_domain(domain)

    field_config(domain, field)
    |> Map.get(:immutable, false)
    |> Kernel.==(true)
  end

  @spec field_write_once?(map(), atom()) :: boolean()
  def field_write_once?(domain, field) when is_map(domain) and is_atom(field) do
    domain = DomainInput.canonical_domain(domain)

    field_config(domain, field)
    |> Map.get(:write_once, false)
    |> Kernel.==(true)
  end

  @spec field_writable?(map(), atom(), atom()) :: boolean()
  def field_writable?(domain, field, :insert) when is_map(domain) and is_atom(field) do
    domain = DomainInput.canonical_domain(domain)

    case field_specs(domain) do
      specs when map_size(specs) > 0 ->
        spec = Map.get(specs, field, %{})

        Map.get(spec, :server_managed, false) != true and
          Map.get(spec, :insertable, false) == true

      _ ->
        field in writable_fields(domain)
    end
  end

  def field_writable?(domain, field, :update) when is_map(domain) and is_atom(field) do
    domain = DomainInput.canonical_domain(domain)

    case field_specs(domain) do
      specs when map_size(specs) > 0 ->
        spec = Map.get(specs, field, %{})
        Map.get(spec, :server_managed, false) != true and Map.get(spec, :updatable, false) == true

      _ ->
        field in writable_fields(domain)
    end
  end

  def field_writable?(domain, field, _operation) when is_map(domain) and is_atom(field) do
    domain = DomainInput.canonical_domain(domain)

    field in writable_fields(domain)
  end

  @spec field_config(map(), atom()) :: map()
  def field_config(domain, field) when is_map(domain) and is_atom(field) do
    domain = DomainInput.canonical_domain(domain)
    write_spec = Map.get(field_specs(domain), field, %{})
    legacy_spec = legacy_field_spec(domain, field)

    legacy_spec
    |> Map.merge(write_spec)
    |> Map.update(:validators, Map.get(legacy_spec, :validators, []), fn validators ->
      validators
    end)
  end

  defp write_fields_config(domain) do
    domain
    |> Map.get(:writes, %{})
    |> Map.get(:fields, %{})
  end

  @spec scope_specs(map()) :: map()
  def scope_specs(domain) when is_map(domain) do
    domain = DomainInput.canonical_domain(domain)

    case scope_config(domain) do
      scope when is_map(scope) ->
        scope
        |> normalize_scope_spec()
        |> reject_empty_values()

      _other ->
        %{}
    end
  end

  @spec tenant_scope(map()) :: map() | nil
  def tenant_scope(domain) when is_map(domain) do
    domain
    |> scope_specs()
    |> Map.get(:tenant)
  end

  @spec hook_specs(map()) :: %{optional(atom()) => list()}
  def hook_specs(domain) when is_map(domain) do
    domain = DomainInput.canonical_domain(domain)

    case hook_config(domain) do
      hooks when is_map(hooks) ->
        Enum.reduce(hooks, %{}, fn {hook_type, hooks}, acc ->
          case normalize_hook_type(hook_type) do
            nil -> acc
            normalized -> Map.put(acc, normalized, List.wrap(hooks))
          end
        end)

      _other ->
        %{}
    end
  end

  @spec hooks(map(), atom()) :: list()
  def hooks(domain, hook_type) when is_map(domain) and is_atom(hook_type) do
    domain
    |> hook_specs()
    |> Map.get(hook_type, [])
  end

  defp scope_config(domain) do
    writes = Map.get(domain, :writes, Map.get(domain, "writes", %{}))
    if is_map(writes), do: Map.get(writes, :scope, Map.get(writes, "scope")), else: nil
  end

  defp normalize_scope_spec(scope) do
    case config_value(scope, :tenant) do
      tenant when is_map(tenant) ->
        %{tenant: normalize_tenant_scope_spec(tenant)}

      _other ->
        %{}
    end
  end

  defp normalize_tenant_scope_spec(spec) do
    required = config_value(spec, :required)
    field = config_value(spec, :field, config_value(spec, :tenant_field))
    sources = config_value(spec, :satisfied_by, config_value(spec, :sources))

    %{}
    |> maybe_put_scope_value(:required, if(is_boolean(required), do: required))
    |> maybe_put_scope_value(:field, normalize_scope_field(field))
    |> Map.put(:satisfied_by, normalize_tenant_scope_sources(sources))
  end

  # Portable Domain JSON may name fields with no atom in a freshly booted VM.
  # Preserve those identifiers without interning caller-controlled strings.
  defp normalize_scope_field(field) when is_binary(field),
    do: normalize_key_name(field) || field

  defp normalize_scope_field(field), do: normalize_key_name(field)

  defp normalize_tenant_scope_sources(nil), do: @default_tenant_scope_sources

  defp normalize_tenant_scope_sources(sources) do
    sources
    |> List.wrap()
    |> Enum.map(&normalize_tenant_scope_source/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp maybe_put_scope_value(map, _key, nil), do: map
  defp maybe_put_scope_value(map, key, value), do: Map.put(map, key, value)

  defp hook_config(domain) do
    writes = Map.get(domain, :writes, Map.get(domain, "writes", %{}))

    canonical_hooks =
      if is_map(writes), do: Map.get(writes, :hooks, Map.get(writes, "hooks")), else: nil

    cond do
      is_map(canonical_hooks) -> canonical_hooks
      true -> Map.get(domain, :hooks, Map.get(domain, "hooks", %{}))
    end
  end

  defp normalize_operation_spec(spec, domain, operation) when is_map(spec) do
    spec
    |> normalize_boolean_key(:enabled)
    |> normalize_boolean_key(:bulk)
    |> normalize_boolean_key(:require_filter)
    |> normalize_conflict_targets(domain, operation)
    |> normalize_operation_field(domain, operation)
  end

  defp normalize_operation_spec(_, _domain, _operation), do: %{}

  defp normalize_relationship_spec(spec) when is_map(spec) do
    spec
    |> normalize_boolean_key(:writable)
    |> normalize_boolean_key(:required)
    |> normalize_boolean_key(:cascade_delete)
    |> normalize_boolean_key(:cascade_update)
    |> normalize_cardinality()
    |> normalize_allowed_ops()
    |> normalize_integer_key(:min_items)
    |> normalize_integer_key(:max_items)
    |> normalize_foreign_key()
  end

  defp normalize_relationship_spec(_), do: %{}

  defp normalize_field_spec(spec) when is_map(spec) do
    spec
    |> normalize_boolean_key(:insertable)
    |> normalize_boolean_key(:updatable)
    |> normalize_boolean_key(:immutable)
    |> normalize_boolean_key(:write_once)
    |> normalize_boolean_key(:server_managed)
    |> normalize_type_key()
    |> normalize_validators_key()
    |> normalize_required_on()
  end

  defp normalize_field_spec(_), do: %{}

  defp normalize_boolean_key(spec, key) do
    value = Map.get(spec, key, Map.get(spec, Atom.to_string(key)))

    if is_nil(value), do: spec, else: Map.put(spec, key, value)
  end

  defp normalize_conflict_targets(spec, domain, :upsert) do
    case config_value(spec, :conflict_targets) do
      targets when is_list(targets) ->
        if Enum.all?(targets, &is_list/1) do
          normalized_targets =
            targets
            |> Enum.map(&normalize_known_fields(&1, known_fields(domain)))
            |> Enum.filter(&conflict_target_field_list?/1)
            |> Enum.uniq()

          Map.put(spec, :conflict_targets, normalized_targets)
        else
          Map.put(spec, :conflict_targets, targets)
        end

      nil ->
        spec

      other ->
        Map.put(spec, :conflict_targets, other)
    end
  end

  defp normalize_conflict_targets(spec, _domain, _operation), do: spec

  defp normalize_operation_field(spec, _domain, _operation), do: spec

  defp conflict_target_field_list?(fields) when is_list(fields) do
    fields != [] and
      Enum.all?(fields, &(is_atom(&1) or (is_binary(&1) and String.trim(&1) != "")))
  end

  defp conflict_target_field_list?(_), do: false

  defp normalize_integer_key(spec, key) do
    value = Map.get(spec, key, Map.get(spec, Atom.to_string(key)))

    cond do
      is_nil(value) -> spec
      is_integer(value) -> Map.put(spec, key, value)
      true -> spec
    end
  end

  defp normalize_type_key(spec) do
    value = Map.get(spec, :type, Map.get(spec, "type"))
    if is_nil(value), do: spec, else: Map.put(spec, :type, value)
  end

  defp normalize_validators_key(spec) do
    validators =
      Map.get(spec, :validators) ||
        Map.get(spec, "validators") ||
        Map.get(spec, :validations) ||
        Map.get(spec, "validations") || []

    Map.put(spec, :validators, List.wrap(validators))
  end

  defp normalize_required_on(spec) do
    required_on = Map.get(spec, :required_on, Map.get(spec, "required_on", []))

    normalized =
      required_on
      |> List.wrap()
      |> Enum.map(&normalize_operation_name/1)
      |> Enum.reject(&is_nil/1)

    Map.put(spec, :required_on, normalized)
  end

  defp normalize_cardinality(spec) do
    value = Map.get(spec, :cardinality, Map.get(spec, "cardinality"))

    normalized =
      case value do
        :one -> :one
        :many -> :many
        "one" -> :one
        "many" -> :many
        _ -> nil
      end

    if normalized, do: Map.put(spec, :cardinality, normalized), else: spec
  end

  defp normalize_allowed_ops(spec) do
    allowed_ops = Map.get(spec, :allowed_ops, Map.get(spec, "allowed_ops", []))

    normalized =
      allowed_ops
      |> List.wrap()
      |> Enum.map(&normalize_operation_name/1)
      |> Enum.reject(&is_nil/1)

    Map.put(spec, :allowed_ops, normalized)
  end

  defp normalize_foreign_key(spec) do
    value = Map.get(spec, :foreign_key, Map.get(spec, "foreign_key"))

    normalized = normalize_key_name(value)
    if normalized, do: Map.put(spec, :foreign_key, normalized), else: spec
  end

  defp normalize_operation_name(op) when is_atom(op), do: op

  defp normalize_operation_name(op) when is_binary(op) do
    try do
      String.to_existing_atom(op)
    rescue
      ArgumentError -> nil
    end
  end

  defp normalize_operation_name(_), do: nil

  defp normalize_key_name(key) when is_atom(key), do: key

  defp normalize_key_name(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp normalize_key_name(_), do: nil

  defp validate_operation_shapes(errors, domain) do
    operations = domain |> Map.get(:writes, %{}) |> Map.get(:operations, %{})

    if is_map(operations) do
      Enum.reduce(operations, errors, fn {operation_name, spec}, acc ->
        op = normalize_operation_name(operation_name)

        cond do
          is_nil(op) or op not in @known_operations ->
            [{[:writes, :operations, operation_name], "is not a supported operation"} | acc]

          not is_map(spec) ->
            [{[:writes, :operations, op], "must be a map"} | acc]

          true ->
            acc
            |> validate_unknown_keys([:writes, :operations, op], spec, @known_operation_keys)
            |> validate_boolean_field([:writes, :operations, op], spec, :enabled)
            |> validate_boolean_field([:writes, :operations, op], spec, :bulk)
            |> validate_boolean_field([:writes, :operations, op], spec, :require_filter)
            |> validate_expected_cardinality([:writes, :operations, op], spec)
            |> validate_returning([:writes, :operations, op], spec)
            |> validate_conflict_targets([:writes, :operations, op], op, spec, domain)
        end
      end)
    else
      [{[:writes, :operations], "must be a map"} | errors]
    end
  end

  defp validate_field_shapes(errors, domain) do
    fields = write_fields_config(domain)
    known = known_fields(domain)

    if is_map(fields) do
      Enum.reduce(fields, errors, fn {field_name, spec}, acc ->
        field = normalize_known_field(field_name, known)

        cond do
          is_nil(field) ->
            [{[:writes, :fields, field_name], "is not a known field"} | acc]

          not is_map(spec) ->
            [{[:writes, :fields, field], "must be a map"} | acc]

          true ->
            acc
            |> validate_unknown_keys([:writes, :fields, field], spec, @known_field_keys)
            |> validate_boolean_field([:writes, :fields, field], spec, :insertable)
            |> validate_boolean_field([:writes, :fields, field], spec, :updatable)
            |> validate_boolean_field([:writes, :fields, field], spec, :immutable)
            |> validate_boolean_field([:writes, :fields, field], spec, :write_once)
            |> validate_boolean_field([:writes, :fields, field], spec, :server_managed)
            |> validate_operation_list([:writes, :fields, field], spec, :required_on)
            |> validate_operation_list([:writes, :fields, field], spec, :forbidden_on)
            |> validate_validators_list([:writes, :fields, field], spec)
            |> validate_field_validator_forms([:writes, :fields, field], spec, known)
            |> validate_server_managed([:writes, :fields, field], spec)
        end
      end)
    else
      [{[:writes, :fields], "must be a map"} | errors]
    end
  end

  defp validate_relationship_shapes(errors, domain) do
    relationships = domain |> Map.get(:writes, %{}) |> Map.get(:relationships, %{})
    known_relationships = known_relationship_names(domain)
    known = known_fields(domain)

    if is_map(relationships) do
      Enum.reduce(relationships, errors, fn {relationship_name, spec}, acc ->
        rel = normalize_key_name(relationship_name)

        cond do
          is_nil(rel) or (known_relationships != [] and rel not in known_relationships) ->
            [{[:writes, :relationships, relationship_name], "is not a known relationship"} | acc]

          not is_map(spec) ->
            [{[:writes, :relationships, rel], "must be a map"} | acc]

          true ->
            acc
            |> validate_unknown_keys(
              [:writes, :relationships, rel],
              spec,
              @known_relationship_keys
            )
            |> validate_boolean_field([:writes, :relationships, rel], spec, :enabled)
            |> validate_boolean_field([:writes, :relationships, rel], spec, :writable)
            |> validate_boolean_field([:writes, :relationships, rel], spec, :required)
            |> validate_boolean_field([:writes, :relationships, rel], spec, :delete_missing)
            |> validate_integer_field([:writes, :relationships, rel], spec, :min_items)
            |> validate_integer_field([:writes, :relationships, rel], spec, :max_items)
            |> validate_relationship_cardinality([:writes, :relationships, rel], spec)
            |> validate_allowed_ops([:writes, :relationships, rel], spec)
            |> validate_relationship_ownership([:writes, :relationships, rel], spec)
            |> validate_relationship_strategy([:writes, :relationships, rel], spec)
            |> validate_nested_domain([:writes, :relationships, rel], spec, known)
            |> validate_foreign_key([:writes, :relationships, rel], spec, known)
            |> validate_unique_by([:writes, :relationships, rel], spec, known)
            |> validate_item_bounds([:writes, :relationships, rel], spec)
        end
      end)
    else
      [{[:writes, :relationships], "must be a map"} | errors]
    end
  end

  defp validate_validations_shapes(errors, domain) do
    validations = domain |> Map.get(:writes, %{}) |> Map.get(:validations, [])

    cond do
      is_nil(validations) ->
        errors

      not is_list(validations) ->
        [{[:writes, :validations], "must be a list"} | errors]

      true ->
        known_fields = known_fields(domain)

        Enum.reduce(validations, errors, fn rule, acc ->
          if valid_constraint_rule?(rule, known_fields) do
            acc
          else
            [{[:writes, :validations, rule], "is not a supported validation rule"} | acc]
          end
        end)
    end
  end

  defp validate_constraints_shapes(errors, domain) do
    constraints = domain |> Map.get(:writes, %{}) |> Map.get(:constraints, [])

    cond do
      is_nil(constraints) ->
        errors

      is_map(constraints) ->
        errors

      not is_list(constraints) ->
        [{[:writes, :constraints], "must be a list or map"} | errors]

      true ->
        known_fields = known_fields(domain)
        known_relationships = known_relationship_names(domain)

        Enum.reduce(constraints, errors, fn rule, acc ->
          if valid_constraint_rule?(rule, known_fields, known_relationships) do
            acc
          else
            [{[:writes, :constraints, rule], "is not a supported constraint rule"} | acc]
          end
        end)
    end
  end

  defp validate_transitions_shapes(errors, domain) do
    transitions =
      domain |> Map.get(:writes, %{}) |> Map.get(:transitions, Map.get(domain, :transitions, %{}))

    cond do
      is_nil(transitions) ->
        errors

      not is_map(transitions) ->
        [{[:writes, :transitions], "must be a map"} | errors]

      true ->
        known_fields = known_fields(domain)

        Enum.reduce(transitions, errors, fn {field_name, rules}, acc ->
          field = normalize_known_field(field_name, known_fields)

          cond do
            is_nil(field) ->
              [{[:writes, :transitions, field_name], "is not a known field"} | acc]

            not is_map(rules) ->
              [{[:writes, :transitions, field], "must be a map"} | acc]

            true ->
              Enum.reduce(rules, acc, fn {from_value, targets}, rules_acc ->
                cond do
                  is_list(targets) ->
                    rules_acc

                  true ->
                    [
                      {[:writes, :transitions, field, from_value],
                       "must map to a list of target states"}
                      | rules_acc
                    ]
                end
              end)
          end
        end)
    end
  end

  defp validate_scope_shapes(errors, domain) do
    scope = scope_config(domain)

    cond do
      is_nil(scope) ->
        errors

      not is_map(scope) ->
        [{[:writes, :scope], "must be a map"} | errors]

      true ->
        errors
        |> validate_unknown_keys([:writes, :scope], scope, @known_scope_keys)
        |> validate_tenant_scope_shape(scope, domain)
    end
  end

  defp validate_tenant_scope_shape(errors, scope, domain) do
    case config_value(scope, :tenant) do
      nil ->
        errors

      tenant when not is_map(tenant) ->
        [{[:writes, :scope, :tenant], "must be a map"} | errors]

      tenant ->
        errors
        |> validate_unknown_keys([:writes, :scope, :tenant], tenant, @known_tenant_scope_keys)
        |> validate_boolean_field([:writes, :scope, :tenant], tenant, :required)
        |> validate_tenant_scope_field(tenant, domain)
        |> validate_tenant_scope_sources(tenant)
    end
  end

  defp validate_tenant_scope_field(errors, tenant, domain) do
    field = config_value(tenant, :field, config_value(tenant, :tenant_field))

    cond do
      is_nil(field) ->
        errors

      is_nil(normalize_known_field(field, known_fields(domain))) ->
        [{[:writes, :scope, :tenant, :field], "must reference a known field"} | errors]

      true ->
        errors
    end
  end

  defp validate_tenant_scope_sources(errors, tenant) do
    sources = config_value(tenant, :satisfied_by, config_value(tenant, :sources))

    cond do
      is_nil(sources) ->
        errors

      not is_list(sources) ->
        [{[:writes, :scope, :tenant, :satisfied_by], "must be a list"} | errors]

      true ->
        Enum.reduce(sources, errors, fn source, acc ->
          if normalize_tenant_scope_source(source) in @known_tenant_scope_sources do
            acc
          else
            [
              {[:writes, :scope, :tenant, :satisfied_by, source],
               "is not a supported tenant scope source"}
              | acc
            ]
          end
        end)
    end
  end

  defp validate_hooks_shapes(errors, domain) do
    writes = Map.get(domain, :writes, Map.get(domain, "writes", %{}))
    hooks = if is_map(writes), do: Map.get(writes, :hooks, Map.get(writes, "hooks")), else: nil

    cond do
      is_nil(hooks) ->
        errors

      not is_map(hooks) ->
        [{[:writes, :hooks], "must be a map"} | errors]

      true ->
        Enum.reduce(hooks, errors, fn {hook_type, hook_refs}, acc ->
          normalized = normalize_hook_type(hook_type)

          cond do
            is_nil(normalized) ->
              [{[:writes, :hooks, hook_type], "is not a supported lifecycle hook"} | acc]

            not is_list(hook_refs) ->
              [{[:writes, :hooks, normalized], "must be a list"} | acc]

            true ->
              Enum.reduce(hook_refs, acc, fn hook_ref, hook_acc ->
                if valid_hook_ref?(hook_ref, normalized) do
                  hook_acc
                else
                  [
                    {[:writes, :hooks, normalized, hook_ref], "is not a supported hook reference"}
                    | hook_acc
                  ]
                end
              end)
          end
        end)
    end
  end

  defp validate_unknown_keys(errors, path, spec, allowed_keys) do
    Enum.reduce(Map.keys(spec), errors, fn key, acc ->
      if known_key?(key, allowed_keys) do
        acc
      else
        [{path ++ [key], "is not allowed"} | acc]
      end
    end)
  end

  defp known_key?(key, allowed_keys) when is_atom(key), do: key in allowed_keys

  defp known_key?(key, allowed_keys) when is_binary(key) do
    Enum.any?(allowed_keys, &(is_atom(&1) and Atom.to_string(&1) == key))
  end

  defp known_key?(_key, _allowed_keys), do: false

  defp config_value(map, key, default \\ nil)

  defp config_value(map, key, default) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  defp config_value(_map, _key, default), do: default

  defp reject_empty_values(map) when is_map(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, value} when is_map(value) -> map_size(value) == 0
      {_key, []} -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp normalize_hook_type(hook_type) when is_atom(hook_type) do
    if hook_type in @known_hook_types, do: hook_type
  end

  defp normalize_hook_type(hook_type) when is_binary(hook_type) do
    Enum.find(@known_hook_types, &(Atom.to_string(&1) == hook_type))
  end

  defp normalize_hook_type(_hook_type), do: nil

  defp normalize_tenant_scope_source(:context), do: :trusted_context
  defp normalize_tenant_scope_source(:trusted_context), do: :trusted_context
  defp normalize_tenant_scope_source(:prefix), do: :prefix
  defp normalize_tenant_scope_source(:filter), do: :filter
  defp normalize_tenant_scope_source(:payload), do: :payload
  defp normalize_tenant_scope_source("context"), do: :trusted_context
  defp normalize_tenant_scope_source("trusted_context"), do: :trusted_context
  defp normalize_tenant_scope_source("prefix"), do: :prefix
  defp normalize_tenant_scope_source("filter"), do: :filter
  defp normalize_tenant_scope_source("payload"), do: :payload
  defp normalize_tenant_scope_source(_source), do: nil

  defp valid_hook_ref?(hook, hook_type) when is_function(hook),
    do: valid_hook_function_arity?(hook, hook_type)

  defp valid_hook_ref?({module, function}, _hook_type) do
    is_atom(module) and is_atom(function)
  end

  defp valid_hook_ref?({module, function, args}, _hook_type) do
    is_atom(module) and is_atom(function) and is_list(args)
  end

  defp valid_hook_ref?(_hook, _hook_type), do: false

  defp valid_hook_function_arity?(hook, hook_type) do
    Enum.any?(hook_arities(hook_type), &(Function.info(hook, :arity) == {:arity, &1}))
  end

  defp hook_arities(:before_update), do: [1, 2]
  defp hook_arities(_hook_type), do: [1]

  defp validate_boolean_field(errors, path, spec, key) do
    value = Map.get(spec, key, Map.get(spec, Atom.to_string(key)))

    cond do
      is_nil(value) -> errors
      is_boolean(value) -> errors
      true -> [{path ++ [key], "must be a boolean"} | errors]
    end
  end

  defp validate_integer_field(errors, path, spec, key) do
    value = Map.get(spec, key, Map.get(spec, Atom.to_string(key)))

    cond do
      is_nil(value) -> errors
      is_integer(value) and value >= 0 -> errors
      true -> [{path ++ [key], "must be a non-negative integer"} | errors]
    end
  end

  defp validate_operation_list(errors, path, spec, key) do
    value = Map.get(spec, key, Map.get(spec, Atom.to_string(key)))

    cond do
      is_nil(value) ->
        errors

      not is_list(value) ->
        [{path ++ [key], "must be a list"} | errors]

      true ->
        Enum.reduce(value, errors, fn operation_name, acc ->
          op = normalize_operation_name(operation_name)

          if op in @known_operations do
            acc
          else
            [{path ++ [key, operation_name], "is not a supported operation"} | acc]
          end
        end)
    end
  end

  defp validate_validators_list(errors, path, spec) do
    validators =
      Map.get(spec, :validators) ||
        Map.get(spec, "validators") ||
        Map.get(spec, :validations) ||
        Map.get(spec, "validations")

    cond do
      is_nil(validators) -> errors
      is_list(validators) -> errors
      true -> [{path ++ [:validators], "must be a list"} | errors]
    end
  end

  defp validate_server_managed(errors, path, spec) do
    server_managed = Map.get(spec, :server_managed, Map.get(spec, "server_managed"))
    insertable = Map.get(spec, :insertable, Map.get(spec, "insertable"))
    updatable = Map.get(spec, :updatable, Map.get(spec, "updatable"))

    if server_managed == true and (insertable == true or updatable == true) do
      [{path, "server_managed fields cannot also be insertable or updatable"} | errors]
    else
      errors
    end
  end

  defp validate_conflict_targets(errors, path, operation, spec, domain) do
    value = Map.get(spec, :conflict_targets, Map.get(spec, "conflict_targets"))

    cond do
      is_nil(value) ->
        errors

      operation != :upsert ->
        [{path ++ [:conflict_targets], "is only allowed on upsert"} | errors]

      is_list(value) and Enum.all?(value, &is_list/1) ->
        validate_conflict_target_fields(errors, path, value, domain)

      true ->
        [{path ++ [:conflict_targets], "must be a list of field lists"} | errors]
    end
  end

  defp validate_conflict_target_fields(errors, path, targets, domain) do
    known_fields = known_fields(domain)

    Enum.reduce(targets, errors, fn target_fields, acc ->
      if Enum.all?(target_fields, &(not is_nil(normalize_known_field(&1, known_fields)))) do
        acc
      else
        [{path ++ [:conflict_targets, target_fields], "must reference known fields"} | acc]
      end
    end)
  end

  defp validate_returning(errors, path, spec) do
    value = Map.get(spec, :returning, Map.get(spec, "returning"))

    cond do
      is_nil(value) ->
        errors

      value in [
        true,
        false,
        :minimal,
        :all,
        :record,
        :records,
        :count,
        :none,
        "minimal",
        "all",
        "record",
        "records",
        "count",
        "none"
      ] ->
        errors

      true ->
        [{path ++ [:returning], "must be a supported returning mode"} | errors]
    end
  end

  defp validate_expected_cardinality(errors, path, spec) do
    value = Map.get(spec, :expected_cardinality, Map.get(spec, "expected_cardinality"))

    if valid_expected_cardinality?(value) do
      errors
    else
      [{path ++ [:expected_cardinality], "is invalid"} | errors]
    end
  end

  defp valid_expected_cardinality?(nil), do: true
  defp valid_expected_cardinality?(:many), do: true
  defp valid_expected_cardinality?("many"), do: true

  defp valid_expected_cardinality?({:exactly, value}),
    do: is_integer(value) and value > 0

  defp valid_expected_cardinality?({:at_most, value}),
    do: is_integer(value) and value >= 0

  defp valid_expected_cardinality?({:at_least, value}),
    do: is_integer(value) and value >= 0

  defp valid_expected_cardinality?({:between, minimum, maximum}),
    do: is_integer(minimum) and is_integer(maximum) and minimum >= 0 and maximum >= minimum

  defp valid_expected_cardinality?(_value), do: false

  defp validate_relationship_cardinality(errors, path, spec) do
    value = Map.get(spec, :cardinality, Map.get(spec, "cardinality"))

    cond do
      is_nil(value) -> errors
      value in [:one, :many, "one", "many"] -> errors
      true -> [{path ++ [:cardinality], "must be :one or :many"} | errors]
    end
  end

  defp validate_allowed_ops(errors, path, spec) do
    value = Map.get(spec, :allowed_ops, Map.get(spec, "allowed_ops"))

    cond do
      is_nil(value) ->
        errors

      not is_list(value) ->
        [{path ++ [:allowed_ops], "must be a list"} | errors]

      true ->
        Enum.reduce(value, errors, fn operation_name, acc ->
          op = normalize_operation_name(operation_name)

          if op in [:insert, :update, :delete, :nested_insert, :nested_update] do
            acc
          else
            [
              {path ++ [:allowed_ops, operation_name], "is not a supported nested operation"}
              | acc
            ]
          end
        end)
    end
  end

  defp validate_relationship_ownership(errors, path, spec) do
    case Map.get(spec, :ownership, Map.get(spec, "ownership")) do
      nil ->
        errors

      value
      when value in [
             :owned,
             :composition,
             :shared_reference,
             :shared_association,
             :join_only,
             :join_association,
             :derived,
             :deferred,
             "owned",
             "composition",
             "shared_reference",
             "shared_association",
             "join_only",
             "join_association",
             "derived",
             "deferred"
           ] ->
        errors

      _value ->
        [
          {path ++ [:ownership],
           "must be a composition, shared association, join association, derived, or deferred relationship"}
          | errors
        ]
    end
  end

  defp validate_relationship_strategy(errors, path, spec) do
    case Map.get(spec, :strategy, Map.get(spec, "strategy")) do
      nil -> errors
      value when value in [:sync, "sync"] -> errors
      _value -> [{path ++ [:strategy], "must be :sync"} | errors]
    end
  end

  defp validate_nested_domain(errors, path, spec, parent_fields) do
    domain = Map.get(spec, :domain, Map.get(spec, "domain"))
    child_key = Map.get(spec, :child_key, Map.get(spec, "child_key"))
    parent_key = Map.get(spec, :parent_key, Map.get(spec, "parent_key"))
    identity_fields = Map.get(spec, :identity_fields, Map.get(spec, "identity_fields"))

    errors =
      cond do
        is_nil(domain) -> errors
        is_map(domain) -> errors
        true -> [{path ++ [:domain], "must be a domain map"} | errors]
      end

    errors =
      cond do
        is_nil(child_key) ->
          errors

        not is_map(domain) ->
          errors

        not is_nil(
          normalize_known_field(child_key, known_fields(DomainInput.canonical_domain(domain)))
        ) ->
          errors

        true ->
          [{path ++ [:child_key], "must reference a field in the child domain"} | errors]
      end

    errors =
      cond do
        is_nil(parent_key) -> errors
        not is_nil(normalize_known_field(parent_key, parent_fields)) -> errors
        true -> [{path ++ [:parent_key], "must reference a field in the parent domain"} | errors]
      end

    cond do
      is_nil(identity_fields) ->
        errors

      not is_list(identity_fields) or identity_fields == [] ->
        [{path ++ [:identity_fields], "must be a non-empty field list"} | errors]

      not is_map(domain) ->
        errors

      Enum.all?(identity_fields, fn field ->
        not is_nil(
          normalize_known_field(field, known_fields(DomainInput.canonical_domain(domain)))
        )
      end) ->
        errors

      true ->
        [{path ++ [:identity_fields], "must reference fields in the child domain"} | errors]
    end
  end

  defp validate_foreign_key(errors, path, spec, known_fields) do
    value = Map.get(spec, :foreign_key, Map.get(spec, "foreign_key"))

    cond do
      is_nil(value) ->
        errors

      is_nil(normalize_known_field(value, known_fields)) ->
        [{path ++ [:foreign_key], "must reference a known field"} | errors]

      true ->
        errors
    end
  end

  defp validate_unique_by(errors, path, spec, known_fields) do
    value = Map.get(spec, :unique_by, Map.get(spec, "unique_by"))

    cond do
      is_nil(value) ->
        errors

      not is_list(value) ->
        [{path ++ [:unique_by], "must be a list of field lists"} | errors]

      true ->
        Enum.reduce(value, errors, fn field_group, acc ->
          cond do
            not is_list(field_group) ->
              [{path ++ [:unique_by, field_group], "must be a field list"} | acc]

            Enum.all?(field_group, &(not is_nil(normalize_known_field(&1, known_fields)))) ->
              acc

            true ->
              [{path ++ [:unique_by, field_group], "must reference known fields"} | acc]
          end
        end)
    end
  end

  defp validate_item_bounds(errors, path, spec) do
    min_items = Map.get(spec, :min_items, Map.get(spec, "min_items"))
    max_items = Map.get(spec, :max_items, Map.get(spec, "max_items"))
    cardinality = Map.get(spec, :cardinality, Map.get(spec, "cardinality"))

    errors =
      if cardinality in [:one, "one"] and is_integer(max_items) and max_items > 1 do
        [{path ++ [:max_items], "must be 1 or less for cardinality :one"} | errors]
      else
        errors
      end

    if is_integer(min_items) and is_integer(max_items) and min_items > max_items do
      [{path, "min_items must be less than or equal to max_items"} | errors]
    else
      errors
    end
  end

  defp known_relationship_names(domain) do
    joins = Map.get(domain, :joins, %{})

    joins
    |> Map.keys()
    |> Enum.map(&normalize_key_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp valid_constraint_rule?({:compare, left_field, op, right_field}, known_fields) do
    valid_known_field_ref?(left_field, known_fields) and
      valid_known_field_ref?(right_field, known_fields) and
      op in [:<=, :>=, :<, :>, :==, :!=]
  end

  defp valid_constraint_rule?({validator, field, other_field, _value}, known_fields)
       when validator in [:required_if, :forbidden_if] do
    valid_known_field_ref?(field, known_fields) and
      valid_known_field_ref?(other_field, known_fields)
  end

  defp valid_constraint_rule?(_rule, _known_fields), do: false

  defp valid_constraint_rule?({:exactly_one_of, fields}, known_fields, _known_relationships) do
    is_list(fields) and Enum.all?(fields, &valid_known_field_ref?(&1, known_fields))
  end

  defp valid_constraint_rule?({:require_one_of, fields}, known_fields, _known_relationships) do
    is_list(fields) and Enum.all?(fields, &valid_known_field_ref?(&1, known_fields))
  end

  defp valid_constraint_rule?({:filter_must_include, field}, known_fields, _known_relationships) do
    valid_known_field_ref?(field, known_fields)
  end

  defp valid_constraint_rule?({:require_relationship, key}, _known_fields, known_relationships) do
    is_atom(key) and key in known_relationships
  end

  defp valid_constraint_rule?(
         {:relationship_min_items, key, min},
         _known_fields,
         known_relationships
       ) do
    is_atom(key) and key in known_relationships and is_integer(min) and min >= 0
  end

  defp valid_constraint_rule?(
         {:relationship_max_items, key, max},
         _known_fields,
         known_relationships
       ) do
    is_atom(key) and key in known_relationships and is_integer(max) and max >= 0
  end

  defp valid_constraint_rule?(_rule, _known_fields, _known_relationships), do: false

  defp validate_field_validator_forms(errors, path, spec, known_fields) do
    validators =
      Map.get(spec, :validators) ||
        Map.get(spec, "validators") ||
        Map.get(spec, :validations) ||
        Map.get(spec, "validations") || []

    if is_list(validators) do
      Enum.reduce(validators, errors, fn validator, acc ->
        if valid_field_validator?(validator, known_fields) do
          acc
        else
          [{path ++ [:validators, validator], "is not a supported validator form"} | acc]
        end
      end)
    else
      errors
    end
  end

  defp valid_field_validator?({:inclusion, values}, _known_fields), do: is_list(values)
  defp valid_field_validator?({:exclusion, values}, _known_fields), do: is_list(values)
  defp valid_field_validator?({:format, %Regex{}}, _known_fields), do: true
  defp valid_field_validator?({:length, opts}, _known_fields), do: Keyword.keyword?(opts)
  defp valid_field_validator?({:number, opts}, _known_fields), do: Keyword.keyword?(opts)
  defp valid_field_validator?({:acceptance, opts}, _known_fields), do: is_list(List.wrap(opts))

  defp valid_field_validator?({:confirmation, opts}, _known_fields) do
    Keyword.keyword?(List.wrap(opts))
  end

  defp valid_field_validator?({validator, field, other_field, value}, known_fields)
       when validator in [:required_if, :forbidden_if] do
    valid_known_field_ref?(field, known_fields) and
      valid_known_field_ref?(other_field, known_fields) and
      not is_nil(value)
  end

  defp valid_field_validator?({:compare, field, op, other_field}, known_fields) do
    valid_known_field_ref?(field, known_fields) and
      valid_known_field_ref?(other_field, known_fields) and
      op in [:<=, :>=, :<, :>, :==, :!=]
  end

  defp valid_field_validator?({:validate_with, {:module, module, function_name}}, _known_fields) do
    is_atom(module) and is_atom(function_name)
  end

  defp valid_field_validator?(_validator, _known_fields), do: false

  defp valid_known_field_ref?(field, known_fields) do
    not is_nil(normalize_known_field(field, known_fields))
  end

  defp insertable?(spec) do
    Map.get(spec, :insertable, false) == true
  end

  defp updatable?(spec) do
    Map.get(spec, :updatable, false) == true
  end

  defp legacy_field_spec(domain, field) do
    columns = domain_columns(domain)

    column_config =
      Enum.find_value(columns, %{}, fn {key, config} ->
        if normalize_known_field(key, known_fields(domain)) == field, do: config
      end)

    %{
      type: Map.get(column_config, :type),
      validators: Map.get(column_config, :validations, [])
    }
  end

  defp known_fields(domain) do
    column_fields = domain |> domain_columns() |> Map.keys()
    schema_fields = KeyNormalizer.schema_fields(domain)

    (column_fields ++ schema_fields)
    |> Enum.map(fn
      key when is_atom(key) -> key
      key when is_binary(key) -> key
    end)
    |> Enum.uniq()
  end

  defp domain_columns(domain) when is_map(domain) do
    source_columns =
      domain
      |> config_value(:source, %{})
      |> map_or_empty()
      |> config_value(:columns, %{})
      |> map_or_empty()

    domain
    |> config_value(:columns, %{})
    |> map_or_empty()
    |> Map.merge(source_columns, fn _key, top_level, source -> Map.merge(source, top_level) end)
  end

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp normalize_known_fields(fields, known_fields) when is_list(fields) do
    fields
    |> Enum.map(&normalize_known_field(&1, known_fields))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_known_field(field, known_fields) when is_atom(field) do
    cond do
      field in known_fields -> field
      Atom.to_string(field) in Enum.map(known_fields, &to_string/1) -> field
      true -> nil
    end
  end

  defp normalize_known_field(field, known_fields) when is_binary(field) do
    Enum.find_value(known_fields, fn
      candidate when is_atom(candidate) -> if Atom.to_string(candidate) == field, do: candidate
      candidate when is_binary(candidate) -> if candidate == field, do: candidate
      _ -> nil
    end)
  end

  defp normalize_known_field(_, _), do: nil
end
