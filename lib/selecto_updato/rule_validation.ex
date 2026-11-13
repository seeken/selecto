defmodule SelectoUpdato.RuleValidation do
  @moduledoc false

  alias Selecto.Domain.WriteContract
  alias Selecto.Rule.{Contract, Evaluator, Legacy}

  alias Selecto.Write.{
    RecordState,
    RuleCandidateRequest,
    UpsertCandidateRequest,
    UpsertCandidateState
  }

  alias SelectoUpdato.{CandidateState, Error, Mutation, StorageDependencies}

  @spec validate_candidate(atom(), WriteContract.t(), [map()]) ::
          {:ok, [map()]} | {:error, Error.t()}
  def validate_candidate(operation, %WriteContract{} = contract, assignments) do
    validate_candidate(operation, contract, assignments, [])
  end

  @spec validate_candidate(atom(), WriteContract.t(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def validate_candidate(operation, %WriteContract{} = contract, assignments, opts) do
    values = Map.new(assignments, &{&1.field, literal(&1.value)})

    with {:ok, values} <- validate_input(operation, contract, values) do
      assignments =
        Enum.map(assignments, &%{&1 | value: {:literal, Map.fetch!(values, &1.field)}})

      validate_storage_candidate(operation, contract, assignments, opts)
    end
  end

  @doc false
  def validate_input(operation, %WriteContract{} = contract, values) do
    rules = rules_for_fields(contract)
    expressions? = Enum.any?(values, fn {_field, value} -> Mutation.expression?(value) end)

    input_rules? =
      Enum.any?(rules.bindings, fn {_id, binding} ->
        binding.stage == "input" and
          (binding.operations == [] or Atom.to_string(operation) in binding.operations)
      end)

    if expressions? and input_rules? do
      mutation_pending("Submitted-input rules cannot consume mutation expressions")
    else
      rules
      |> Evaluator.evaluate(:input, stringify_keys(values), operation: operation)
      |> accept()
    end
  end

  # The portable compiler validates original INPUT before it creates assignments.
  # Keep the storage stage separate so those normalizers cannot run a second time.
  @doc false
  def validate_storage_candidate(operation, %WriteContract{} = contract, assignments, opts) do
    if operation == :upsert and requires_record_state?(:upsert, contract) do
      upsert_strategy_unavailable()
    else
      do_validate_storage_candidate(operation, contract, assignments, opts)
    end
  end

  defp do_validate_storage_candidate(operation, contract, assignments, opts) do
    opts = storage_options(operation, contract, opts)
    values = Map.new(assignments, &{&1.field, literal(&1.value)})
    rules = rules_for_fields(contract)

    with {:ok, values} <- validate_legacy_fields(contract, values),
         {:ok, candidate_values} <- candidate_values(operation, values, opts),
         candidate_result <-
           Evaluator.evaluate(rules, :candidate, candidate_values, operation: operation),
         {:ok, normalized} <- accept(candidate_result),
         {:ok, stored_normalized} <- project_values(operation, normalized, opts),
         :ok <- stable_normalization(normalized, stored_normalized),
         :ok <- stable_mutations(assignments, candidate_values, normalized) do
      assigned = MapSet.new(assignments, &to_string(&1.field))

      additional =
        normalized
        |> Enum.filter(fn {field, value} ->
          not MapSet.member?(assigned, to_string(field)) and
            Map.has_key?(candidate_values, field) and value != Map.get(candidate_values, field)
        end)
        |> Enum.sort()
        |> Enum.map(fn {field, value} -> %{field: to_string(field), value: {:literal, value}} end)

      {:ok,
       Enum.map(assignments, fn assignment ->
         case assignment.value do
           {:mutation, _} -> assignment
           _ -> %{assignment | value: {:literal, Map.fetch!(normalized, assignment.field)}}
         end
       end) ++ additional}
    end
  end

  # Unlike an update, an upsert candidate cannot be formed by merging all
  # submitted attributes into one selected row. The native arbiter and the
  # actual conflict-update whitelist decide which values can persist.
  @doc false
  def validate_upsert_candidate(%WriteContract{} = contract, assignments, command, opts) do
    subject = make_ref()
    types = Keyword.fetch!(opts, :rule_candidate_types)
    rules = rules_for_fields(contract)

    request = %UpsertCandidateRequest{
      command: command,
      field_types: types,
      dependencies: StorageDependencies.fields(rules, :upsert, Map.keys(types)),
      context: Keyword.get(opts, :context, %{}),
      subject: subject
    }

    submitted = Map.new(assignments, &{&1.field, literal(&1.value)})

    with {:ok, _values} <- validate_legacy_fields(contract, submitted),
         {:ok, state} <- project_upsert(request, opts),
         {:ok, request, state} <- choice_upsert_state(request, state, rules, opts),
         {:ok, normalized} <-
           rules |> Evaluator.evaluate(:candidate, state.values, operation: :upsert) |> accept(),
         :ok <- stable_mutations(assignments, state.values, normalized),
         {:ok, realized} <- realize_upsert_assignments(assignments, state, normalized, command) do
      {:ok, realized, %{request: request, state: state, normalized: normalized}}
    end
  end

  defp choice_upsert_state(request, state, rules, opts) do
    normalizes? =
      Enum.any?(rules.bindings, fn {_id, binding} ->
        binding.stage == "candidate" and not is_nil(Map.get(binding, :normalizer)) and
          (binding.operations == [] or "upsert" in binding.operations)
      end)

    needs_record? =
      Keyword.get(opts, :upsert_choice_candidate?, false) and
        (state.branch == :insert or state.effect == :update or normalizes?)

    fields = Map.keys(request.field_types) |> Enum.map(&to_string/1) |> Enum.sort()

    if needs_record? and Enum.sort(request.dependencies) != fields do
      # A membership resolver may consume the complete prospective record.
      # Expand only after the native branch is known, so an unchanged conflict
      # with no candidate normalizers needs neither a resolver nor unused
      # default/generated-field proof.
      expanded = %{request | dependencies: fields, prior: state.receipt}

      with {:ok, complete} <- project_upsert(expanded, opts),
           true <- complete.branch == state.branch and complete.effect == state.effect,
           true <- complete.prior_values === state.prior_values,
           true <- Map.take(complete.values, Map.keys(state.values)) === state.values do
        {:ok, expanded, complete}
      else
        false -> mutation_pending("Choice record projection changed the protected upsert state")
        {:error, _} = error -> error
      end
    else
      {:ok, request, state}
    end
  end

  @doc false
  def finalize_upsert_candidate(%WriteContract{} = contract, command, proof, opts) do
    request = %{proof.request | command: command, prior: proof.state.receipt}

    with {:ok, state} <- project_upsert(request, opts),
         true <- state.branch == proof.state.branch,
         true <- state.prior_values === proof.state.prior_values,
         true <- proof.normalized === state.values,
         :ok <- reject_obligations_values(:upsert, contract, state.values) do
      metadata =
        command.metadata
        |> Map.put(:protected_upsert_receipt, state.receipt)
        |> Map.put(:protected_upsert_subject, request.subject)

      {:ok, %{command | metadata: metadata}}
    else
      false ->
        mutation_pending("Upsert normalization changed the protected branch or canonical values")

      {:error, _} = error ->
        error
    end
  end

  defp project_upsert(request, opts) do
    provider = Keyword.get(opts, :upsert_candidate_provider)

    if Keyword.get(opts, :protected_upsert_candidates?, false) == true and
         is_function(provider, 1) do
      case provider.(request) do
        {:ok, %UpsertCandidateState{} = state} ->
          validate_upsert_state(state, request)

        {:error, %Selecto.Write.Error{} = error} ->
          {:error, Error.new(error.type, error.message, details: error.details)}

        {:error, %Error{}} = error ->
          error

        _ ->
          mutation_pending("Protected native upsert state is unavailable")
      end
    else
      upsert_strategy_unavailable()
    end
  end

  defp validate_upsert_state(state, request) do
    types = MapSet.new(Map.keys(request.field_types), &to_string/1)

    with true <- state.format == "selecto.upsert_candidate_state" and state.format_version == 1,
         true <- state.complete? == true and state.protection in [:locked, :serializable],
         true <- is_reference(state.receipt),
         true <-
           {state.branch, state.effect} in [
             {:insert, :insert},
             {:conflict, :update},
             {:conflict, :nothing}
           ],
         {:ok, values} <- upsert_values(state.values, types),
         {:ok, prior_values} <- upsert_values(state.prior_values, types),
         true <- state.branch != :insert or prior_values == %{},
         true <- Enum.all?(request.dependencies, &Map.has_key?(values, to_string(&1))) do
      {:ok, %{state | values: values, prior_values: prior_values}}
    else
      _ -> mutation_pending("Protected native upsert state is incomplete or invalid")
    end
  end

  defp upsert_values(values, types) when is_map(values) and not is_struct(values) do
    keys = Map.keys(values)

    if Enum.all?(keys, &(is_atom(&1) or is_binary(&1))) do
      normalized = stringify_keys(values)

      if map_size(normalized) == map_size(values) and
           Enum.all?(Map.keys(normalized), &MapSet.member?(types, &1)),
         do: {:ok, normalized},
         else: :error
    else
      :error
    end
  end

  defp upsert_values(_values, _types), do: :error

  defp realize_upsert_assignments(assignments, state, normalized, command) do
    assigned = MapSet.new(assignments, &to_string(&1.field))
    updated = MapSet.new(command.metadata.upsert_update_fields, &to_string/1)

    ignored_changed? =
      state.branch == :conflict and
        Enum.any?(assignments, fn assignment ->
          field = to_string(assignment.field)

          not MapSet.member?(updated, field) and
            Map.get(normalized, field) !== Map.get(state.values, field)
        end)

    if ignored_changed? do
      mutation_pending(
        "Candidate normalizers cannot change a field excluded from conflict updates"
      )
    else
      additional =
        normalized
        |> Enum.filter(fn {field, value} ->
          not MapSet.member?(assigned, to_string(field)) and
            Map.has_key?(state.values, field) and value !== Map.get(state.values, field)
        end)
        |> Enum.sort()
        |> Enum.map(fn {field, value} -> %{field: to_string(field), value: {:literal, value}} end)

      realized =
        Enum.map(assignments, fn assignment ->
          field = to_string(assignment.field)

          if (state.branch == :insert or MapSet.member?(updated, field)) and
               not match?({:mutation, _}, assignment.value) do
            case Map.fetch(normalized, field) do
              {:ok, value} -> %{assignment | value: {:literal, value}}
              :error -> assignment
            end
          else
            # Retain insert-only attributes for the native INSERT checks. They
            # do not replace protected values in the conflict candidate.
            assignment
          end
        end)

      {:ok, realized ++ additional}
    end
  end

  defp upsert_strategy_unavailable do
    {:error,
     Error.new(
       :unsupported_operation,
       "Required upsert data rules need an adapter-owned protected branch strategy",
       details: %{code: :upsert_rule_strategy_unsupported}
     )}
  end

  defp storage_options(operation, contract, opts) do
    fields =
      StorageDependencies.fields(
        rules_for_fields(contract),
        operation,
        Map.keys(Keyword.get(opts, :rule_candidate_types, %{}))
      )

    opts = Keyword.put(opts, :rule_candidate_dependency_fields, fields)
    if fields == [], do: Keyword.put(opts, :native_rule_candidate?, false), else: opts
  end

  @doc false
  def requires_storage_candidate?(operation, %WriteContract{rules: rules}) do
    StorageDependencies.storage?(rules, operation)
  end

  @doc false
  @spec requires_record_state?(atom(), WriteContract.t()) :: boolean()
  def requires_record_state?(operation, %WriteContract{} = contract)
      when operation in [:update, :upsert] do
    rules = rules_for_fields(contract)

    Enum.any?(rules.bindings, fn {_id, binding} ->
      binding.stage in ["candidate", "transaction", "evidence"] and
        (binding.operations == [] or Atom.to_string(operation) in binding.operations)
    end)
  end

  def requires_record_state?(_operation, _contract), do: false

  @doc false
  @spec native_constraints(atom(), WriteContract.t()) :: [map()]
  def native_constraints(operation, %WriteContract{} = contract) do
    contract
    |> rules_for_fields()
    |> Map.fetch!(:bindings)
    |> Enum.flat_map(fn {binding_id, binding} ->
      native = Map.get(binding, :native_constraint)

      if binding.enforcement == "required" and is_map(native) and
           (binding.operations == [] or Atom.to_string(operation) in binding.operations) do
        [
          %{
            binding_id: binding_id,
            adapter: native.adapter,
            constraint: native.constraint,
            category: native_constraint_category(native.category)
          }
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(&{&1.adapter, &1.constraint, &1.binding_id})
  end

  @doc false
  @spec ensure_supported_operation_rules(SelectoUpdato.Operation.t(), WriteContract.t()) ::
          :ok | {:error, Error.t()}
  def ensure_supported_operation_rules(
        %SelectoUpdato.Operation{type: :upsert},
        %WriteContract{} = contract
      ) do
    # The compiler supplies the actual command to an adapter-owned upsert
    # projector when these rules need branch state. Inspection and execution
    # both fail closed without that strategy; a submitted-only merge is not a
    # protected conflict candidate.
    _ = contract
    :ok
  end

  def ensure_supported_operation_rules(
        %SelectoUpdato.Operation{type: :update} = operation,
        %WriteContract{} = contract
      ) do
    unsupported = final_state_bindings(:update, contract)

    if bulk_selection?(operation) and unsupported != [] do
      {:error,
       Error.new(
         :unsupported_operation,
         "data rules need a selected-row bulk strategy",
         details: %{code: :bulk_rule_strategy_unsupported, bindings: unsupported}
       )}
    else
      :ok
    end
  end

  def ensure_supported_operation_rules(
        %SelectoUpdato.Operation{type: :delete},
        %WriteContract{} = contract
      ) do
    unsupported = final_state_bindings(:delete, contract)

    if unsupported == [] do
      :ok
    else
      {:error,
       Error.new(
         :unsupported_operation,
         "data rules need a post-delete strategy",
         details: %{code: :delete_rule_strategy_unsupported, bindings: unsupported}
       )}
    end
  end

  def ensure_supported_operation_rules(%SelectoUpdato.Operation{}, _contract), do: :ok

  defp final_state_bindings(operation, contract) do
    contract.rules.bindings
    |> Enum.filter(fn {_id, binding} ->
      binding.stage in ["candidate", "transaction", "evidence"] and
        (binding.operations == [] or Atom.to_string(operation) in binding.operations)
    end)
    |> Enum.map(fn {id, binding} -> %{binding_id: id, stage: binding.stage} end)
  end

  defp bulk_selection?(%SelectoUpdato.Operation{expected_cardinality: {:exactly, 1}}), do: false
  defp bulk_selection?(%SelectoUpdato.Operation{expected_cardinality: nil}), do: false
  defp bulk_selection?(%SelectoUpdato.Operation{}), do: true

  @spec reject_pending_obligations(atom(), WriteContract.t(), [map()]) ::
          :ok | {:error, Error.t()}
  def reject_pending_obligations(operation, %WriteContract{} = contract, assignments) do
    reject_pending_obligations(operation, contract, assignments, [])
  end

  @spec reject_pending_obligations(atom(), WriteContract.t(), [map()], keyword()) ::
          :ok | {:error, Error.t()}
  def reject_pending_obligations(operation, %WriteContract{} = contract, assignments, opts) do
    opts = storage_options(operation, contract, opts)
    values = Map.new(assignments, &{&1.field, literal(&1.value)})

    with {:ok, values} <- candidate_values(operation, values, opts) do
      reject_obligations_values(operation, contract, values)
    end
  end

  defp reject_obligations_values(operation, contract, values) do
    rules = rules_for_fields(contract)

    Enum.reduce_while([:transaction, :evidence], :ok, fn stage, :ok ->
      result = Evaluator.evaluate(rules, stage, values, operation: operation)

      if result.disposition == :passed do
        {:cont, :ok}
      else
        case accept(result) do
          {:error, error} -> {:halt, {:error, error}}
        end
      end
    end)
  end

  @doc false
  @spec validate_nested_collection(
          atom(),
          WriteContract.t(),
          atom() | String.t(),
          [map()],
          atom(),
          [term()],
          [atom() | String.t()],
          [atom() | String.t()],
          atom() | String.t(),
          atom() | String.t(),
          atom() | String.t(),
          keyword()
        ) :: {:ok, [map()]} | {:error, Error.t()}
  def validate_nested_collection(
        operation,
        %WriteContract{} = contract,
        relationship,
        entries,
        representation,
        path,
        identity_fields,
        fields,
        parent_key,
        child_relation,
        child_key,
        opts
      ) do
    relationship = to_string(relationship)
    rules = rules_for_relationship(contract, relationship)

    opts =
      Keyword.put(
        opts,
        :rule_candidate_dependency_fields,
        StorageDependencies.collection_fields(
          rules,
          operation,
          relationship,
          Map.keys(Keyword.get(opts, :collection_field_types, %{}))
        )
      )

    opts =
      if StorageDependencies.storage?(rules, operation),
        do: opts,
        else: Keyword.put(opts, :native_rule_candidate?, false)

    if map_size(rules.bindings) == 0 do
      {:ok, entries}
    else
      active = active_nested_entries(entries)
      submitted = Enum.map(active, fn {_index, entry} -> entry.attrs end)
      input_values = %{relationship => submitted}

      with input <- Evaluator.evaluate(rules, :input, input_values, operation: operation),
           {:ok, input_values} <- accept_nested(input, path),
           {:ok, candidate_rows, source} <-
             complete_candidate(
               rules,
               operation,
               relationship,
               entries,
               representation,
               path,
               identity_fields,
               fields,
               parent_key,
               child_relation,
               child_key,
               opts,
               input_values
             ),
           {:ok, candidate_rows} <-
             project_collection_rows(operation, candidate_rows, child_relation, opts),
           candidate_values = %{relationship => candidate_rows},
           candidate <-
             Evaluator.evaluate(rules, :candidate, candidate_values, operation: operation),
           {:ok, candidate_values} <- accept_nested(candidate, path),
           :ok <-
             stable_hydrated_normalization(
               source,
               candidate_rows,
               Map.fetch!(candidate_values, relationship)
             ),
           {:ok, stored_rows} <-
             project_collection_rows(
               operation,
               Map.fetch!(candidate_values, relationship),
               child_relation,
               opts
             ),
           :ok <- stable_normalization(Map.fetch!(candidate_values, relationship), stored_rows),
           :ok <- reject_nested_obligations(rules, operation, candidate_values, path),
           {:ok, normalized} <-
             normalized_submitted(
               source,
               input_values,
               candidate_values,
               relationship,
               length(active),
               path
             ) do
        {:ok, put_active_nested_entries(entries, active, normalized)}
      end
    end
  end

  @spec validate_action_inputs(Contract.t(), atom() | String.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def validate_action_inputs(%Contract{} = contract, action, values) do
    contract
    |> Evaluator.evaluate(:action_input, values, action: action)
    |> case do
      %{disposition: :passed, values: normalized} -> {:ok, normalized}
      result -> {:error, action_error(result)}
    end
  end

  @spec validate_inline(map(), term(), [term()]) :: :ok | {:error, map()}
  def validate_inline(spec, value, path) do
    spec = merge_raw_spec(spec)

    with {:ok, tests} <- Legacy.input_tests(spec),
         :ok <- evaluate_inline_tests(tests, value, path) do
      :ok
    else
      {:error, {:unsupported, validator}} ->
        {:error,
         action_input_error(
           :unsupported_action_input_rule,
           path,
           "Action input rule is unsupported.",
           validator: inspect(validator)
         )}

      {:error, error} when is_map(error) ->
        {:error, error}
    end
  end

  defp validate_legacy_fields(contract, values) do
    Enum.reduce_while(values, {:ok, values}, fn {field, value}, {:ok, current} ->
      validators =
        contract
        |> WriteContract.field_spec(field)
        |> case do
          %{} = spec -> Map.get(spec, :validators, [])
          nil -> []
        end

      case evaluate_legacy_validators(validators, value, [field]) do
        :ok -> {:cont, {:ok, current}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp candidate_values(operation, submitted, opts) do
    expressions? = Enum.any?(submitted, fn {_field, value} -> match?({:mutation, _}, value) end)

    if expressions? and Keyword.get(opts, :rule_candidate_dependency_fields, []) != [] do
      mutation_candidate_values(operation, submitted, opts)
    else
      with {:ok, values} <- raw_candidate_values(operation, submitted, opts) do
        project_values(operation, values, opts)
      end
    end
  end

  defp mutation_candidate_values(operation, submitted, opts) do
    provider = Keyword.get(opts, :record_state_provider)
    request = Keyword.get(opts, :record_state_request)

    if Keyword.get(opts, :native_rule_candidate?, false) and operation == :update and
         is_function(provider, 1) and not is_nil(request) do
      case provider.(request) do
        {:ok, %RecordState{values: source, complete?: true, protection: protection}}
        when is_map(source) and protection in [:locked, :serializable] ->
          source = stringify_keys(source)
          context = Map.put(Keyword.get(opts, :context, %{}), :selecto_mutation_source, source)

          project_values(
            operation,
            Map.merge(source, submitted),
            Keyword.put(opts, :context, context)
          )

        _ ->
          mutation_pending("Protected mutation source values are unavailable")
      end
    else
      mutation_pending("Mutation rules require a protected single-row update")
    end
  end

  defp stable_mutations(assignments, before, normalized) do
    if Enum.all?(assignments, fn assignment ->
         not match?({:mutation, _}, assignment.value) or
           Map.fetch!(before, assignment.field) == Map.fetch!(normalized, assignment.field)
       end),
       do: :ok,
       else: mutation_pending("Candidate normalizers cannot rewrite a mutation expression")
  end

  defp mutation_pending(message),
    do: {:error, Error.new(:validation, message, details: %{code: :required_data_rule_pending})}

  defp stable_normalization(normalized, stored) do
    if normalized == stored,
      do: :ok,
      else:
        {:error,
         Error.new(:validation, "normalization is not stable under native storage",
           details: %{code: :required_data_rule_pending}
         )}
  end

  defp project_values(operation, values, opts) do
    case {Keyword.get(opts, :native_rule_candidate?, false),
          Keyword.get(opts, :rule_candidate_provider)} do
      {true, provider} when is_function(provider, 1) ->
        request = %RuleCandidateRequest{
          operation: operation,
          relation: Keyword.fetch!(opts, :rule_candidate_relation),
          values: values,
          field_types: Keyword.fetch!(opts, :rule_candidate_types),
          context:
            opts
            |> Keyword.get(:context, %{})
            |> Map.put(
              :selecto_rule_candidate_dependencies,
              Keyword.get(opts, :rule_candidate_dependency_fields, :all)
            )
        }

        case provider.(request) do
          {:ok, %RecordState{values: stored, complete?: true, protection: protection}}
          when is_map(stored) and protection in [:locked, :serializable] ->
            {:ok, stringify_keys(stored)}

          {:error, %Selecto.Write.Error{} = error} ->
            {:error, Error.new(error.type, error.message, details: error.details)}

          _ ->
            {:error,
             Error.new(:validation, "protected storage candidate is unavailable",
               details: %{code: :required_data_rule_pending}
             )}
        end

      {true, _} ->
        {:error,
         Error.new(:validation, "protected storage candidate is unavailable",
           details: %{code: :required_data_rule_pending}
         )}

      _ ->
        {:ok, values}
    end
  end

  defp raw_candidate_values(operation, submitted, opts) when operation in [:update, :upsert] do
    case {Keyword.get(opts, :record_state_provider), Keyword.get(opts, :record_state_request)} do
      {_provider, nil} ->
        if Keyword.get(opts, :require_protected_record_state, false) do
          {:error,
           Error.new(:validation, "protected record state request is unavailable",
             details: %{code: :record_state_unavailable}
           )}
        else
          {:ok, submitted}
        end

      {nil, _request} ->
        if Keyword.get(opts, :require_protected_record_state, false) do
          {:error,
           Error.new(:validation, "protected record state provider is unavailable",
             details: %{code: :record_state_unavailable}
           )}
        else
          {:ok, submitted}
        end

      {provider, request} when is_function(provider, 1) and not is_nil(request) ->
        case provider.(request) do
          {:ok,
           %RecordState{
             values: values,
             complete?: true,
             protection: protection
           }}
          when protection in [:locked, :serializable]
          when is_map(values) ->
            {:ok, Map.merge(stringify_keys(values), submitted)}

          {:ok, %RecordState{}} ->
            {:error,
             Error.new(:validation, "protected record state is incomplete",
               details: %{code: :record_state_unavailable}
             )}

          {:error, %Selecto.Write.Error{} = error} ->
            {:error, Error.new(error.type, error.message, details: error.details)}

          _ ->
            {:error,
             Error.new(:validation, "protected record state provider failed",
               details: %{code: :record_state_unavailable}
             )}
        end

      _ ->
        {:error,
         Error.new(:validation, "protected record state provider is invalid",
           details: %{code: :record_state_unavailable}
         )}
    end
  end

  defp raw_candidate_values(_operation, submitted, _opts), do: {:ok, submitted}

  defp stringify_keys(values) do
    Map.new(values, fn {key, value} -> {to_string(key), value} end)
  end

  defp rules_for_fields(%WriteContract{rules: rules, source: source}) do
    ids =
      source
      |> Map.get(:columns, Map.get(source, "columns", %{}))
      |> Map.keys()
      |> MapSet.new(&to_string/1)

    select_rule_bindings(rules, &MapSet.member?(ids, first_subject_segment(&1)))
  end

  defp native_constraint_category("unique_violation"), do: :unique_violation
  defp native_constraint_category("foreign_key_violation"), do: :foreign_key_violation
  defp native_constraint_category("not_null_violation"), do: :not_null_violation
  defp native_constraint_category("check_violation"), do: :check_violation

  defp rules_for_relationship(%WriteContract{rules: rules}, relationship) do
    select_rule_bindings(rules, &(first_subject_segment(&1) == relationship))
  end

  defp select_rule_bindings(%Contract{} = rules, predicate) do
    %{rules | bindings: Map.filter(rules.bindings, fn {_id, binding} -> predicate.(binding) end)}
  end

  defp first_subject_segment(%{subject: %{path: [segment | _]}}), do: to_string(segment)
  defp first_subject_segment(_binding), do: nil

  defp active_nested_entries(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reject(fn {entry, _index} -> entry.operation in [:delete, :unlink] end)
    |> Enum.map(fn {entry, index} -> {index, entry} end)
  end

  defp put_active_nested_entries(entries, active, normalized) do
    Enum.zip(active, normalized)
    |> Enum.reduce(entries, fn {{index, entry}, attrs}, current ->
      List.replace_at(current, index, %{entry | attrs: attrs})
    end)
  end

  defp complete_candidate(
         rules,
         operation,
         relationship,
         entries,
         representation,
         path,
         identity_fields,
         fields,
         parent_key,
         child_relation,
         child_key,
         opts,
         input_values
       ) do
    operation = to_string(operation)

    candidate? =
      Enum.any?(rules.bindings, fn {_id, binding} ->
        binding.stage in ["candidate", "transaction", "evidence"] and
          (binding.operations == [] or operation in binding.operations)
      end)

    cond do
      not candidate? or operation == "insert" or representation in [:full_set, :replace_one] ->
        {:ok, Map.fetch!(input_values, relationship), :submitted}

      true ->
        request = %Selecto.Write.CandidateRequest{
          operation: operation,
          representation: representation,
          relationship: relationship,
          path: path,
          parent_command: Keyword.fetch!(opts, :candidate_parent_command),
          parent_key: parent_key,
          child_relation: child_relation,
          child_key: child_key,
          context: Keyword.get(opts, :context, %{}),
          identity_fields: Enum.map(identity_fields, &to_string/1),
          fields: fields |> Enum.map(&to_string/1) |> Enum.sort(),
          field_types: Keyword.get(opts, :collection_field_types, %{}),
          scope_predicate: Keyword.get(opts, :collection_scope_predicate),
          max_rows: CandidateState.max_rows()
        }

        case CandidateState.materialize(
               Keyword.get(opts, :candidate_state_provider),
               request,
               entries
             ) do
          {:ok, rows, _state} -> {:ok, rows, :hydrated}
          {:error, %Error{} = error} -> {:error, error}
        end
    end
  end

  defp project_collection_rows(operation, rows, relation, opts) do
    projection_opts =
      opts
      |> Keyword.put(:rule_candidate_relation, relation)
      |> Keyword.put(:rule_candidate_types, Keyword.get(opts, :collection_field_types, %{}))

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, result} ->
      case project_values(operation, stringify_keys(row), projection_opts) do
        {:ok, projected} -> {:cont, {:ok, result ++ [projected]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp stable_hydrated_normalization(:submitted, _before, _after), do: :ok

  defp stable_hydrated_normalization(:hydrated, before, after_values),
    do: stable_normalization(before, after_values)

  defp normalized_submitted(
         :submitted,
         _input_values,
         candidate_values,
         relationship,
         expected,
         path
       ),
       do: fetch_nested_values(candidate_values, relationship, expected, path)

  defp normalized_submitted(
         :hydrated,
         input_values,
         candidate_values,
         relationship,
         expected,
         path
       ) do
    with {:ok, submitted} <- fetch_nested_values(input_values, relationship, expected, path),
         candidate when is_list(candidate) <- Map.get(candidate_values, relationship),
         true <- Enum.all?(candidate, &is_map/1) do
      {:ok, submitted}
    else
      _other ->
        {:error,
         Error.new(:validation, "nested candidate data rule normalization is invalid",
           details: %{code: :data_rule_error, path: path}
         )}
    end
  end

  defp reject_nested_obligations(rules, operation, values, path) do
    Enum.reduce_while([:transaction, :evidence], :ok, fn stage, :ok ->
      result = Evaluator.evaluate(rules, stage, values, operation: operation)

      case accept_nested(result, path) do
        {:ok, _values} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp fetch_nested_values(values, relationship, expected, path) do
    case Map.fetch(values, relationship) do
      {:ok, normalized} when is_list(normalized) and length(normalized) == expected ->
        {:ok, normalized}

      _other ->
        {:error,
         Error.new(:validation, "nested data rule normalization changed collection shape",
           details: %{code: :data_rule_error, path: path}
         )}
    end
  end

  defp accept_nested(%{disposition: :passed, values: values}, _path), do: {:ok, values}

  defp accept_nested(result, path) do
    {:error,
     Error.new(:validation, "nested data rule validation failed",
       details: %{
         code: disposition_code(result.disposition),
         disposition: result.disposition,
         path: path,
         outcomes: result.outcomes,
         obligations: result.obligations
       }
     )}
  end

  defp evaluate_legacy_validators(validators, value, path) do
    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case Legacy.field_test(validator) do
        {:ok, test} ->
          case Evaluator.evaluate_test(test, value) do
            :passed -> {:cont, :ok}
            result -> {:halt, {:error, write_error(path, result)}}
          end

        :unsupported ->
          {:halt,
           {:error,
            Error.new(:validation, "write field validator is unsupported",
              details: %{code: :unsupported_write_rule, path: path, validator: inspect(validator)}
            )}}
      end
    end)
  end

  defp evaluate_inline_tests(tests, value, path) do
    Enum.reduce_while(tests, :ok, fn test, :ok ->
      case Contract.compile_test(test) do
        {:ok, compiled} ->
          case Evaluator.evaluate_test(compiled, value) do
            :passed -> {:cont, :ok}
            result -> {:halt, {:error, action_input_error(path, result)}}
          end

        {:error, error} ->
          {:halt,
           {:error,
            action_input_error(:invalid_action_input_rule, path, "Action input rule is invalid.",
              rule_error: error
            )}}
      end
    end)
  end

  defp accept(%{disposition: :passed, values: values}), do: {:ok, values}

  defp accept(result) do
    {:error,
     Error.new(:validation, "data rule validation failed",
       details: %{
         code: disposition_code(result.disposition),
         disposition: result.disposition,
         outcomes: result.outcomes,
         obligations: result.obligations
       }
     )}
  end

  defp write_error(path, result) do
    Error.new(:validation, "write field validation failed",
      details: %{code: :data_rule_failed, path: path, result: result}
    )
  end

  defp action_error(result) do
    %{
      code: disposition_code(result.disposition),
      path: [:intent, :inputs],
      message: "Action input data rule validation failed.",
      disposition: result.disposition,
      outcomes: result.outcomes,
      obligations: result.obligations
    }
  end

  defp action_input_error(path, {:failed, details}) do
    action_input_error(:invalid_action_input_value, path, details.message,
      rule_code: details.code,
      rule_details: Map.drop(details, [:code, :message])
    )
  end

  defp action_input_error(path, {:error, details}) do
    action_input_error(:action_input_rule_error, path, details.message,
      rule_code: details.code,
      rule_details: Map.drop(details, [:code, :message])
    )
  end

  defp action_input_error(code, path, message, details) do
    details |> Map.new() |> Map.merge(%{code: code, path: path, message: message})
  end

  defp merge_raw_spec(spec) do
    case Map.get(spec, :raw, Map.get(spec, "raw")) do
      %{} = raw -> Map.merge(raw, Map.drop(spec, [:raw, "raw"]))
      _ -> spec
    end
  end

  defp literal({:literal, value}), do: value
  defp literal(value), do: value
  defp disposition_code(:pending), do: :required_data_rule_pending
  defp disposition_code(:failed), do: :data_rule_failed
  defp disposition_code(_disposition), do: :data_rule_error
end
