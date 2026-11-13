defmodule SelectoUpdato.DomainContract do
  @moduledoc """
  Read-only Updato-facing projection for normalized Selecto domains.

  This module does not execute writes and does not build write plans. It gives
  Updato a small contract surface over `Selecto.Domain.project/2` so write,
  action, and capability metadata can be inspected without walking authored
  domain maps directly.
  """

  alias Selecto.Domain
  alias Selecto.Domain.ActionPreconditions
  alias Selecto.Domain.Diagnostics
  alias Selecto.Rule.Contract, as: RuleContract
  alias SelectoUpdato.DomainContract.{ChoiceSourceValidator, IntentValidator}
  alias SelectoUpdato.WriteContract

  @contract_version 1
  @known_write_sections [
    :operations,
    :fields,
    :relationships,
    :validations,
    :constraints,
    :transitions,
    :scope,
    :hooks
  ]

  @type diagnostics :: Diagnostics.t()
  @type result :: {:ok, map(), diagnostics()} | {:error, diagnostics()}

  @doc """
  Builds a read-only Updato contract from a domain-shaped input.

  Accepted inputs are authored Selecto domain maps, already-normalized Selecto
  domains, and `%Selecto{}` or selecto-like maps containing `:domain`.
  """
  @spec build(term()) :: result()
  def build(input) do
    with {:ok, normalized, diagnostics} <- normalize_input(input),
         {:ok, rules} <- RuleContract.compile_normalized(normalized) do
      projection = Domain.project(normalized, :write)
      write_warnings = write_section_warnings(projection)
      diagnostics = append_warnings(diagnostics, write_warnings)

      {:ok, contract_document(projection, diagnostics, RuleContract.project(rules)), diagnostics}
    end
  end

  @doc """
  Alias for `build/1`.
  """
  @spec write_contract(term()) :: result()
  def write_contract(input), do: build(input)

  @doc """
  Builds a JSON-ready Updato domain contract document.

  The returned map has string keys and JSON-compatible values so callers can
  serve it directly from an artifact endpoint. Elixir-only terms such as atoms
  and tuples are converted to strings and arrays, and nil map values are
  omitted.
  """
  @spec json_document(term(), keyword()) :: result()
  def json_document(input, opts \\ []) do
    with {:ok, contract, diagnostics} <- build(input) do
      document =
        contract
        |> Map.put(:generated_at, generated_at(opts))
        |> json_safe()

      {:ok, document, diagnostics}
    end
  end

  @doc """
  Encodes the JSON-ready Updato domain contract document.
  """
  @spec encode_json(term(), keyword()) ::
          {:ok, String.t(), diagnostics()} | {:error, diagnostics()}
  def encode_json(input, opts \\ []) do
    with {:ok, document, diagnostics} <- json_document(input, opts) do
      {:ok, Jason.encode!(document, json_encode_opts(opts)), diagnostics}
    end
  end

  @doc """
  Validates a proposed write/action intent without executing it.
  """
  @spec validate_intent(term(), map(), keyword()) :: IntentValidator.result()
  def validate_intent(input, intent, opts \\ []) do
    case contract_input(input) do
      {:ok, contract} ->
        contract
        |> IntentValidator.validate(intent, opts)
        |> append_choice_source_errors(ChoiceSourceValidator.validate(input, intent, opts))

      :build ->
        case build(input) do
          {:ok, contract, _diagnostics} ->
            contract
            |> IntentValidator.validate(intent, opts)
            |> append_choice_source_errors(ChoiceSourceValidator.validate(input, intent, opts))

          {:error, diagnostics} ->
            %{
              valid?: false,
              errors: [
                %{
                  code: :invalid_domain_contract,
                  path: "",
                  message: "domain contract input is invalid",
                  diagnostics: diagnostics.errors
                }
              ],
              warnings: diagnostics.warnings
            }
        end
    end
  end

  defp append_choice_source_errors(result, []), do: result

  defp append_choice_source_errors(result, errors) when is_map(result) do
    result
    |> Map.update(:errors, errors, &(&1 ++ errors))
    |> Map.put(:valid?, false)
  end

  defp contract_document(projection, diagnostics, rules) do
    writes = write_map(projection)

    %{
      contract_version: @contract_version,
      schema_version: Map.get(projection, :schema_version),
      projection: :updato_write_contract,
      name: map_value(projection, :name),
      source: Map.get(projection, :source),
      operations: operation_entries(writes),
      fields:
        field_entries(writes, Map.get(projection, :columns, %{}), Map.get(projection, :source)),
      rules: rules,
      relationships: relationship_entries(writes),
      validations: write_list(writes, :validations),
      constraints: write_list(writes, :constraints),
      transitions: transition_entries(writes),
      scope: scope_entry(projection),
      hooks: hook_entries(writes),
      actions: action_entries(Map.get(projection, :actions, %{})),
      events: event_entries(Map.get(projection, :events, %{})),
      capabilities: capability_entries(Map.get(projection, :capabilities, %{})),
      source_relationships:
        registry_entries(Map.get(projection, :source_relationships, %{}), :source_relationship),
      choice_sources: registry_entries(Map.get(projection, :choice_sources, %{}), :choice_source),
      unmodeled_write_sections: unmodeled_write_sections(writes),
      diagnostics: diagnostics_summary(diagnostics)
    }
  end

  defp normalize_input(
         %{
           schema_version: schema_version,
           domain: %{},
           query: %{},
           projection: %{},
           sections: sections
         } = normalized
       ) do
    diagnostics =
      Diagnostics.new(
        sections: sections,
        schema_version: schema_version,
        schema_version_inferred: false
      )

    {:ok, normalized, diagnostics}
  end

  defp normalize_input(%Selecto{domain: domain}) when is_map(domain), do: Domain.normalize(domain)
  defp normalize_input(%{domain: domain}) when is_map(domain), do: Domain.normalize(domain)
  defp normalize_input(%{"domain" => domain}) when is_map(domain), do: Domain.normalize(domain)
  defp normalize_input(input), do: Domain.normalize(input)

  defp contract_input(%{} = input) do
    if contract_document?(input), do: {:ok, input}, else: :build
  end

  defp contract_input(_input), do: :build

  defp contract_document?(input) do
    projection = map_value(input, :projection)

    projection in [:updato_write_contract, "updato_write_contract"] and
      is_list(map_value(input, :operations, [])) and is_list(map_value(input, :actions, []))
  end

  defp generated_at(opts) do
    case Keyword.get(opts, :generated_at) do
      nil ->
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      %DateTime{} = datetime ->
        DateTime.to_iso8601(datetime)

      generated_at ->
        generated_at
    end
  end

  defp operation_entries(writes) do
    writes
    |> write_map(:operations)
    |> sorted_entries()
    |> Enum.map(fn {operation, spec} ->
      %{
        id: id(operation),
        enabled: map_value(spec, :enabled),
        bulk: map_value(spec, :bulk),
        require_filter: map_value(spec, :require_filter),
        returning: map_value(spec, :returning),
        conflict_targets: field_groups(map_value(spec, :conflict_targets)),
        field: field_id_or_nil(map_value(spec, :field)),
        raw: spec
      }
      |> compact()
    end)
  end

  defp field_entries(writes, columns, source) do
    writes
    |> write_map(:fields)
    |> sorted_entries()
    |> Enum.map(fn {field, spec} ->
      column =
        source
        |> map_value(:columns, %{})
        |> field_config(field)
        |> Map.merge(field_config(columns, field))

      %{
        id: id(field),
        label: map_value(spec, :label, map_value(column, :label)),
        type: map_value(spec, :type, map_value(column, :type)),
        insertable: map_value(spec, :insertable),
        updatable: map_value(spec, :updatable),
        immutable: map_value(spec, :immutable),
        write_once: map_value(spec, :write_once),
        server_managed: map_value(spec, :server_managed),
        required_on: operation_ids(map_value(spec, :required_on, [])),
        forbidden_on: operation_ids(map_value(spec, :forbidden_on, [])),
        validators: field_validators(spec),
        constraints: write_list(spec, :constraints),
        default: map_value(spec, :default),
        default_provider: map_value(spec, :default_provider),
        choice_source: field_id_or_nil(map_value(column, :choice_source)),
        reference: choice_reference(map_value(column, :reference)),
        raw: spec
      }
      |> compact()
    end)
  end

  defp relationship_entries(writes) do
    writes
    |> write_map(:relationships)
    |> sorted_entries()
    |> Enum.map(fn {relationship, spec} ->
      %{
        id: id(relationship),
        writable: map_value(spec, :writable),
        cardinality: map_value(spec, :cardinality),
        allowed_ops: operation_ids(map_value(spec, :allowed_ops, [])),
        ownership: map_value(spec, :ownership),
        child_domain: relationship_domain_summary(map_value(spec, :domain)),
        child_key: field_id_or_nil(map_value(spec, :child_key)),
        parent_key: field_id_or_nil(map_value(spec, :parent_key)),
        identity_fields: field_ids(map_value(spec, :identity_fields, [])),
        strategy: map_value(spec, :strategy),
        delete_missing: map_value(spec, :delete_missing),
        foreign_key: field_id_or_nil(map_value(spec, :foreign_key)),
        required: map_value(spec, :required),
        min_items: map_value(spec, :min_items),
        max_items: map_value(spec, :max_items),
        unique_by: field_groups(map_value(spec, :unique_by)),
        orphan_strategy: map_value(spec, :orphan_strategy),
        cascade_delete: map_value(spec, :cascade_delete),
        cascade_update: map_value(spec, :cascade_update),
        path_id: map_value(spec, :path_id),
        target: map_value(spec, :target),
        child_identity: map_value(spec, :child_identity),
        client_identity: map_value(spec, :client_identity),
        physical_provenance: map_value(spec, :physical_provenance),
        read: map_value(spec, :read),
        write: map_value(spec, :write),
        capabilities: map_value(spec, :capabilities),
        tenant_scope: map_value(spec, :tenant_scope),
        ordering: map_value(spec, :ordering),
        conflict: map_value(spec, :conflict),
        idempotency: map_value(spec, :idempotency),
        offline: map_value(spec, :offline),
        validation: map_value(spec, :validation),
        assurance: map_value(spec, :assurance),
        output: map_value(spec, :output),
        raw: drop_domain(spec)
      }
      |> compact()
    end)
  end

  defp relationship_domain_summary(domain) when is_map(domain) do
    source = map_value(domain, :source, %{})

    %{
      name: map_value(domain, :name),
      relation: map_value(source, :source_table, map_value(source, :table)),
      primary_key: field_id_or_nil(map_value(source, :primary_key))
    }
    |> compact()
  end

  defp relationship_domain_summary(_domain), do: nil

  defp field_ids(fields) when is_list(fields), do: Enum.map(fields, &id/1)
  defp field_ids(_fields), do: []

  defp drop_domain(spec) when is_map(spec) do
    spec |> Map.delete(:domain) |> Map.delete("domain")
  end

  defp transition_entries(writes) do
    writes
    |> write_map(:transitions)
    |> sorted_entries()
    |> Enum.map(fn {field, graph} ->
      %{
        field: id(field),
        transitions: transition_targets(graph),
        raw: graph
      }
    end)
  end

  defp action_entries(actions) when is_map(actions) do
    actions
    |> sorted_entries()
    |> Enum.map(fn {action, spec} ->
      %{
        id: id(action),
        label: map_value(spec, :label, map_value(spec, :name)),
        description: map_value(spec, :description),
        type: map_value(spec, :type),
        scope: field_id_or_nil(map_value(spec, :scope)),
        target: field_id_or_nil(map_value(spec, :target)),
        capability: field_id_or_nil(map_value(spec, :capability)),
        icon: map_value(spec, :icon),
        confirmation: map_value(spec, :confirmation, map_value(spec, :confirm)),
        audit: map_value(spec, :audit),
        presentation: map_value(spec, :presentation),
        selection: map_value(spec, :selection),
        inputs: input_entries(map_value(spec, :inputs)),
        variants: variant_entries(map_value(spec, :variants)),
        transition: transition_spec(map_value(spec, :transition)),
        execution: execution_spec(map_value(spec, :execution)),
        raw: spec
      }
      |> compact()
      |> preserve_action_preconditions(spec)
    end)
  end

  defp action_entries(_actions), do: []

  defp event_entries(events) when is_map(events) do
    events
    |> sorted_entries()
    |> Enum.map(fn {event, spec} ->
      %{
        id: id(event),
        schema_version: map_value(spec, :schema_version),
        data: map_value(spec, :data),
        additional_fields: map_value(spec, :additional_fields),
        raw: spec
      }
      |> compact()
    end)
  end

  defp event_entries(_events), do: []

  defp capability_entries(capabilities) when is_map(capabilities) do
    capabilities
    |> sorted_entries()
    |> Enum.map(fn {capability, spec} ->
      %{
        id: id(capability),
        operations: operation_ids(map_value(spec, :operations, [])),
        action: map_value(spec, :action),
        raw: spec
      }
      |> compact()
    end)
  end

  defp capability_entries(_capabilities), do: []

  defp registry_entries(registry, kind) when is_map(registry) do
    registry
    |> sorted_entries()
    |> Enum.map(fn {entry_id, spec} ->
      %{
        id: id(entry_id),
        kind: kind,
        raw: spec
      }
    end)
  end

  defp registry_entries(_registry, _kind), do: []

  defp transition_targets(graph) when is_map(graph) do
    graph
    |> sorted_entries()
    |> Enum.map(fn {from, targets} ->
      %{from: id(from), to: Enum.map(List.wrap(targets), &id/1)}
    end)
  end

  defp transition_targets(_graph), do: []

  defp scope_entry(projection) do
    %{
      tenant: tenant_scope_entry(WriteContract.tenant_scope(projection))
    }
    |> compact()
  end

  defp tenant_scope_entry(scope) when is_map(scope) do
    %{
      required: map_value(scope, :required),
      field: field_id_or_nil(map_value(scope, :field)),
      satisfied_by: operation_ids(map_value(scope, :satisfied_by, []))
    }
    |> compact()
  end

  defp tenant_scope_entry(_scope), do: nil

  defp hook_entries(writes) do
    writes
    |> write_map(:hooks)
    |> sorted_entries()
    |> Enum.map(fn {hook_type, refs} ->
      hook_refs = List.wrap(refs)

      %{
        id: id(hook_type),
        runtime: :host_code,
        portable: false,
        count: length(hook_refs),
        refs: Enum.map(hook_refs, &hook_ref_entry/1)
      }
      |> compact()
    end)
  end

  defp hook_ref_entry(hook) when is_function(hook) do
    %{
      kind: :function,
      arity: function_arity(hook)
    }
    |> compact()
  end

  defp hook_ref_entry({module, function}) when is_atom(module) and is_atom(function) do
    %{
      kind: :module_function,
      module: inspect(module),
      function: id(function),
      extra_args: 0
    }
  end

  defp hook_ref_entry({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    %{
      kind: :module_function,
      module: inspect(module),
      function: id(function),
      extra_args: length(args)
    }
  end

  defp hook_ref_entry(_hook), do: %{kind: :unknown}

  defp function_arity(hook) when is_function(hook) do
    case Function.info(hook, :arity) do
      {:arity, arity} -> arity
      _other -> nil
    end
  end

  defp transition_spec(spec) when is_map(spec) do
    %{
      field: field_id_or_nil(map_value(spec, :field)),
      from: field_id_or_nil(map_value(spec, :from)),
      to: field_id_or_nil(map_value(spec, :to))
    }
    |> compact()
  end

  defp transition_spec(_spec), do: nil

  defp precondition_entries(preconditions) do
    case ActionPreconditions.normalize(preconditions) do
      {:ok, entries} -> entries
      # Do not silently remove a guard from an already-normalized input that
      # bypassed authored-domain validation. Planning will reject it.
      {:error, _error} -> preconditions
    end
  end

  defp preserve_action_preconditions(entry, spec) do
    case map_value(spec, :preconditions) do
      nil -> entry
      raw -> Map.put(entry, :preconditions, precondition_entries(raw))
    end
  end

  defp execution_spec(spec) when is_map(spec) do
    %{
      conflict_target: map_value(spec, :conflict_target),
      kind: map_value(spec, :kind),
      operation: map_value(spec, :operation),
      set: map_value(spec, :set),
      document: map_value(spec, :document),
      aggregate: map_value(spec, :aggregate),
      stream_id: map_value(spec, :stream_id),
      bounded_context: map_value(spec, :bounded_context),
      consistency: map_value(spec, :consistency),
      possible_events: operation_ids(map_value(spec, :possible_events, [])),
      collection_patches: map_value(spec, :collection_patches),
      cases: execution_case_entries(map_value(spec, :cases)),
      resolver: map_value(spec, :resolver)
    }
    |> compact()
    |> preserve_execution_returning(spec)
  end

  defp execution_spec(_spec), do: nil

  # An explicit empty list must reach the planner's returning validation rather
  # than being compacted away and replaced by the write operation's default.
  defp preserve_execution_returning(entry, spec) do
    case map_value(spec, :returning) do
      nil -> entry
      returning -> Map.put(entry, :returning, returning)
    end
  end

  defp input_entries(inputs) when is_map(inputs) do
    inputs
    |> sorted_entries()
    |> Enum.map(fn {input, spec} ->
      %{
        id: id(input),
        type: map_value(spec, :type),
        required: map_value(spec, :required),
        default: map_value(spec, :default),
        values: map_value(spec, :values),
        discriminator: map_value(spec, :discriminator),
        representation: map_value(spec, :representation),
        identity: map_value(spec, :identity),
        order: map_value(spec, :order),
        allowed_ops: operation_ids(map_value(spec, :allowed_ops, [])),
        min_items: map_value(spec, :min_items),
        max_items: map_value(spec, :max_items),
        item: item_input_entries(map_value(spec, :item)),
        choice_source: field_id_or_nil(map_value(spec, :choice_source)),
        label: map_value(spec, :label),
        description: map_value(spec, :description),
        raw: spec
      }
      |> compact()
    end)
  end

  defp input_entries(inputs) when is_list(inputs), do: Enum.map(inputs, &input_entry/1)
  defp input_entries(_inputs), do: []

  defp input_entry(%{} = input) do
    %{
      id: field_id_or_nil(map_value(input, :id) || map_value(input, :name)),
      type: map_value(input, :type),
      required: map_value(input, :required),
      default: map_value(input, :default),
      values: map_value(input, :values),
      discriminator: map_value(input, :discriminator),
      representation: map_value(input, :representation),
      identity: map_value(input, :identity),
      order: map_value(input, :order),
      allowed_ops: operation_ids(map_value(input, :allowed_ops, [])),
      min_items: map_value(input, :min_items),
      max_items: map_value(input, :max_items),
      item: item_input_entries(map_value(input, :item)),
      choice_source: field_id_or_nil(map_value(input, :choice_source)),
      label: map_value(input, :label),
      description: map_value(input, :description),
      raw: input
    }
    |> compact()
  end

  defp input_entry(input), do: %{id: id(input)}

  defp item_input_entries(item) when is_map(item), do: input_entries(item)
  defp item_input_entries(_item), do: []

  defp variant_entries(variants) when is_list(variants) do
    Enum.map(variants, &variant_entry/1)
  end

  defp variant_entries(variants) when is_map(variants) do
    variants
    |> sorted_entries()
    |> Enum.map(fn {variant, spec} ->
      spec
      |> Map.put_new(:id, variant)
      |> variant_entry()
    end)
  end

  defp variant_entries(_variants), do: []

  defp variant_entry(%{} = variant) do
    %{
      id: field_id_or_nil(map_value(variant, :id)),
      inputs: input_entries(map_value(variant, :inputs)),
      execution: execution_spec(map_value(variant, :execution)),
      raw: variant
    }
    |> maybe_put(:when, map_value(variant, :when) || map_value(variant, :match))
    |> compact()
  end

  defp variant_entry(variant), do: %{id: id(variant)}

  defp execution_case_entries(cases) when is_list(cases) do
    Enum.map(cases, &execution_case_entry/1)
  end

  defp execution_case_entries(_cases), do: []

  defp execution_case_entry(%{} = case_spec) do
    %{
      conflict_target: map_value(case_spec, :conflict_target),
      operation: map_value(case_spec, :operation),
      set: map_value(case_spec, :set),
      collection_patches: map_value(case_spec, :collection_patches),
      raw: case_spec
    }
    |> maybe_put(:when, map_value(case_spec, :when) || map_value(case_spec, :match))
    |> compact()
  end

  defp execution_case_entry(case_spec), do: %{raw: case_spec}

  defp diagnostics_summary(diagnostics) do
    %{
      error_count: length(diagnostics.errors),
      warning_count: length(diagnostics.warnings),
      error_codes: diagnostic_codes(diagnostics.errors),
      warning_codes: diagnostic_codes(diagnostics.warnings),
      schema_version_inferred: diagnostics.schema_version_inferred,
      sections: diagnostics.sections
    }
  end

  defp diagnostic_codes(diagnostics) do
    diagnostics
    |> Enum.map(&Map.get(&1, :code))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp write_section_warnings(projection) do
    case unmodeled_write_sections(write_map(projection)) do
      [] ->
        []

      sections ->
        [
          %{
            code: :unmodeled_write_sections,
            message: "writes contains sections that are not projected by the Updato contract yet",
            sections: sections
          }
        ]
    end
  end

  defp append_warnings(%Diagnostics{} = diagnostics, []), do: diagnostics

  defp append_warnings(%Diagnostics{} = diagnostics, warnings) do
    %{diagnostics | warnings: diagnostics.warnings ++ warnings}
  end

  defp unmodeled_write_sections(writes) when is_map(writes) do
    known_sections = Enum.map(@known_write_sections, &section_id/1)

    writes
    |> Map.keys()
    |> Enum.reject(&(section_id(&1) in known_sections))
    |> Enum.sort_by(&id/1)
  end

  defp write_map(projection), do: write_map(projection, :writes)

  defp write_map(map, key) when is_map(map) do
    case map_value(map, key, %{}) do
      section when is_map(section) -> section
      _other -> %{}
    end
  end

  defp write_list(map, key) when is_map(map) do
    case map_value(map, key, []) do
      nil -> []
      values when is_list(values) -> values
      value -> [value]
    end
  end

  defp field_config(columns, field) when is_map(columns) do
    Enum.find_value(columns, %{}, fn {column, config} ->
      if id(column) == id(field), do: config
    end)
  end

  defp field_config(_columns, _field), do: %{}

  defp field_validators(spec) do
    case map_value(spec, :validators, map_value(spec, :validations, [])) do
      nil -> []
      validators when is_list(validators) -> validators
      validator -> [validator]
    end
  end

  defp field_groups(nil), do: []

  defp field_groups(groups) when is_list(groups) do
    Enum.map(groups, fn
      group when is_list(group) -> Enum.map(group, &id/1)
      field -> [id(field)]
    end)
  end

  defp field_groups(group), do: [[id(group)]]

  defp operation_ids(operations) do
    operations
    |> List.wrap()
    |> Enum.map(&id/1)
  end

  defp field_id_or_nil(nil), do: nil
  defp field_id_or_nil(value), do: id(value)

  defp choice_reference(reference) when is_map(reference) do
    reference
    |> Map.take([
      :choice_source,
      "choice_source",
      :value_source,
      "value_source",
      :caption_source,
      "caption_source"
    ])
    |> compact()
  end

  defp choice_reference(_reference), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, default)
  end

  defp map_value(_map, _key, default), do: default

  defp compact(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, value} when is_map(value) -> map_size(value) == 0
      _entry -> false
    end)
    |> Map.new()
  end

  defp sorted_entries(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> id(key) end)
  end

  defp section_id(section), do: id(section)
  defp id(value) when is_atom(value), do: Atom.to_string(value)
  defp id(value) when is_binary(value), do: value
  defp id(value), do: inspect(value)

  defp json_encode_opts(opts) do
    opts
    |> Keyword.take([:pretty])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc false
  @spec json_safe(term()) :: term()
  def json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json_safe(%Date{} = value), do: Date.to_iso8601(value)
  def json_safe(%Time{} = value), do: Time.to_iso8601(value)
  def json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def json_safe(%Regex{} = value), do: inspect(value)
  def json_safe(value) when is_function(value), do: inspect(value)
  def json_safe(value) when is_pid(value), do: inspect(value)
  def json_safe(value) when is_port(value), do: inspect(value)
  def json_safe(value) when is_reference(value), do: inspect(value)
  def json_safe(value) when is_struct(value), do: value |> Map.from_struct() |> json_safe()

  def json_safe(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, value}, acc ->
      case json_safe(value) do
        nil -> acc
        safe_value -> Map.put(acc, json_key(key), safe_value)
      end
    end)
  end

  def json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  def json_safe(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> json_safe()
  end

  def json_safe(value) when is_atom(value) and value in [nil, true, false], do: value
  def json_safe(value) when is_atom(value), do: Atom.to_string(value)
  def json_safe(value) when is_binary(value), do: value
  def json_safe(value) when is_number(value), do: value
  def json_safe(value), do: inspect(value)

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key)
end
