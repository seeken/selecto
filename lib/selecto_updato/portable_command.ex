defmodule SelectoUpdato.PortableCommand do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core
  alias Selecto.Domain
  alias Selecto.Domain.WriteContract
  alias Selecto.Write.{Command, RecordRequest}

  alias SelectoUpdato.{
    ActionAuthorization,
    ChoiceMembership,
    Error,
    NestedGraph,
    Mutation,
    Operation,
    PlannedOperation,
    QueryEnforcement,
    RuleValidation,
    Tenant,
    Upsert
  }

  @spec compile(Operation.t() | PlannedOperation.t(), keyword()) ::
          {:ok, Command.t() | Selecto.Write.Graph.t(), map()} | {:error, Error.t()}
  def compile(operation, opts \\ [])

  def compile(%Operation{} = operation, opts) when is_list(opts) do
    result =
      case NestedGraph.detect_nested(operation) do
        {:ok, _contract, true} ->
          NestedGraph.compile(operation, opts)

        {:ok, contract, false} ->
          # Contract was compiled from this operation's own domain within this
          # call, so it is safe to reuse; the shared pipeline stays private so
          # callers can never inject a foreign contract.
          do_compile_flat(operation, contract, opts)

        :error ->
          # Nested detection could not even compile the contract; let the flat
          # path surface the precise contract error.
          compile_flat(operation, opts)
      end

    invalidate_rejected_action(operation, result)
  end

  def compile(%PlannedOperation{}, _opts) do
    {:error,
     Error.new(:authorization, "Opaque planned operations cannot be compiled directly",
       details: %{code: :opaque_planned_operation}
     )}
  end

  @doc false
  @spec requires_prepared_record_state?(Operation.t()) :: boolean()
  def requires_prepared_record_state?(%Operation{type: operation, domain: domain})
      when operation in [:update, :upsert] do
    with {:ok, contract} <- WriteContract.compile(domain) do
      RuleValidation.requires_record_state?(operation, contract)
    else
      _ -> false
    end
  end

  def requires_prepared_record_state?(%Operation{}), do: false

  @doc false
  @spec compile_flat(Operation.t(), keyword()) ::
          {:ok, Command.t(), map()} | {:error, Error.t()}
  def compile_flat(%Operation{} = operation, opts \\ []) when is_list(opts) do
    # Public entry point: always compile the contract from the operation's own
    # domain. Caller-supplied contracts are never trusted.
    result =
      with {:ok, contract} <- compile_contract(operation.domain) do
        do_compile_flat(operation, contract, opts)
      end

    invalidate_rejected_action(operation, result)
  end

  # A malformed action can fail before the normal consumption step, including
  # phase/evidence checks and domain admission. These refusals must still burn
  # the identified grant; restoring the original builder cannot revive it.
  defp invalidate_rejected_action(%Operation{action_policy: policy}, {:error, _} = error)
       when is_map(policy) do
    if grant = map_value(policy, :authorization_grant) do
      _ = ActionAuthorization.consume(grant, %{rejected_action_operation: true})
    end

    error
  end

  defp invalidate_rejected_action(%Operation{}, result), do: result

  defp do_compile_flat(%Operation{} = operation, contract, opts) when is_list(opts) do
    native_constraints = RuleValidation.native_constraints(operation.type, contract)

    with :ok <- ensure_trusted_filters_applied(operation, opts),
         :ok <- ensure_write_policy(contract, operation.type),
         :ok <- ensure_supported_operation(contract, operation.type),
         {:ok, operation} <- Upsert.apply_domain_conflict_policy(operation),
         :ok <- RuleValidation.ensure_supported_operation_rules(operation, contract),
         {:ok, context} <- trusted_context(operation, opts),
         contract = effective_tenant_contract(contract, operation, context, opts),
         :ok <- validate_action_authorization(operation, context, opts),
         :ok <- validate_authorization_context(operation, context, opts),
         :ok <- consume_action_authorization(operation, context, opts),
         :ok <- validate_operation_identifiers(operation, contract),
         {:ok, operation} <- normalize_input_operation(operation, contract),
         :ok <- validate_tenant_conflicts(operation, contract, context),
         :ok <- validate_upsert_filters(operation, contract, context),
         :ok <- validate_upsert_tenant_target(operation, contract, context),
         {:ok, query_predicate} <- QueryEnforcement.compile(operation, contract),
         {:ok, expected_cardinality} <- resolve_expected_cardinality(operation, contract),
         {:ok, returning} <- resolve_returning(operation, contract),
         {:ok, relation} <- relation(contract),
         {:ok, assignments} <- assignments(operation, contract, context),
         {:ok, assignments} <- pin_site_assignment(assignments, operation, contract, context),
         {:ok, assignments} <- root_tenant_assignment(assignments, operation, contract, context),
         {:ok, assignments} <-
           apply_foreign_key_sources(assignments, operation, contract, context),
         :ok <- required_assignment_fields(assignments, operation.type, contract),
         {:ok, foreign_key_guards} <-
           foreign_key_guards(operation, contract, assignments, context),
         {:ok, predicate} <- predicate(operation, contract, context, query_predicate),
         {:ok, record_state_opts} <-
           record_state_options(
             operation,
             contract,
             relation,
             predicate,
             assignments,
             context,
             opts
           ),
         record_state_opts =
           opts
           |> Keyword.merge(record_state_opts)
           |> Keyword.put(:rule_candidate_relation, relation)
           |> Keyword.put(:rule_candidate_types, portable_field_types(contract))
           |> Keyword.put(:upsert_choice_candidate?, choice_candidate?(operation))
           |> Keyword.put(:context, context),
         {:ok, insert_admission} <-
           insert_admission(operation, contract, context, query_predicate, opts),
         command_attrs = %{
           operation: operation.type,
           relation: relation,
           predicate: predicate,
           expected_cardinality: expected_cardinality,
           returning: returning,
           native_constraints: native_constraints
         },
         {:ok, provisional} <-
           write_command(
             operation,
             contract,
             assignments,
             command_attrs,
             query_predicate,
             foreign_key_guards,
             insert_admission
           ),
         {:ok, assignments, upsert_proof} <-
           validate_storage_assignments(
             operation,
             contract,
             assignments,
             provisional,
             record_state_opts
           ),
         {:ok, assignments} <-
           normalized_assignment_policy(operation, contract, assignments, context),
         {:ok, assignments} <-
           apply_foreign_key_sources(assignments, operation, contract, context),
         predicate <- normalized_write_once_predicate(operation, contract, assignments, predicate),
         :ok <- validate_values_foreign_keys(operation.domain, assignments, relation),
         {:ok, foreign_key_guards} <-
           foreign_key_guards(operation, contract, assignments, context),
         {:ok, command} <-
           write_command(
             operation,
             contract,
             assignments,
             %{command_attrs | predicate: predicate},
             query_predicate,
             foreign_key_guards,
             insert_admission
           ),
         {:ok, command} <-
           finalize_storage_assignments(
             operation,
             contract,
             command,
             upsert_proof,
             record_state_opts
           ),
         :ok <- validate_choice_membership(operation, command, upsert_proof, context),
         :ok <-
           QueryEnforcement.validate_insert_candidate(
             operation,
             assignments,
             query_predicate,
             opts
           ),
         {:ok, command} <- put_post_image(command, operation, contract, context, query_predicate),
         {:ok, command} <- SelectoUpdato.DocumentAction.compile(operation, command, context) do
      {:ok, command, context}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, %Selecto.Write.Error{} = error} ->
        {:error, Error.new(error.type, error.message, details: error.details)}
    end
  end

  # Trusted required filters are never dropped: a compile reached without
  # the execution scope applying them (a direct PortableCommand.compile with
  # `required_filters:` or a context carrying them) is refused.
  # Graph children carry their root's trusted filters applied
  # (NestedGraph.bind_trusted_scope), so every compile, root or child, is
  # checked the same way; no option exempts one.
  defp ensure_trusted_filters_applied(operation, opts) do
    case Tenant.unapplied_required_filters(operation, opts) do
      [] ->
        :ok

      _filters ->
        {:error,
         Error.new(
           :invalid_tenant_scope,
           "trusted required filters must be applied by the execution scope",
           details: %{code: :trusted_required_filters_unapplied}
         )}
    end
  end

  # TW-09 post-image (user decision 2026-10-24, "bound tenant-like scope
  # only"): the stored row an INSERT or UPDATE leaves must still lie inside
  # the engine tenant and the trusted and host scope, whatever triggers,
  # generated columns or the update's own assignments did. The adapter
  # re-reads the written rows by their key after the statement, inside the
  # write's transaction, under `post_image.predicate`, and rolls back unless
  # every row matches.
  #
  # The scope is recorded by provenance, never recovered from the compiled
  # predicate: the engine tenant (bound to each tenant column the contract
  # declares), the trusted context's required filters, and a query enforced
  # as host scope. Plain required filters and query enforcement bound only
  # the pre-image of an UPDATE (it may leave status = 'open'); an INSERT has
  # no pre-image, so its re-read checks the full guard: the bound scope plus
  # the required and enforced-query predicate.
  defp put_post_image(
         %Command{operation: operation} = command,
         op,
         contract,
         context,
         query_predicate
       )
       when operation in [:insert, :update, :upsert] do
    with {:ok, scope} <- bound_scope_predicates(op, contract, context) do
      # An upsert may take either branch; its stored row is checked like an
      # insert's (no pre-image).
      predicates =
        case {operation, query_predicate} do
          {:update, _predicate} -> scope
          {_insert_or_upsert, nil} -> scope
          {_insert_or_upsert, predicate} -> scope ++ [predicate]
        end

      key = post_image_key(contract)

      cond do
        predicates == [] ->
          {:ok, command}

        key == [] ->
          post_image_unavailable("guarded writes need the relation's primary key")

        operation == :update and Enum.any?(command.assignments, &moves_key?(&1, key, command)) ->
          post_image_unavailable("a scoped update cannot assign the row's key")

        true ->
          predicate =
            case Enum.uniq(predicates) do
              [single] -> single
              many -> {:and, many}
            end

          {:ok,
           %{
             command
             | metadata: Map.put(command.metadata, :post_image, %{predicate: predicate, key: key})
           }}
      end
    end
  end

  # A DELETE leaves no row to re-read, but under a bound scope (engine
  # tenant, trusted or host scope, a tenant-pin or any other required filter,
  # query enforcement) the adapter must still refuse what acts on rows the
  # guard excludes (statement-level DELETE triggers, DELETE rules):
  # `metadata.bound_scope`.
  defp put_post_image(
         %Command{operation: :delete} = command,
         op,
         contract,
         context,
         query_predicate
       ) do
    with {:ok, scope} <- bound_scope_predicates(op, contract, context) do
      if scope == [] and is_nil(query_predicate),
        do: {:ok, command},
        else: {:ok, %{command | metadata: Map.put(command.metadata, :bound_scope, true)}}
    end
  end

  defp put_post_image(command, _operation, _contract, _context, _query_predicate),
    do: {:ok, command}

  # An assignment to a key column moves the row out from under the re-read
  # by key, unless the update's own predicate pins that column to the same
  # literal (a top-level equality conjunct), so the key cannot change.
  defp moves_key?(%{field: field, value: value}, key, %Command{predicate: predicate}) do
    field = field_id(field)

    field in key and
      not (match?({:literal, _}, value) and
             {:eq, {:field, field}, value} in top_level_conjuncts(predicate))
  end

  defp top_level_conjuncts({:and, predicates}) when is_list(predicates),
    do: Enum.flat_map(predicates, &top_level_conjuncts/1)

  defp top_level_conjuncts({:eq, {:field, field}, value}),
    do: [{:eq, {:field, field_id(field)}, value}]

  defp top_level_conjuncts(_predicate), do: []

  defp bound_scope_predicates(%Operation{} = operation, contract, context) do
    tenant =
      case context[:tenant_id] do
        nil ->
          []

        tenant_id ->
          [
            get_in(contract.scope, [:tenant, :field]),
            Core.map_value(contract.source, :tenant_field),
            contract.scope[:root_tenant_column]
          ]
          |> Enum.filter(&field_name?/1)
          |> Enum.map(&field_id/1)
          |> Enum.uniq()
          |> Enum.map(&{:eq, {:field, &1}, {:literal, tenant_id}})
      end

    host =
      case operation.query_enforcement do
        # Evidence captured before scope provenance existed keeps every
        # captured filter (stricter).
        %{host_scope: true} = evidence ->
          List.wrap(Map.get(evidence, :scope_filters, Map.get(evidence, :filters, [])))

        _ ->
          []
      end

    trusted = Keyword.get(operation.opts || [], :trusted_required_filters, [])

    # Tenant-pin rule (coordinator decision under "bound tenant-like scope
    # only"): a domain required filter that reads the declared tenant field
    # (source.tenant_field / writes.scope.tenant.field) is tenant-like and
    # bounds the post-image whole. Detection is fail-closed (w3exrev16): a
    # filter counts when ANY column it names, at any depth and under any
    # operator (ranges, OR arms, NOT, a nested AND given as one filter), is a
    # tenant field. Every other required filter bounds the pre-image only (an
    # open -> closed update must apply).
    tenant_fields =
      [get_in(contract.scope, [:tenant, :field]), Core.map_value(contract.source, :tenant_field)]
      |> Enum.filter(&field_name?/1)
      |> Enum.map(&field_id/1)

    tenant_pins =
      operation.domain
      |> map_value(:required_filters)
      |> List.wrap()
      |> Enum.filter(&reads_tenant_field?(&1, tenant_fields))

    with {:ok, trusted} <- QueryEnforcement.compile_scope_filters(trusted, operation.domain),
         {:ok, host} <- QueryEnforcement.compile_scope_filters(host, operation.domain),
         {:ok, pins} <- QueryEnforcement.compile_scope_filters(tenant_pins, operation.domain) do
      {:ok, tenant ++ Enum.reject([trusted, host, pins], &is_nil/1)}
    end
  end

  defp post_image_key(contract) do
    case Core.map_value(contract.source, :primary_key) do
      nil -> ["id"]
      keys when is_list(keys) -> Enum.map(keys, &field_id/1)
      key -> [field_id(key)]
    end
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp post_image_unavailable(message) do
    {:error,
     Error.new(:query_enforcement, message,
       details: %{code: :query_rule_not_evaluable, reason: :post_image_unavailable}
     )}
  end

  defp write_command(
         operation,
         contract,
         assignments,
         attrs,
         query_predicate,
         foreign_key_guards,
         insert_admission
       ) do
    protected_upsert? =
      operation.type == :upsert and RuleValidation.requires_record_state?(:upsert, contract)

    attrs
    |> Map.put(:assignments, assignments)
    |> Map.put(
      :required_capabilities,
      [operation.type] ++
        if(protected_upsert?, do: [:protected_upsert_candidates], else: []) ++
        if(insert_admission, do: [:typed_insert_admission], else: []) ++
        if(Enum.any?(assignments, &match?({:mutation, _}, &1.value)),
          do: [:mutation_expressions],
          else: []
        )
    )
    |> Map.put(
      :metadata,
      operation
      |> command_metadata(
        contract,
        assignments,
        query_predicate,
        foreign_key_guards,
        insert_admission
      )
      |> with_host_fields(operation)
    )
    |> Command.new()
  end

  defp validate_storage_assignments(
         %Operation{type: :upsert},
         contract,
         assignments,
         command,
         opts
       ) do
    if RuleValidation.requires_record_state?(:upsert, contract) do
      RuleValidation.validate_upsert_candidate(contract, assignments, command, opts)
    else
      with {:ok, assignments} <-
             RuleValidation.validate_storage_candidate(:upsert, contract, assignments, opts),
           do: {:ok, assignments, nil}
    end
  end

  defp validate_storage_assignments(operation, contract, assignments, _command, opts) do
    with {:ok, assignments} <-
           RuleValidation.validate_storage_candidate(operation.type, contract, assignments, opts),
         do: {:ok, assignments, nil}
  end

  defp finalize_storage_assignments(%Operation{type: :upsert}, contract, command, proof, opts)
       when not is_nil(proof),
       do: RuleValidation.finalize_upsert_candidate(contract, command, proof, opts)

  defp finalize_storage_assignments(operation, contract, command, nil, opts) do
    with :ok <-
           RuleValidation.reject_pending_obligations(
             operation.type,
             contract,
             command.assignments,
             opts
           ),
         do: {:ok, command}
  end

  defp normalize_input_operation(%Operation{type: type} = operation, contract)
       when type in [:insert, :upsert, :update] do
    field = if type == :update, do: :changes, else: :attrs

    case Map.fetch!(operation, field) do
      values when is_map(values) ->
        values = Map.new(values, fn {key, value} -> {key, Mutation.input(value)} end)

        with {:ok, normalized} <- RuleValidation.validate_input(type, contract, values) do
          normalized =
            Map.new(values, fn {key, value} ->
              {key, Map.get(normalized, to_string(key), value)}
            end)

          {:ok, Map.put(operation, field, normalized)}
        end

      _ ->
        {:ok, operation}
    end
  end

  defp normalize_input_operation(%Operation{} = operation, contract) do
    with {:ok, _} <- RuleValidation.validate_input(operation.type, contract, %{}) do
      {:ok, operation}
    end
  end

  defp normalized_write_once_predicate(
         %Operation{type: :update} = operation,
         contract,
         assignments,
         predicate
       ) do
    changes = Map.new(assignments, &{&1.field, &1.value})

    existing = write_once_guards(operation, contract)

    case write_once_guards(%{operation | changes: changes}, contract) -- existing do
      [] -> predicate
      guards -> {:and, [predicate | guards]}
    end
  end

  defp normalized_write_once_predicate(_operation, _contract, _assignments, predicate),
    do: predicate

  defp normalized_assignment_policy(operation, contract, assignments, context) do
    values =
      Map.new(assignments, fn %{field: field, value: value} ->
        {field, Mutation.input_value(value)}
      end)

    type = if operation.type == :upsert, do: :insert, else: operation.type

    with :ok <- validate_required_fields(values, type, contract),
         {:ok, validated} <- assignment_list(values, type, operation, contract, context) do
      by_field = Map.new(validated, &{to_string(&1.field), &1})
      {:ok, Enum.map(assignments, &Map.fetch!(by_field, to_string(&1.field)))}
    end
  end

  defp validate_values_foreign_keys(domain, assignments, relation) do
    {foreign_keys, _errors} = Selecto.Domain.Values.foreign_keys(domain)

    Enum.reduce_while(assignments, :ok, fn %{field: field, value: assignment}, _acc ->
      case {Map.get(foreign_keys, field_id(field)), assignment} do
        {nil, _} ->
          {:cont, :ok}

        {_spec, {:literal, nil}} ->
          {:cont, :ok}

        {spec, {:literal, value}} ->
          allowed = Enum.map(spec.options, & &1.value)

          if Enum.any?(allowed, &(to_string(&1) == to_string(value))) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              Error.new(:validation, "field must reference an available values relation entry",
                details: %{
                  code: :write_foreign_key_violation,
                  field: field_id(field),
                  relation: relation,
                  association: spec.association,
                  value: value,
                  allowed_values: allowed
                }
              )}}
          end

        {_spec, _expression} ->
          {:cont, :ok}
      end
    end)
  end

  defp record_state_options(
         %Operation{type: operation} = updato_operation,
         contract,
         relation,
         predicate,
         assignments,
         context,
         opts
       )
       when operation == :update do
    if RuleValidation.requires_record_state?(operation, contract) do
      with {:ok, predicate} <- record_state_predicate(updato_operation, predicate, assignments) do
        request = %RecordRequest{
          operation: operation,
          relation: relation,
          predicate: predicate,
          context: context,
          ownership: Keyword.get(opts, :record_state_ownership),
          fields:
            portable_field_types(contract) |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
        }

        {:ok,
         [
           record_state_provider: Keyword.get(opts, :record_state_provider),
           record_state_request: request,
           require_protected_record_state:
             Keyword.get(opts, :require_protected_record_state, false)
         ]}
      end
    else
      {:ok, [require_protected_record_state: false]}
    end
  end

  defp record_state_options(
         operation,
         contract,
         _relation,
         _predicate,
         _assignments,
         _context,
         opts
       ) do
    {:ok,
     [
       require_protected_record_state:
         Keyword.get(opts, :require_protected_record_state, false) and
           RuleValidation.requires_record_state?(operation.type, contract)
     ]}
  end

  defp record_state_predicate(%Operation{type: :update}, predicate, _assignments),
    do: {:ok, predicate}

  defp compile_contract(domain) do
    case WriteContract.compile(domain) do
      {:ok, contract} -> {:ok, contract}
      {:error, error} -> {:error, Error.new(error.type, error.message, details: error.details)}
    end
  end

  # Every operation but a delete assigns fields, so it needs the domain's
  # writes.fields grants; there is no permissive fallback.
  defp ensure_write_policy(contract, operation) do
    case WriteContract.require_write_policy(contract, operation) do
      :ok -> :ok
      {:error, error} -> {:error, Error.new(error.type, error.message, details: error.details)}
    end
  end

  defp ensure_supported_operation(contract, operation)
       when operation in [:insert, :update, :delete, :upsert] do
    if WriteContract.operation_enabled?(contract, operation) do
      :ok
    else
      {:error,
       Error.new(
         :write_operation_not_enabled,
         "operation is not enabled by the domain write contract",
         details: %{operation: operation}
       )}
    end
  end

  defp ensure_supported_operation(_contract, operation) do
    {:error,
     Error.new(
       :unsupported_operation,
       "portable write adapters do not yet support this operation",
       details: %{operation: operation}
     )}
  end

  defp validate_action_authorization(%Operation{action_policy: nil}, _context, _opts), do: :ok

  defp validate_action_authorization(
         %Operation{action_policy: policy, type: operation},
         context,
         opts
       )
       when is_map(policy) do
    authorization = map_value(context, :action_authorization)
    expected_action = map_value(policy, :action)
    expected_capability = map_value(policy, :capability)
    expected_operation = map_value(policy, :operation)
    expected_grant = map_value(policy, :authorization_grant)
    execution_phase = Keyword.get(opts, :action_phase)

    cond do
      not is_map(authorization) ->
        action_authorization_error(
          :missing_action_authorization,
          "Planned action builders require authorization from ActionExecutionAdapter",
          policy
        )

      is_nil(expected_grant) or map_value(authorization, :authorization_grant) != expected_grant ->
        action_authorization_error(
          :action_authorization_mismatch,
          "Planned action authorization does not match this builder",
          policy
        )

      normalize_status(map_value(authorization, :status)) != :enabled ->
        action_authorization_error(
          :action_authorization_denied,
          "Planned action authorization is not enabled",
          policy
        )

      not same_identifier?(map_value(authorization, :action), expected_action) ->
        action_authorization_error(
          :action_authorization_mismatch,
          "Planned action authorization does not match the builder action",
          policy
        )

      not same_identifier?(map_value(authorization, :capability), expected_capability) ->
        action_authorization_error(
          :action_authorization_mismatch,
          "Planned action authorization does not match the builder capability",
          policy
        )

      execution_phase not in [:preview, :execute] ->
        action_authorization_error(
          :missing_action_execution_phase,
          "Planned action builders require an authorized execution phase",
          policy
        )

      normalize_phase(map_value(authorization, :phase)) not in [:preview, :execute] ->
        action_authorization_error(
          :invalid_action_authorization_phase,
          "Planned action authorization must name an execution phase",
          policy
        )

      execution_phase in [:preview, :execute] and
          normalize_phase(map_value(authorization, :phase)) != execution_phase ->
        action_authorization_error(
          :action_authorization_phase_mismatch,
          "Planned action authorization cannot be reused for another phase",
          policy
        )

      expected_operation != operation ->
        action_authorization_error(
          :action_operation_mismatch,
          "Planned action builder operation no longer matches domain policy",
          policy
        )

      true ->
        validate_capability_decision(context, expected_capability, policy)
    end
  end

  defp validate_capability_decision(_context, nil, _policy), do: :ok

  defp validate_capability_decision(context, capability, policy) do
    decision = map_value(context, :capability_decision)

    if is_map(decision) and normalize_status(map_value(decision, :status)) == :enabled and
         same_identifier?(map_value(decision, :capability), capability) do
      :ok
    else
      action_authorization_error(
        :action_capability_evidence_mismatch,
        "Planned action capability evidence is missing or does not match",
        policy
      )
    end
  end

  defp action_authorization_error(code, message, policy) do
    {:error,
     Error.new(:authorization, message,
       details: %{
         code: code,
         action: map_value(policy, :action),
         capability: map_value(policy, :capability)
       }
     )}
  end

  defp validate_authorization_context(%Operation{action_policy: nil}, _context, _opts), do: :ok

  defp validate_authorization_context(%Operation{} = operation, context, opts) do
    case ActionAuthorization.authorization_context(context, opts) do
      {:ok, _authorization_context} -> :ok
      {:error, error} -> reject_ambiguous_authorization_context(operation, error)
    end
  end

  defp consume_action_authorization(%Operation{action_policy: nil}, _context, _opts), do: :ok

  defp consume_action_authorization(%Operation{} = operation, context, opts) do
    policy = operation.action_policy
    grant = map_value(policy, :authorization_grant)

    evidence = %{
      action: map_value(policy, :action),
      capability: map_value(policy, :capability),
      operation: operation.type,
      operation_fingerprint: ActionAuthorization.operation_fingerprint(operation),
      phase: Keyword.fetch!(opts, :action_phase)
    }

    case ActionAuthorization.authorization_context(context, opts) do
      {:ok, authorization_context} ->
        ActionAuthorization.consume(
          grant,
          Map.put(evidence, :authorization_context, authorization_context)
        )

      {:error, {:validation_error, message, details}} ->
        reject_ambiguous_authorization_context(
          operation,
          {:validation_error, message, details},
          evidence
        )
    end
  end

  defp reject_ambiguous_authorization_context(
         operation,
         {:validation_error, message, details},
         evidence \\ %{}
       ) do
    grant = map_value(operation.action_policy, :authorization_grant)

    _ =
      ActionAuthorization.consume(
        grant,
        Map.put(evidence, :authorization_context, {:invalid, details})
      )

    {:error, Error.new(:authorization, message, details: details)}
  end

  defp validate_operation_identifiers(%Operation{} = operation, contract) do
    with :ok <- validate_assignment_identifiers(operation),
         :ok <- validate_filter_identifiers(operation.filters || [], contract),
         :ok <- validate_returning_identifiers(operation.returning, contract) do
      :ok
    end
  end

  defp validate_assignment_identifiers(%Operation{} = operation) do
    case operation.attrs || operation.changes do
      values when is_map(values) ->
        validate_unique_identifiers(Map.keys(values), :assignment)

      _other ->
        :ok
    end
  end

  defp validate_filter_identifiers(filters, contract) when is_list(filters) do
    fields =
      Enum.flat_map(filters, fn
        {field, _value} when is_atom(field) or is_binary(field) -> [field]
        {field, _comparator, _value} when is_atom(field) or is_binary(field) -> [field]
        _filter -> []
      end)

    with :ok <- validate_unique_identifiers(fields, :filter),
         :ok <- validate_declared_fields(fields, contract, :filter) do
      :ok
    end
  end

  defp validate_returning_identifiers(fields, contract) when is_list(fields) do
    with :ok <- validate_unique_identifiers(fields, :returning),
         :ok <- validate_declared_fields(fields, contract, :returning) do
      :ok
    end
  end

  defp validate_returning_identifiers(_returning, _contract), do: :ok

  defp validate_unique_identifiers(fields, :filter) do
    duplicates =
      fields
      |> Enum.filter(&(is_atom(&1) or is_binary(&1)))
      |> Enum.group_by(&field_id/1)
      |> Enum.flat_map(fn {field, representations} ->
        representation_types =
          Enum.map(representations, &identifier_representation/1) |> Enum.uniq()

        if length(representation_types) > 1, do: [field], else: []
      end)
      |> Enum.sort()

    duplicate_identifier_result(duplicates, :filter)
  end

  defp validate_unique_identifiers(fields, kind) do
    duplicates =
      fields
      |> Enum.filter(&(is_atom(&1) or is_binary(&1)))
      |> Enum.map(&field_id/1)
      |> Enum.frequencies()
      |> Enum.flat_map(fn
        {field, count} when count > 1 -> [field]
        _entry -> []
      end)
      |> Enum.sort()

    duplicate_identifier_result(duplicates, kind)
  end

  defp duplicate_identifier_result(duplicates, kind) do
    case duplicates do
      [] ->
        :ok

      fields ->
        {:error,
         Error.new(:invalid_operation, "Normalized write identifiers must be unique",
           details: %{
             code: duplicate_identifier_code(kind),
             identifier_kind: kind,
             fields: fields
           }
         )}
    end
  end

  defp identifier_representation(field) when is_atom(field), do: :atom
  defp identifier_representation(field) when is_binary(field), do: :string

  defp duplicate_identifier_code(:assignment), do: :duplicate_assignment_identifier
  defp duplicate_identifier_code(:filter), do: :duplicate_filter_identifier
  defp duplicate_identifier_code(:returning), do: :duplicate_returning_identifier

  defp validate_declared_fields(fields, contract, surface) do
    declared = contract.source |> Core.relation_fields() |> MapSet.new()

    unknown =
      fields
      |> Enum.filter(&(is_atom(&1) or is_binary(&1)))
      |> Enum.map(&field_id/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(declared, &1))
      |> Enum.sort()

    case unknown do
      [] ->
        :ok

      fields ->
        {:error,
         Error.new(:unknown_field, "Write identifiers must reference declared source fields",
           details: %{
             code: :undeclared_write_identifier,
             identifier_kind: surface,
             fields: fields,
             allowed_fields: declared |> MapSet.to_list() |> Enum.sort()
           }
         )}
    end
  end

  defp validate_tenant_conflicts(%Operation{} = operation, contract, context) do
    case Tenant.context_conflict(operation) do
      nil ->
        validate_tenant_values(operation, contract, context)

      conflict ->
        {:error,
         Error.new(:tenant_mismatch, "Trusted tenant sources do not agree",
           details: %{
             code: :conflicting_trusted_tenant_context,
             conflict: conflict
           }
         )}
    end
  end

  defp validate_tenant_values(
         %Operation{} = operation,
         %{scope: %{tenant: %{field: field}}},
         context
       ) do
    case context[:tenant_id] do
      nil ->
        :ok

      tenant_id ->
        with :ok <- verify_tenant_filters(operation.filters || [], field, tenant_id),
             :ok <- verify_tenant_assignment(operation, field, tenant_id) do
          :ok
        end
    end
  end

  defp validate_tenant_values(%Operation{}, _contract, _context), do: :ok

  # Insert and upsert values, and update changes, may name the tenant field only
  # with the trusted tenant. An update that sets another tenant would move a
  # scoped row into that tenant even though its predicate is tenant-bound.
  defp verify_tenant_assignment(%Operation{type: type} = operation, field, tenant_id)
       when type in [:insert, :upsert, :update] do
    values = if type == :update, do: operation.changes, else: operation.attrs

    if Enum.all?(values || %{}, &trusted_tenant_value?(&1, field, tenant_id)),
      do: :ok,
      else: tenant_mismatch(field)
  end

  defp verify_tenant_assignment(%Operation{}, _field, _tenant_id), do: :ok

  defp trusted_tenant_value?({key, value}, field, tenant_id)
       when is_atom(key) or is_binary(key) do
    not tenant_field?(key, field) or match?(^tenant_id, value)
  end

  defp trusted_tenant_value?(_entry, _field, _tenant_id), do: true

  # An upsert has no mutation predicate: its conflict branch updates whichever
  # row owns the conflicting key. A caller or host filter on an upsert would
  # therefore be silently ignored, so only the trusted tenant filter (which the
  # tenant assignment and tenant-bearing conflict target already enforce) may
  # accompany one. Any other filter refuses the upsert, as a required predicate
  # does (specification 2.20.0).
  defp validate_upsert_filters(%Operation{type: :upsert} = operation, contract, context) do
    tenant_field = contract.scope |> Map.get(:tenant, %{}) |> Map.get(:field)
    tenant_id = context[:tenant_id]

    unenforced =
      Enum.reject(operation.filters || [], fn
        {field, value} ->
          trusted_tenant_filter?(field, value, tenant_field, tenant_id)

        {field, comparator, value} when comparator in [:eq, "eq", "="] ->
          trusted_tenant_filter?(field, value, tenant_field, tenant_id)

        _filter ->
          false
      end)

    case unenforced do
      [] ->
        :ok

      filters ->
        {:error,
         Error.new(
           :query_enforcement,
           "upsert cannot enforce write filters because its conflict branch can update a row outside them",
           details: %{
             code: :query_enforcement_unsupported_operation,
             operation: :upsert,
             fields: filters |> Enum.flat_map(&filter_field/1) |> Enum.uniq() |> Enum.sort()
           }
         )}
    end
  end

  defp validate_upsert_filters(%Operation{}, _contract, _context), do: :ok

  # An upsert's conflict branch updates whichever row owns the conflicting
  # key, so under a bound tenant (lesson 47) the conflict target must include
  # the bound tenant column; otherwise another tenant's row could be updated.
  defp validate_upsert_tenant_target(
         %Operation{type: :upsert} = operation,
         %{scope: %{tenant: %{field: field}}},
         context
       ) do
    target = List.wrap(operation.conflict_target)

    cond do
      is_nil(context[:tenant_id]) ->
        :ok

      Enum.any?(target, &tenant_field?(&1, field)) ->
        :ok

      true ->
        {:error,
         Error.new(
           :invalid_operation,
           "Tenant-scoped upsert conflict targets must include the tenant field",
           details: %{
             code: :tenant_conflict_target_missing,
             tenant_field: field,
             conflict_target: target
           }
         )}
    end
  end

  defp validate_upsert_tenant_target(%Operation{}, _contract, _context), do: :ok

  defp trusted_tenant_filter?(_field, _value, nil, _tenant_id), do: false
  defp trusted_tenant_filter?(_field, _value, _tenant_field, nil), do: false

  defp trusted_tenant_filter?(field, value, tenant_field, tenant_id)
       when is_atom(field) or is_binary(field),
       do: tenant_field?(field, tenant_field) and match?(^tenant_id, value)

  defp trusted_tenant_filter?(_field, _value, _tenant_field, _tenant_id), do: false

  defp filter_field({field, _value}) when is_atom(field) or is_binary(field),
    do: [field_id(field)]

  defp filter_field({field, _comparator, _value}) when is_atom(field) or is_binary(field),
    do: [field_id(field)]

  defp filter_field(_filter), do: []

  defp tenant_mismatch(field) do
    {:error,
     Error.new(:tenant_mismatch, "tenant value must match trusted tenant context",
       details: %{field: field}
     )}
  end

  defp resolve_expected_cardinality(%Operation{} = operation, contract) do
    operation_spec = Map.fetch!(contract.operations, operation.type)

    domain_expected =
      if not is_nil(operation.expected_cardinality) and
           map_value(operation_spec, :bulk) == true and
           not Core.has_key?(operation_spec, :expected_cardinality),
         do: :many,
         else: expected_cardinality(contract, operation.type)

    with {:ok, domain_expected} <-
           normalize_cardinality(domain_expected) do
      case operation.action_policy do
        nil ->
          resolve_caller_cardinality(operation.expected_cardinality, domain_expected)

        policy when is_map(policy) ->
          resolve_action_cardinality(operation, contract, policy, domain_expected)
      end
    end
  end

  defp resolve_caller_cardinality(nil, domain_expected), do: {:ok, domain_expected}

  defp resolve_caller_cardinality(requested, domain_expected) do
    with {:ok, requested} <- normalize_cardinality(requested) do
      if cardinality_subset?(requested, domain_expected) do
        {:ok, requested}
      else
        {:error,
         Error.new(:invalid_operation, "Caller cardinality cannot weaken domain policy",
           details: %{
             code: :expected_cardinality_policy_violation,
             domain_expected_cardinality: domain_expected,
             requested_expected_cardinality: requested
           }
         )}
      end
    end
  end

  defp resolve_action_cardinality(operation, contract, policy, domain_expected) do
    policy_expected = map_value(policy, :expected_cardinality)

    with :ok <-
           ensure_action_policy_value(
             operation.expected_cardinality,
             policy_expected,
             :cardinality
           ),
         {:ok, resolved} <-
           normalize_cardinality(
             if(is_nil(policy_expected), do: domain_expected, else: policy_expected)
           ),
         :ok <- validate_concrete_action_cardinality(operation, contract, policy_expected) do
      {:ok, resolved}
    end
  end

  defp validate_concrete_action_cardinality(_operation, _contract, nil), do: :ok

  # A create/upsert action submits one candidate. Its actual affected count is
  # checked atomically by the write adapter; a primary-key filter is neither
  # required nor the identity of an alternate-key conflict branch.
  defp validate_concrete_action_cardinality(%Operation{type: type}, _contract, {:exactly, 1})
       when type in [:insert, :upsert], do: :ok

  defp validate_concrete_action_cardinality(
         operation,
         contract,
         {:exactly, expected_count}
       ) do
    operation_spec = Map.fetch!(contract.operations, operation.type)

    concrete_target_count = concrete_primary_key_target_count(operation, contract)
    bulk? = map_value(operation_spec, :bulk) == true

    if concrete_target_count == expected_count and (expected_count == 1 or bulk?) do
      :ok
    else
      {:error,
       Error.new(:invalid_operation, "Action cardinality must match a concrete bulk target",
         details: %{
           code: :action_cardinality_target_mismatch,
           expected_cardinality: {:exactly, expected_count}
         }
       )}
    end
  end

  defp validate_concrete_action_cardinality(_operation, _contract, _expected) do
    {:error,
     Error.new(:invalid_operation, "Action cardinality must be derived from a concrete target",
       details: %{code: :invalid_action_cardinality}
     )}
  end

  defp concrete_primary_key_target_count(operation, contract) do
    primary_key =
      map_value(contract.source, :primary_key)
      |> Kernel.||(:id)
      |> field_id()

    Enum.find_value(operation.filters || [], fn
      {field, comparator, values}
      when comparator in [:in, "in"] and is_list(values) and values != [] ->
        if field_id(field) == primary_key and length(Enum.uniq(values)) == length(values),
          do: length(values)

      {field, _value} ->
        if field_id(field) == primary_key, do: 1

      _filter ->
        nil
    end)
  end

  defp normalize_cardinality("many"), do: {:ok, :many}
  defp normalize_cardinality(:many), do: {:ok, :many}

  defp normalize_cardinality({:exactly, value} = cardinality)
       when is_integer(value) and value > 0,
       do: {:ok, cardinality}

  defp normalize_cardinality({:at_most, value} = cardinality)
       when is_integer(value) and value >= 0,
       do: {:ok, cardinality}

  defp normalize_cardinality({:at_least, value} = cardinality)
       when is_integer(value) and value >= 0,
       do: {:ok, cardinality}

  defp normalize_cardinality({:between, minimum, maximum} = cardinality)
       when is_integer(minimum) and is_integer(maximum) and minimum >= 0 and maximum >= minimum,
       do: {:ok, cardinality}

  defp normalize_cardinality(value) do
    {:error,
     Error.new(:invalid_operation, "Invalid expected cardinality",
       details: %{code: :invalid_expected_cardinality, expected_cardinality: value}
     )}
  end

  defp cardinality_subset?(requested, domain) do
    {requested_min, requested_max} = cardinality_bounds(requested)
    {domain_min, domain_max} = cardinality_bounds(domain)

    requested_min >= domain_min and upper_bound_at_most?(requested_max, domain_max)
  end

  defp cardinality_bounds(:many), do: {0, :infinity}
  defp cardinality_bounds({:exactly, value}), do: {value, value}
  defp cardinality_bounds({:at_most, value}), do: {0, value}
  defp cardinality_bounds({:at_least, value}), do: {value, :infinity}
  defp cardinality_bounds({:between, minimum, maximum}), do: {minimum, maximum}

  defp upper_bound_at_most?(_requested, :infinity), do: true
  defp upper_bound_at_most?(:infinity, _domain), do: false
  defp upper_bound_at_most?(requested, domain), do: requested <= domain

  defp resolve_returning(%Operation{} = operation, contract) do
    operation_spec = Map.fetch!(contract.operations, operation.type)

    with {:ok, domain_returning} <- normalize_returning(map_value(operation_spec, :returning)) do
      case operation.action_policy do
        nil ->
          ceiling =
            if is_list(operation.returning) and not Core.has_key?(operation_spec, :returning),
              do: :all,
              else: domain_returning

          resolve_caller_returning(operation.returning, ceiling, contract)

        policy when is_map(policy) ->
          resolve_action_returning(operation, policy, contract)
      end
    end
  end

  defp resolve_caller_returning(nil, domain_returning, contract) do
    with :ok <- validate_resolved_returning_fields(domain_returning, contract),
         do: {:ok, domain_returning}
  end

  defp resolve_caller_returning(requested, domain_returning, contract) do
    with {:ok, requested} <- normalize_returning(requested),
         true <- returning_subset?(requested, domain_returning),
         :ok <- validate_resolved_returning_fields(requested, contract) do
      {:ok, requested}
    else
      false ->
        {:error,
         Error.new(:invalid_operation, "Caller returning policy exceeds domain policy",
           details: %{
             code: :returning_policy_violation,
             domain_returning: domain_returning,
             requested_returning: requested
           }
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp resolve_action_returning(operation, policy, contract) do
    policy_returning = map_value(policy, :returning)

    with {:ok, policy_returning} <- normalize_returning(policy_returning),
         {:ok, current_returning} <- normalize_returning(operation.returning),
         :ok <- ensure_action_policy_value(current_returning, policy_returning, :returning),
         :ok <- validate_resolved_returning_fields(policy_returning, contract) do
      {:ok, policy_returning}
    end
  end

  defp normalize_returning(value)
       when value in [nil, false, :minimal, "minimal", :count, "count", :none, "none"],
       do: {:ok, :none}

  defp normalize_returning(value)
       when value in [true, :all, "all", :record, "record", :records, "records"],
       do: {:ok, :all}

  defp normalize_returning(fields) when is_list(fields) do
    if Enum.all?(fields, &(is_atom(&1) or is_binary(&1))) do
      {:ok, Enum.map(fields, &field_id/1)}
    else
      invalid_returning(fields)
    end
  end

  defp normalize_returning(value), do: invalid_returning(value)

  defp invalid_returning(value) do
    {:error,
     Error.new(:invalid_operation, "Invalid returning policy",
       details: %{code: :invalid_returning_policy, returning: value}
     )}
  end

  defp returning_subset?(:none, _domain), do: true
  defp returning_subset?(_requested, :none), do: false
  defp returning_subset?(_requested, :all), do: true
  defp returning_subset?(:all, _domain), do: false

  defp returning_subset?(requested, domain) when is_list(requested) and is_list(domain) do
    MapSet.subset?(MapSet.new(requested), MapSet.new(domain))
  end

  defp returning_subset?(_requested, _domain), do: false

  defp validate_resolved_returning_fields(fields, contract) when is_list(fields),
    do: validate_declared_fields(fields, contract, :returning)

  defp validate_resolved_returning_fields(_returning, _contract), do: :ok

  defp ensure_action_policy_value(actual, expected, _kind) when actual == expected, do: :ok

  defp ensure_action_policy_value(actual, expected, kind) do
    {:error,
     Error.new(:invalid_operation, "Planned action builder policy was modified",
       details: %{
         code: :action_policy_mismatch,
         policy_kind: kind,
         expected: expected,
         actual: actual
       }
     )}
  end

  defp normalize_status("enabled"), do: :enabled
  defp normalize_status(status), do: status
  defp normalize_phase("preview"), do: :preview
  defp normalize_phase("execute"), do: :execute
  defp normalize_phase(phase), do: phase

  defp same_identifier?(nil, nil), do: true

  defp same_identifier?(left, right)
       when (is_atom(left) or is_binary(left)) and (is_atom(right) or is_binary(right)),
       do: to_string(left) == to_string(right)

  defp same_identifier?(left, right), do: left == right

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_value(_map, _key), do: nil

  defp validate_choice_membership(%Operation{} = operation, command, nil, context) do
    record = choice_record(operation)
    names = choice_field_names(operation, record)

    attrs =
      Map.new(command.assignments, fn assignment ->
        {Map.get(names, assignment.field, assignment.field),
         Mutation.input_value(assignment.value)}
      end)

    ChoiceMembership.validate(operation, attrs, record, context)
  end

  defp validate_choice_membership(%Operation{} = operation, command, proof, context) do
    record = choice_record(operation)
    names = choice_field_names(operation, record)
    known = MapSet.new(Map.keys(proof.request.field_types), &to_string/1)

    # A conflict branch must not let ignored INSERT attributes replace stored
    # fields in a resolver's dependent record. The final projection proved this
    # exact canonical candidate, including every requested choice dependency.
    record =
      record
      |> Enum.reject(fn {key, _value} ->
        (is_atom(key) or is_binary(key)) and MapSet.member?(known, to_string(key))
      end)
      |> Map.new()
      |> Map.merge(
        Map.new(proof.normalized, fn {field, value} ->
          {Map.get(names, field, field), value}
        end)
      )

    persisted =
      if proof.state.branch == :conflict,
        do: MapSet.new(command.metadata.upsert_update_fields, &to_string/1),
        else: MapSet.new(command.assignments, &to_string(&1.field))

    attrs =
      command.assignments
      |> Enum.filter(&MapSet.member?(persisted, to_string(&1.field)))
      |> Map.new(fn assignment ->
        field = to_string(assignment.field)
        {Map.get(names, field, field), Map.fetch!(proof.normalized, field)}
      end)

    ChoiceMembership.validate(operation, attrs, record, context)
  end

  defp choice_record(operation) do
    case Keyword.get(operation.opts || [], :choice_source_record) || filter_record(operation) do
      record when is_struct(record) -> Map.from_struct(record)
      record when is_map(record) -> record
      _ -> %{}
    end
  end

  defp choice_field_names(operation, record) do
    source = map_value(operation.domain, :source) || %{}
    columns = map_value(source, :columns) || %{}
    attrs = operation.attrs || operation.changes || %{}

    [Map.keys(columns), Map.keys(record), Map.keys(attrs)]
    |> List.flatten()
    |> Enum.filter(&(is_atom(&1) or is_binary(&1)))
    |> Map.new(&{to_string(&1), &1})
  end

  defp choice_candidate?(operation) do
    source = map_value(operation.domain, :source) || %{}

    [map_value(source, :columns), map_value(operation.domain, :columns)]
    |> Enum.filter(&is_map/1)
    |> Enum.any?(fn columns ->
      Enum.any?(columns, fn {_field, column} ->
        reference = map_value(column, :reference)

        Enum.any?([map_value(column, :choice_source), map_value(reference, :choice_source)], fn
          value when is_atom(value) -> not is_nil(value)
          value when is_binary(value) -> value != ""
          _ -> false
        end)
      end)
    end)
  end

  defp filter_record(%Operation{filters: filters}) when is_list(filters) do
    filters
    |> Enum.reduce(%{}, fn
      {field, value}, record when is_atom(field) or is_binary(field) ->
        Map.put(record, field, value)

      {field, comparator, value}, record
      when (is_atom(field) or is_binary(field)) and comparator in [:eq, "eq", "="] ->
        Map.put(record, field, value)

      _filter, record ->
        record
    end)
  end

  defp relation(%{source: source}) when is_map(source) do
    relation = SelectoUpdato.WriteContract.relation_name(source)

    cond do
      not SelectoUpdato.WriteContract.relation_valid?(source) ->
        {:error,
         Error.new(
           :invalid_domain,
           "a write domain's source_table must be a bare name; declare its schema with source_schema",
           details: %{relation: to_string(relation)}
         )}

      is_atom(relation) or (is_binary(relation) and String.trim(relation) != "") ->
        {:ok, relation}

      true ->
        {:error,
         Error.new(:invalid_domain, "write domain source must declare source_table or table")}
    end
  end

  defp assignments(%Operation{type: :insert, attrs: attrs} = operation, contract, context)
       when is_map(attrs),
       do: assignment_list(attrs, :insert, operation, contract, context)

  defp assignments(%Operation{type: :update, changes: changes} = operation, contract, context)
       when is_map(changes),
       do: assignment_list(changes, :update, operation, contract, context)

  defp assignments(%Operation{type: :upsert, attrs: attrs} = operation, contract, context)
       when is_map(attrs),
       do: assignment_list(attrs, :insert, operation, contract, context)

  defp assignments(%Operation{type: :delete}, _contract, _context), do: {:ok, []}

  defp assignments(%Operation{type: type}, _contract, _context) do
    {:error,
     Error.new(:invalid_operation, "operation requires a map of write values",
       details: %{operation: type}
     )}
  end

  defp assignment_list(values, operation, updato_operation, contract, context) do
    tenant = contract.scope[:tenant]
    tenant_field = tenant && tenant[:field]

    with :ok <- validate_input_required_fields(values, operation, contract, context) do
      values
      |> Enum.reduce_while({:ok, []}, fn {field, value}, {:ok, assignments} ->
        field_id = field_id(field)

        value =
          if Mutation.expression?(value),
            do: value,
            else: Domain.normalize_field_value(updato_operation.domain, field_id, value)

        if operation == :insert and
             (tenant_field?(field_id, tenant_field) or
                governed_fill?(contract, updato_operation, field_id, value, context)) do
          case Mutation.assignment(value, operation, contract, field_id) do
            {:ok, value} -> {:cont, {:ok, [%{field: field_id, value: value} | assignments]}}
            error -> {:halt, error}
          end
        else
          case field_write_denial(contract, operation, field_id) do
            nil ->
              case Mutation.assignment(value, operation, contract, field_id) do
                {:ok, value} -> {:cont, {:ok, [%{field: field_id, value: value} | assignments]}}
                error -> {:halt, error}
              end

            :unknown ->
              {:halt,
               {:error,
                Error.new(:unknown_field, "field is not declared on the write source",
                  details: %{field: field, operation: operation}
                )}}

            reason ->
              {:halt,
               {:error,
                Error.new(:write_field_not_writable, "field is not writable for this operation",
                  details: %{field: field, operation: operation, reason: reason}
                )}}
          end
        end
      end)
      |> case do
        {:ok, assignments} ->
          assignments = Enum.reverse(assignments)

          case {operation, tenant_field, context[:tenant_id]} do
            {:insert, field, tenant_id} when not is_nil(field) and not is_nil(tenant_id) ->
              ensure_tenant_assignment(assignments, field, tenant_id)

            {:update, field, tenant_id} when not is_nil(field) and not is_nil(tenant_id) ->
              ensure_update_tenant_assignment(assignments, field, tenant_id)

            {:insert, field, _tenant_id} when not is_nil(field) ->
              {:error,
               Error.new(:missing_tenant_scope, "insert requires trusted tenant context",
                 details: %{field: field}
               )}

            _ ->
              {:ok, assignments}
          end

        error ->
          error
      end
    end
  end

  # These trusted values are materialized by the ordinary assignment pipeline.
  # Validate caller-required fields first without treating governed autofill as
  # an omission; the final assigned values are checked again after materialization.
  defp validate_input_required_fields(values, :insert, contract, context) do
    known = Map.new(values, fn {field, value} -> {field_id(field), value} end)
    tenant = contract.scope[:tenant]

    known =
      if tenant && not is_nil(context[:tenant_id]),
        do: Map.put_new(known, field_id(tenant[:field]), context[:tenant_id]),
        else: known

    known =
      Enum.reduce(WriteContract.foreign_keys(contract), known, fn {field, spec}, acc ->
        case foreign_key_source(spec) do
          {:context, key} ->
            case Map.fetch(context, key) do
              {:ok, value} -> Map.put_new(acc, field_id(field), value)
              :error -> acc
            end

          :input ->
            acc
        end
      end)

    validate_required_fields(known, :insert, contract)
  end

  defp validate_input_required_fields(_values, _operation, _contract, _context), do: :ok

  defp required_assignment_fields(assignments, type, contract) do
    values =
      Map.new(assignments, fn %{field: field, value: value} ->
        {field, Mutation.input_value(value)}
      end)

    validate_required_fields(values, if(type == :upsert, do: :insert, else: type), contract)
  end

  defp validate_required_fields(values, :insert, contract) when is_map(values) do
    present_fields = values |> Map.keys() |> Enum.map(&field_id/1) |> MapSet.new()

    missing =
      contract.fields
      |> Enum.filter(fn {_field, spec} ->
        required_on = List.wrap(spec_value(spec, :required_on))
        spec_value(spec, :required) == true or :insert in required_on or "insert" in required_on
      end)
      |> Enum.map(fn {field, _spec} -> field end)
      |> Enum.reject(fn field ->
        MapSet.member?(present_fields, field) and
          present_required_value?(value_for_field(values, field))
      end)

    case missing do
      [] ->
        :ok

      fields ->
        {:error,
         Error.new(:validation, "required write fields are missing",
           details: %{
             code: :missing_required_write_fields,
             errors: Enum.map(fields, &{[&1], "is required"}),
             fields: fields
           }
         )}
    end
  end

  defp validate_required_fields(_values, _operation, _contract), do: :ok

  defp present_required_value?(%Mutation{node: {:literal, value}}),
    do: present_required_value?(value)

  defp present_required_value?(%Mutation{}), do: false

  defp present_required_value?(%{"$mutation" => "literal", "value" => value}),
    do: present_required_value?(value)

  defp present_required_value?(%{"$mutation" => _}), do: false
  defp present_required_value?(nil), do: false
  defp present_required_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_required_value?(_value), do: true

  defp value_for_field(values, field) do
    Enum.find_value(values, fn {key, value} -> if field_id(key) == field, do: {:found, value} end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  # The core contract grants a field per operation; Updato additionally fails
  # closed on the flags that forbid caller writes: an immutable field never
  # changes after insert, and a server-managed field is never caller-written.
  defp field_write_denial(contract, operation, field_id) do
    spec = WriteContract.field_spec(contract, field_id) || %{}

    cond do
      field_id not in Core.relation_fields(contract.source) -> :unknown
      not WriteContract.writable?(contract, operation, field_id) -> :not_writable
      spec_value(spec, :server_managed) == true -> :server_managed
      operation == :update and spec_value(spec, :immutable) == true -> :immutable
      true -> nil
    end
  end

  defp ensure_update_tenant_assignment(assignments, field, tenant_id) do
    field = field_id(field)

    if Enum.all?(assignments, fn assignment ->
         field_id(assignment.field) != field or match?({:literal, ^tenant_id}, assignment.value)
       end) do
      {:ok, assignments}
    else
      tenant_mismatch(field)
    end
  end

  defp ensure_tenant_assignment(assignments, field, tenant_id) do
    field = field_id(field)

    case Enum.find(assignments, &(field_id(&1.field) == field)) do
      nil ->
        {:ok, assignments ++ [%{field: field, value: {:literal, tenant_id}}]}

      %{value: {:literal, ^tenant_id}} ->
        {:ok, assignments}

      _ ->
        {:error,
         Error.new(:tenant_mismatch, "insert tenant value must match trusted tenant context",
           details: %{field: field}
         )}
    end
  end

  defp predicate(%Operation{type: :insert}, _contract, _context, _query_predicate),
    do: {:ok, nil}

  defp predicate(%Operation{type: :upsert}, _contract, _context, _query_predicate),
    do: {:ok, nil}

  defp predicate(%Operation{filters: filters} = operation, contract, context, query_predicate)
       when operation.type in [:update, :delete] do
    with {:ok, filters} <- bind_tenant_scope(filters, contract, context),
         {:ok, filters} <- bind_site_pin(filters, contract),
         filters = bind_root_tenant_column(filters, contract, context),
         {:ok, predicates} <- compile_filters(filters) do
      predicates =
        if is_nil(query_predicate), do: predicates, else: predicates ++ [query_predicate]

      if predicates == [] do
        {:error,
         Error.new(
           :missing_predicate,
           "update and delete operations require a domain-governed filter"
         )}
      else
        case predicates ++ write_once_guards(operation, contract) do
          [predicate] -> {:ok, predicate}
          predicates -> {:ok, {:and, predicates}}
        end
      end
    end
  end

  # A write-once field may be set by an update only while it is still null, so
  # the guard is part of the atomic mutation predicate rather than a prior read.
  # A row whose value is already set matches no row and fails the cardinality
  # check instead of being overwritten.
  defp write_once_guards(%Operation{type: :update, changes: changes}, contract)
       when is_map(changes) do
    changes
    |> Map.keys()
    |> Enum.filter(&(is_atom(&1) or is_binary(&1)))
    |> Enum.map(&field_id/1)
    |> Enum.filter(fn field ->
      spec = WriteContract.field_spec(contract, field) || %{}
      spec_value(spec, :write_once) == true
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{:is_null, {:field, &1}})
  end

  defp write_once_guards(%Operation{}, _contract), do: []

  defp bind_tenant_scope(filters, %{scope: %{tenant: %{field: field}}}, context) do
    case context[:tenant_id] do
      nil ->
        {:error,
         Error.new(:missing_tenant_scope, "tenant-scoped writes require trusted tenant context",
           details: %{field: field}
         )}

      tenant_id ->
        with :ok <- verify_tenant_filters(filters, field, tenant_id) do
          # Admitting equality and IN conjuncts are intersected into the bound
          # tenant.
          filters =
            Enum.reject(filters, fn
              {filter_field, _value} -> tenant_field?(filter_field, field)
              {filter_field, _comparator, _value} -> tenant_field?(filter_field, field)
              _filter -> false
            end)

          {:ok, filters ++ [{field, tenant_id}]}
        end
    end
  end

  defp bind_tenant_scope(filters, %{scope: %{}}, _context), do: {:ok, filters}

  defp verify_tenant_filters(filters, field, tenant_id) do
    # Every positive tenant conjunct must admit the trusted tenant: an
    # equality to it, or an IN set containing it (intersected). One that
    # excludes it is a tenant mismatch (lesson 47).
    excluding =
      Enum.find(filters, fn
        {filter_field, {comparator, values}}
        when comparator in [:in, "in"] and is_list(values) ->
          tenant_field?(filter_field, field) and tenant_id not in values

        {filter_field, {comparator, value}} when comparator in [:eq, "eq", :=, "="] ->
          tenant_field?(filter_field, field) and not match?(^tenant_id, value)

        {filter_field, value} ->
          tenant_field?(filter_field, field) and not match?(^tenant_id, value)

        {filter_field, comparator, value} when comparator in [:eq, "eq", "="] ->
          tenant_field?(filter_field, field) and not match?(^tenant_id, value)

        {filter_field, comparator, values} when comparator in [:in, "in"] and is_list(values) ->
          tenant_field?(filter_field, field) and tenant_id not in values

        # Any other comparison on the tenant field cannot be proven to admit
        # the trusted tenant.
        {filter_field, _comparator, _value} ->
          tenant_field?(filter_field, field)

        _filter ->
          false
      end)

    if is_nil(excluding), do: :ok, else: tenant_mismatch(field)
  end

  defp compile_filters(filters) when is_list(filters) do
    filters
    |> Enum.reduce_while({:ok, []}, fn
      # A NULL pin is IS NULL (`= NULL` matches nothing).
      {field, nil}, {:ok, predicates} when is_atom(field) or is_binary(field) ->
        {:cont, {:ok, [{:is_null, {:field, field_id(field)}} | predicates]}}

      # A Selecto operator expression ({:>, v}, {:in, list}, {:not_in, list},
      # {:between, a, b}, "!=", a list, :not_null, ...) is not a governed
      # write filter yet: it refuses typed before any SQL runs (bound as one
      # literal it failed in the driver; compiled, its values would need the
      # read's type coercion, which governed writes do not apply).
      {field, value}, _acc
      when (is_atom(field) or is_binary(field)) and
             (is_tuple(value) or is_list(value) or value in [:not_null, :not_nil]) ->
        {:halt, unsupported_filter_operator(field, value)}

      {field, value}, {:ok, predicates} when is_atom(field) or is_binary(field) ->
        {:cont, {:ok, [{:eq, {:field, field_id(field)}, {:literal, value}} | predicates]}}

      {field, comparator, values}, {:ok, predicates}
      when (is_atom(field) or is_binary(field)) and comparator in [:in, "in"] and
             is_list(values) and values != [] ->
        literals = Enum.map(values, &{:literal, &1})
        {:cont, {:ok, [{:in, {:field, field_id(field)}, literals} | predicates]}}

      {field, comparator, value} = filter, {:ok, predicates}
      when is_atom(field) or is_binary(field) ->
        case compile_comparison_filter(field, comparator, value) do
          {:ok, predicate} -> {:cont, {:ok, [predicate | predicates]}}
          :error -> {:halt, invalid_filter(filter)}
        end

      filter, _acc ->
        {:halt, invalid_filter(filter)}
    end)
    |> case do
      {:ok, predicates} -> {:ok, Enum.reverse(predicates)}
      error -> error
    end
  end

  defp compile_comparison_filter(field, comparator, value) do
    case normalize_comparator(comparator) do
      {:ok, operator} when operator in [:is_null, :not_null] and is_nil(value) ->
        {:ok, {operator, {:field, field_id(field)}}}

      {:ok, operator} when operator in [:is_null, :not_null] ->
        :error

      {:ok, operator} ->
        {:ok, {operator, {:field, field_id(field)}, {:literal, value}}}

      :error ->
        :error
    end
  end

  defp normalize_comparator(value) when value in [:eq, "eq", "="], do: {:ok, :eq}
  defp normalize_comparator(value) when value in [:neq, "neq", "!=", "<>"], do: {:ok, :neq}
  defp normalize_comparator(value) when value in [:gt, "gt", ">"], do: {:ok, :gt}
  defp normalize_comparator(value) when value in [:gte, "gte", ">="], do: {:ok, :gte}
  defp normalize_comparator(value) when value in [:lt, "lt", "<"], do: {:ok, :lt}
  defp normalize_comparator(value) when value in [:lte, "lte", "<="], do: {:ok, :lte}
  defp normalize_comparator(value) when value in [:is_null, "is_null"], do: {:ok, :is_null}
  defp normalize_comparator(value) when value in [:not_null, "not_null"], do: {:ok, :not_null}
  defp normalize_comparator(_value), do: :error

  defp unsupported_filter_operator(field, value) do
    operator =
      cond do
        is_tuple(value) and tuple_size(value) > 0 -> elem(value, 0)
        is_list(value) -> :in
        true -> value
      end

    {:error,
     Error.new(
       :unsupported_filter_operator,
       "governed write filters accept a field equal to a value or nil; " <>
         "operator forms (ranges, IN, NOT IN, !=, BETWEEN, lists) are not supported",
       details: %{field: field, operator: operator}
     )}
  end

  defp invalid_filter(filter) do
    {:error,
     Error.new(
       :invalid_predicate,
       "portable writes only accept comparison, null-test and non-empty IN filters",
       details: %{filter: filter}
     )}
  end

  defp expected_cardinality(contract, operation) do
    contract.operations
    |> Map.fetch!(operation)
    |> Map.get(:expected_cardinality, {:exactly, 1})
  end

  defp insert_admission(operation, contract, context, query_predicate, opts) do
    case QueryEnforcement.storage_insert_admission_backend(operation, opts) do
      nil ->
        {:ok, nil}

      backend ->
        with {:ok, filters} <- bind_tenant_scope(operation.filters || [], contract, context),
             {:ok, filters} <- bind_site_pin(filters, contract),
             filters = bind_root_tenant_column(filters, contract, context),
             {:ok, predicates} <- compile_filters(filters) do
          predicates = if query_predicate, do: predicates ++ [query_predicate], else: predicates

          case predicates do
            [] -> {:ok, nil}
            [predicate] -> admission(backend, predicate, contract)
            predicates -> admission(backend, {:and, predicates}, contract)
          end
        end
    end
  end

  defp admission(:sqlite, predicate, _contract),
    do: {:ok, %{storage_backend: :sqlite, predicate: predicate}}

  # The MySQL-family re-read finds the stored row by the domain primary key:
  # an undeclared key defaults to `id`, and a composite key cannot name one
  # stored row, so the guarded insert is refused as not evaluable.
  defp admission(backend, predicate, contract) do
    case primary_key_column(map_value(contract.source, :primary_key)) do
      {:ok, key} ->
        {:ok, %{storage_backend: backend, predicate: predicate, primary_key: key}}

      :error ->
        {:error,
         Error.new(
           :query_enforcement,
           "guarded insert admission needs a single-column primary key",
           details: %{code: :query_rule_not_evaluable, operation: :insert}
         )}
    end
  end

  defp primary_key_column(nil), do: {:ok, "id"}
  defp primary_key_column([key]), do: primary_key_column(key)

  defp primary_key_column(key) when (is_atom(key) and not is_boolean(key)) or is_binary(key),
    do: if(to_string(key) == "", do: :error, else: {:ok, to_string(key)})

  defp primary_key_column(_key), do: :error

  defp command_metadata(
         operation,
         contract,
         assignments,
         query_predicate,
         foreign_key_guards,
         insert_admission
       ) do
    metadata = %{
      domain_fingerprint: contract.fingerprint,
      field_types: portable_field_types(contract)
    }

    metadata =
      case tenant_fields(contract) do
        [] -> metadata
        fields -> Map.put(metadata, :tenant_fields, fields)
      end

    metadata =
      if insert_admission,
        do: Map.put(metadata, :insert_admission, insert_admission),
        else: metadata

    metadata =
      case QueryEnforcement.metadata(operation, query_predicate) do
        nil -> metadata
        query_metadata -> Map.put(metadata, :query_enforcement, query_metadata)
      end

    metadata =
      case foreign_key_guards do
        [] -> metadata
        guards -> Map.put(metadata, :foreign_key_guards, guards)
      end

    if operation.type == :upsert do
      metadata
      |> Map.put(:conflict_target, List.wrap(operation.conflict_target))
      |> Map.put(:declared_conflict_targets, declared_conflict_targets(contract))
      |> Map.put(:upsert_update_fields, upsert_update_fields(contract, assignments))
    else
      metadata
    end
  end

  # The root's tenant and site columns. Backends whose collations can match
  # tenant values case- or accent-insensitively (MySQL, MariaDB) compare these
  # columns by their stored bytes; other backends ignore the list.
  defp tenant_fields(contract) do
    [
      Core.map_value(contract.source, :tenant_field),
      get_in(contract.scope, [:tenant, :field])
    ]
    |> Enum.filter(&field_name?/1)
    |> Enum.map(&field_id/1)
    |> Enum.uniq()
  end

  # Every field a host-installed or trusted predicate compares with =, <>,
  # !=, IN or NOT IN anywhere in its tree (through AND/OR/NOT) joins the
  # tenant fields: the domain's required filters, the trusted context's
  # required filters and the enforced query. Such a predicate decides tenant
  # identity even on a domain without tenant_field. MySQL-family adapters
  # compare those columns by their stored bytes (judged by declared type) in
  # write conditions, re-reads and admission; other backends ignore the list.
  # The caller's own write filters are not host scope.
  defp with_host_fields(metadata, %Operation{} = operation) do
    evidence =
      case operation.query_enforcement do
        %{} = captured -> Map.get(captured, :filters, [])
        _ -> []
      end

    fields =
      (List.wrap(map_value(operation.domain, :required_filters)) ++
         Keyword.get(operation.opts || [], :trusted_required_filters, []) ++ List.wrap(evidence))
      |> Enum.flat_map(&Selecto.Builder.ExactCompare.comparison_fields/1)
      |> Enum.map(&(&1 |> String.split(".") |> List.last()))

    case Enum.uniq(Map.get(metadata, :tenant_fields, []) ++ fields) do
      [] -> metadata
      all -> Map.put(metadata, :tenant_fields, all)
    end
  end

  # A reference guard's tenant binding. `tenant_exact: false` when the domain
  # types the tenant column as a value that compares exactly already
  # everywhere it declares it (MySQL-family adapters keep the plain
  # comparison), `:bytes` for a UUID tenant (compared by its stored bytes,
  # unconverted).
  defp guard_tenant(domain, tenant_field, tenant_id) do
    guard = %{tenant_field: tenant_field, tenant_value: tenant_id}

    case Selecto.Builder.ExactCompare.text_column?(domain, tenant_field) do
      true -> guard
      mode -> Map.put(guard, :tenant_exact, mode)
    end
  end

  defp declared_conflict_targets(contract) do
    contract.operations
    |> Map.fetch!(:upsert)
    |> Map.get(:conflict_targets, [])
  end

  defp portable_field_types(contract) do
    contract.source
    |> map_value(:columns)
    |> case do
      columns when is_map(columns) ->
        Enum.reduce(columns, %{}, fn {field, spec}, types ->
          case map_value(spec, :type) do
            type when is_atom(type) or is_binary(type) -> Map.put(types, field, type)
            _type -> types
          end
        end)

      _columns ->
        %{}
    end
  end

  defp upsert_update_fields(contract, assignments) do
    assignments
    |> Enum.filter(fn %{field: field} ->
      spec = WriteContract.field_spec(contract, field) || %{}

      WriteContract.writable?(contract, :update, field) and
        spec_value(spec, :immutable) != true and
        spec_value(spec, :write_once) != true and
        spec_value(spec, :server_managed) != true
    end)
    |> Enum.map(& &1.field)
  end

  defp apply_foreign_key_sources(assignments, operation, contract, context) do
    contract
    |> WriteContract.foreign_keys()
    |> Enum.reduce_while({:ok, assignments}, fn {field, spec}, {:ok, current} ->
      case foreign_key_source(spec) do
        :input ->
          ensure_required_foreign_key(current, field, spec, operation.type)

        {:context, key} ->
          apply_context_foreign_key(current, field, key, spec, operation.type, context)
      end
      |> case do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_required_foreign_key(assignments, field, spec, operation)
       when operation in [:insert, :upsert] do
    if spec_value(spec, :required) == true and is_nil(assignment_for(assignments, field)) do
      {:error,
       Error.new(:missing_foreign_key, "required foreign-key value is missing",
         details: %{field: field}
       )}
    else
      {:ok, assignments}
    end
  end

  defp ensure_required_foreign_key(assignments, _field, _spec, _operation), do: {:ok, assignments}

  defp apply_context_foreign_key(assignments, field, key, spec, operation, context)
       when operation in [:insert, :upsert] do
    case Map.fetch(context, key) do
      {:ok, value} ->
        case assignment_for(assignments, field) do
          nil ->
            {:ok, assignments ++ [%{field: field, value: {:literal, value}}]}

          %{value: {:literal, ^value}} ->
            {:ok, assignments}

          _ ->
            {:error,
             Error.new(
               :foreign_key_source_mismatch,
               "foreign-key value must match trusted context",
               details: %{field: field, context_key: key}
             )}
        end

      :error ->
        if spec_value(spec, :required) == true do
          {:error,
           Error.new(:missing_foreign_key_context, "required foreign-key context is missing",
             details: %{field: field, context_key: key}
           )}
        else
          {:ok, assignments}
        end
    end
  end

  defp apply_context_foreign_key(assignments, field, key, _spec, :update, context) do
    case assignment_for(assignments, field) do
      nil ->
        {:ok, assignments}

      %{value: {:literal, value}} ->
        if Map.get(context, key) == value do
          {:ok, assignments}
        else
          {:error,
           Error.new(:foreign_key_source_mismatch, "foreign-key value must match trusted context",
             details: %{field: field, context_key: key}
           )}
        end

      _ ->
        {:error,
         Error.new(:foreign_key_source_mismatch, "foreign-key value must match trusted context",
           details: %{field: field, context_key: key}
         )}
    end
  end

  defp apply_context_foreign_key(assignments, _field, _key, _spec, _operation, _context),
    do: {:ok, assignments}

  # Each guard asks the adapter to prove the referenced row exists. When the
  # referenced relation is tenant-scoped the guard also carries the trusted
  # tenant (`tenant_field`/`tenant_value`), so a caller cannot attach a row to,
  # or probe the existence of, another tenant's parent. References come from
  # `writes.constraints.foreign_keys` and from the owner keys of direct to-one
  # associations; a declared foreign key takes precedence on its field.
  defp foreign_key_guards(%Operation{} = operation, contract, assignments, context) do
    declared = WriteContract.foreign_keys(contract)
    # A NULL reference points at no row, so it needs no parent (as in Perl).
    assignments = Enum.reject(assignments, &match?(%{value: {:literal, nil}}, &1))

    with {:ok, declared_guards} <-
           declared_foreign_key_guards(declared, operation, contract, assignments, context),
         {:ok, association_guards} <-
           association_reference_guards(declared, operation, contract, assignments, context) do
      {:ok, Enum.uniq(declared_guards ++ association_guards)}
    end
  end

  defp declared_foreign_key_guards(declared, operation, contract, assignments, context) do
    declared
    |> Enum.sort_by(fn {field, _spec} -> field end)
    |> Enum.reduce_while({:ok, []}, fn {field, spec}, {:ok, guards} ->
      case {assignment_for(assignments, field), spec_value(spec, :references)} do
        {%{field: assignment_field}, references} when is_map(references) ->
          with {:ok, relation} <-
                 declared_relation(operation.domain, contract, spec_value(references, :relation)),
               guard = %{
                 field: field_id(assignment_field),
                 relation: relation,
                 target_field: field_id(spec_value(references, :field))
               },
               {:ok, scope} <-
                 foreign_key_guard_scope(operation, contract, spec, references, context) do
            {:cont, {:ok, [Map.merge(guard, scope || %{}) | guards]}}
          else
            {:error, error} -> {:halt, {:error, error}}
          end

        _ ->
          {:cont, {:ok, guards}}
      end
    end)
    |> case do
      {:ok, guards} -> {:ok, Enum.reverse(guards)}
      error -> error
    end
  end

  defp foreign_key_guard_scope(operation, contract, spec, references, context) do
    relation = spec_value(references, :relation)

    case referenced_tenant_field(operation.domain, contract, references) do
      {:tenant, tenant_field} ->
        case context[:tenant_id] do
          nil ->
            {:error,
             Error.new(
               :missing_tenant_scope,
               "foreign-key guard references a tenant-scoped relation without trusted tenant context",
               details: %{relation: relation, tenant_field: tenant_field}
             )}

          tenant_id ->
            {:ok, guard_tenant(operation.domain, tenant_field, tenant_id)}
        end

      :shared ->
        {:ok, nil}

      :undeclared ->
        if tenant_scoped_write?(contract, context) and foreign_key_source(spec) == :input do
          {:error,
           Error.new(
             :invalid_domain,
             "an input foreign key on a tenant-scoped write must declare the referenced relation's tenant field",
             details: %{
               code: :foreign_key_tenant_scope_undeclared,
               relation: relation,
               required: [:references, :tenant_field]
             }
           )}
        else
          {:ok, nil}
        end

      {:error, code} ->
        {:error,
         Error.new(:invalid_domain, "foreign-key tenant scope is invalid",
           details: %{code: code, relation: relation}
         )}
    end
  end

  # Resolution order: an explicit `references.tenant_field` (a field, or
  # `false` for a relation shared by every tenant), then the root relation for
  # a self-reference, then every domain schema backed by the referenced
  # relation that declares `tenant_field`.
  defp referenced_tenant_field(domain, contract, references) do
    relation = to_string(spec_value(references, :relation))
    candidates = referenced_relations(domain, contract, relation)

    case Core.fetch_key(references, :tenant_field) do
      {:ok, value} when value in [false, nil] ->
        :shared

      {:ok, field} when is_atom(field) or is_binary(field) ->
        validate_referenced_tenant_field(field_id(field), candidates)

      {:ok, _value} ->
        {:error, :invalid_foreign_key_tenant_field}

      :error ->
        candidates
        |> Enum.map(&elem(&1, 1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&field_id/1)
        |> Enum.uniq()
        |> case do
          [] -> :undeclared
          [field] -> validate_referenced_tenant_field(field, candidates)
          _fields -> {:error, :ambiguous_foreign_key_tenant_field}
        end
    end
  end

  defp validate_referenced_tenant_field(field, candidates) do
    if Enum.all?(candidates, fn {relation, _tenant_field} ->
         Core.field_in_list?(Core.relation_fields(relation), field)
       end),
       do: {:tenant, field},
       else: {:error, :unknown_foreign_key_tenant_field}
  end

  defp referenced_relations(domain, contract, relation) do
    root =
      if relation_name?(contract.source, nil, relation) do
        root_tenant =
          get_in(contract.scope, [:tenant, :field]) ||
            Core.map_value(contract.source, :tenant_field)

        [{contract.source, root_tenant}]
      else
        []
      end

    schemas =
      case Core.map_value(domain, :schemas) do
        schemas when is_map(schemas) ->
          schemas
          |> Enum.filter(fn {key, schema} ->
            is_map(schema) and relation_name?(schema, key, relation)
          end)
          |> Enum.map(fn {_key, schema} -> {schema, Core.map_value(schema, :tenant_field)} end)

        _schemas ->
          []
      end

    root ++ schemas
  end

  # R59: a reference resolves through the schema the domain declares for that
  # relation, never the connection's path, where a namesake could answer for
  # it. With schemas declared, a bare name the domain does not know refuses.
  defp declared_relation(domain, contract, relation) do
    name = to_string(relation)

    names =
      domain
      |> referenced_relations(contract, name)
      |> Enum.map(fn {source, _tenant_field} ->
        to_string(SelectoUpdato.WriteContract.relation_under(source, contract.source) || name)
      end)
      |> Enum.uniq()

    declared? = not is_nil(SelectoUpdato.WriteContract.declared_schema(contract.source))

    case names do
      [one] ->
        {:ok, one}

      [] ->
        if declared? and not String.contains?(name, "."),
          do: undeclared_relation(name),
          else: {:ok, relation}

      _several ->
        undeclared_relation(name)
    end
  end

  defp undeclared_relation(name) do
    {:error,
     Error.new(
       :invalid_domain,
       "a reference's relation must resolve to one declared relation; name its schema",
       details: %{code: :foreign_key_relation_undeclared, relation: name}
     )}
  end

  # A reference names a physical relation, so a schema matches by its table,
  # or by that table in its declared schema; a schema key stands in only for a
  # schema that declares no table.
  defp relation_name?(relation, key, name) do
    case Enum.reject(
           [Core.map_value(relation, :source_table), Core.map_value(relation, :table)],
           &is_nil/1
         ) do
      [] ->
        not is_nil(key) and to_string(key) == name

      tables ->
        Enum.any?(tables, &(to_string(&1) == name)) or
          to_string(SelectoUpdato.WriteContract.relation_name(relation)) == name
    end
  end

  # A write confined to a trusted tenant by `writes.scope.tenant`; a reference
  # whose tenancy the domain does not record cannot be guarded on it.
  defp tenant_scoped_write?(contract, context) do
    match?(%{tenant: %{field: field}} when not is_nil(field), contract.scope) and
      not is_nil(context[:tenant_id])
  end

  # The owner key of a direct to-one association references the target row.
  # Not guarded: the row's own primary key (a reverse has-one), a to-many,
  # `through` or values-backed association, a field a declared foreign key
  # already covers, and a null reference, which names no parent. A nested
  # child's parent key is bound later and is never an assignment here.
  defp association_reference_guards(declared, operation, contract, assignments, context) do
    schemas =
      case Core.map_value(operation.domain, :schemas) do
        schemas when is_map(schemas) -> schemas
        _schemas -> %{}
      end

    root = %{
      table: relation_table(contract.source),
      relation: to_string(SelectoUpdato.WriteContract.relation_name(contract.source)),
      source: contract.source,
      tenant_field:
        get_in(contract.scope, [:tenant, :field]) ||
          Core.map_value(contract.source, :tenant_field),
      primary_keys:
        contract.source
        |> Core.map_value(:primary_key)
        |> Kernel.||(:id)
        |> List.wrap()
        |> Enum.filter(&field_name?/1)
        |> Enum.map(&field_id/1)
    }

    case Core.map_value(contract.source, :associations) do
      associations when is_map(associations) ->
        associations
        |> Enum.sort_by(fn {name, _association} -> to_string(name) end)
        |> Enum.reduce_while({:ok, []}, fn {_name, association}, {:ok, guards} ->
          case association_reference(association, schemas, declared, root, assignments) do
            nil ->
              {:cont, {:ok, guards}}

            reference ->
              case association_reference_guard(reference, operation.domain, contract, context) do
                {:ok, nil} -> {:cont, {:ok, guards}}
                {:ok, guard} -> {:cont, {:ok, [guard | guards]}}
                {:error, error} -> {:halt, {:error, error}}
              end
          end
        end)
        |> case do
          {:ok, guards} -> {:ok, Enum.reverse(guards)}
          error -> error
        end

      _associations ->
        {:ok, []}
    end
  end

  defp association_reference(association, schemas, declared, root, assignments)
       when is_map(association) do
    owner_key = Core.map_value(association, :owner_key)
    related_key = Core.map_value(association, :related_key)
    target = association_target(schemas, Core.map_value(association, :queryable))
    table = target_relation(target, root) || association_table(association, root, schemas)

    with true <- field_name?(owner_key) and field_name?(related_key),
         field = field_id(owner_key),
         false <- Map.has_key?(declared, field) or field in root.primary_keys,
         %{value: value} when value != {:literal, nil} <- assignment_for(assignments, field),
         false <- is_nil(table) or not is_nil(Core.map_value(association, :through)),
         false <- values_backed?(association, target),
         :one <- association_cardinality(association, target, related_key) do
      %{
        field: field,
        relation: to_string(table),
        target_field: field_id(related_key),
        tenancy:
          if(table == :undeclared,
            do: :undeclared_relation,
            else: association_tenancy(association, target, table, root)
          ),
        relation_name: to_string(Core.map_value(association, :table))
      }
    else
      _not_a_reference -> nil
    end
  end

  defp association_reference(_association, _schemas, _declared, _root, _assignments), do: nil

  # An association's `table:` fallback names a relation like a reference does
  # (R59): the root's, a schema's, or, with schemas declared, nothing known.
  defp association_table(association, root, schemas) do
    case Core.map_value(association, :table) do
      nil ->
        nil

      table ->
        name = to_string(table)

        matches =
          schemas
          |> Enum.filter(fn {key, schema} ->
            is_map(schema) and relation_name?(schema, key, name)
          end)
          |> Enum.map(fn {_key, schema} ->
            to_string(SelectoUpdato.WriteContract.relation_under(schema, root.source))
          end)

        matches = if name == to_string(root.table), do: [root.relation | matches], else: matches

        case Enum.uniq(matches) do
          [one] ->
            one

          [] ->
            if String.contains?(root.relation, ".") and not String.contains?(name, "."),
              do: :undeclared,
              else: table

          _several ->
            :undeclared
        end
    end
  end

  # The association's target scope key, else the target schema's tenant
  # field, else the root's tenant field for a self-reference.
  defp association_tenancy(association, target, table, root) do
    cond do
      field_name?(Core.map_value(association, :target_scope_key)) ->
        {:tenant, field_id(Core.map_value(association, :target_scope_key))}

      field_name?(Core.map_value(target, :tenant_field)) ->
        {:tenant, field_id(Core.map_value(target, :tenant_field))}

      to_string(table) == root.relation and field_name?(root.tenant_field) ->
        {:tenant, field_id(root.tenant_field)}

      true ->
        :undeclared
    end
  end

  defp association_reference_guard(
         %{tenancy: {:tenant, tenant_field}} = reference,
         domain,
         _contract,
         context
       ) do
    case context[:tenant_id] do
      nil ->
        {:ok, nil}

      tenant_id ->
        {:ok,
         reference
         |> Map.drop([:tenancy, :relation_name])
         |> Map.merge(guard_tenant(domain, tenant_field, tenant_id))}
    end
  end

  defp association_reference_guard(%{tenancy: :undeclared_relation} = reference, _d, _c, _ctx),
    do: undeclared_relation(reference.relation_name)

  defp association_reference_guard(
         %{tenancy: :undeclared} = reference,
         _domain,
         contract,
         context
       ) do
    if tenant_scoped_write?(contract, context) do
      {:error,
       Error.new(
         :invalid_domain,
         "a reference on a tenant-scoped write must declare the referenced relation's tenant field",
         details: %{
           code: :foreign_key_tenant_scope_undeclared,
           field: reference.field,
           relation: reference.relation,
           required: [:references, :tenant_field]
         }
       )}
    else
      {:ok, nil}
    end
  end

  defp association_target(_schemas, nil), do: nil

  defp association_target(schemas, queryable) do
    case Core.fetch_key(schemas, queryable) do
      {:ok, schema} when is_map(schema) ->
        schema

      _missing ->
        Enum.find_value(schemas, fn {key, schema} ->
          if to_string(key) == to_string(queryable) and is_map(schema), do: schema
        end)
    end
  end

  defp values_backed?(association, target) do
    not is_nil(Core.map_value(association, :values)) or
      (is_map(target) and not is_nil(Core.map_value(target, :values)))
  end

  # An authored cardinality wins; otherwise an association to the target's
  # primary key is to-one.
  defp association_cardinality(association, target, related_key) do
    case Core.map_value(association, :cardinality) do
      value when value in [:one, "one"] ->
        :one

      nil ->
        target_key = (is_map(target) && Core.map_value(target, :primary_key)) || :id

        if field_name?(target_key) and field_id(target_key) == field_id(related_key),
          do: :one,
          else: :many

      _cardinality ->
        :many
    end
  end

  defp field_name?(value) when is_boolean(value) or is_nil(value), do: false
  defp field_name?(value), do: Core.field_ref?(value)

  defp target_relation(relation, root) when is_map(relation),
    do: SelectoUpdato.WriteContract.relation_under(relation, root.source)

  defp target_relation(_relation, _root), do: nil

  defp relation_table(relation) when is_map(relation),
    do: Core.map_value(relation, :source_table) || Core.map_value(relation, :table)

  defp relation_table(_relation), do: nil

  defp foreign_key_source(spec) do
    case spec_value(spec, :source) do
      :input -> :input
      "input" -> :input
      {:context, key} -> {:context, key}
      source when is_map(source) -> {:context, spec_value(source, :key)}
    end
  end

  defp assignment_for(assignments, field),
    do: Enum.find(assignments, &(field_id(&1.field) == field_id(field)))

  @doc false
  # Lessons 47 and 47a: a trusted engine tenant bounds every write on a domain
  # that declares `source.tenant_field`, with or without `writes.scope.tenant`,
  # and the bound column is that declared tenant_field.
  #
  #   * a single-column scope (scope field == tenant_field) is unchanged;
  #   * a two-column domain (scope field site_id) binds tenant_id instead. The
  #     site column is never bound to the engine value; it is pinned only by
  #     positive site conjuncts in trusted predicates (`:site_pin`, lesson
  #     47b): the domain's required filters, the trusted tenant context's
  #     required filters and an enforced host query, never request filters;
  #   * a domain without a write scope binds tenant_field when a trusted
  #     tenant is present;
  #   * a graph child whose tenant_field is the root's scope column is not
  #     bound to the engine value: its site values must lie within the root's
  #     pinned site set, or the write is refused.
  @spec effective_tenant_contract(map(), Operation.t(), map(), keyword()) :: map()
  def effective_tenant_contract(contract, %Operation{} = operation, context, opts \\ []) do
    contract
    |> base_tenant_contract(operation, context, opts)
    |> graph_child_tenant_columns(Keyword.get(opts, :graph_root_tenant), context)
  end

  # A graph child is checked on every column that names one of the root's
  # tenant columns, whatever the child declares (lesson 47b): the root
  # tenant_field column is bound to the trusted tenant, and the root scope
  # column is confined to the root's trusted site pin (refused without one).
  defp graph_child_tenant_columns(contract, nil, _context), do: contract

  defp graph_child_tenant_columns(contract, root, context) do
    contract
    |> drop_root_column_site_pin(root)
    |> child_site_column(root)
    |> child_tenant_column(root, context)
  end

  # A child's own scope column that is the root tenant column is bound as the
  # root tenant column, not pinned as a site.
  defp drop_root_column_site_pin(contract, %{field: field}) when is_binary(field) do
    case contract.scope[:site_pin] do
      %{field: site, child: false} ->
        if tenant_field?(site, field),
          do: %{contract | scope: Map.delete(contract.scope, :site_pin)},
          else: contract

      _ ->
        contract
    end
  end

  defp drop_root_column_site_pin(contract, _root), do: contract

  defp child_site_column(contract, %{site_field: site} = root) when is_binary(site) do
    if declares_field?(contract.source, site) do
      pin = %{field: site, values: root.site_set, child: true}
      %{contract | scope: Map.put(contract.scope, :site_pin, pin)}
    else
      contract
    end
  end

  defp child_site_column(contract, _root), do: contract

  defp child_tenant_column(contract, %{field: field}, context) when is_binary(field) do
    bound = get_in(contract.scope, [:tenant, :field])

    cond do
      is_nil(context[:tenant_id]) or not declares_field?(contract.source, field) ->
        contract

      not is_nil(bound) and tenant_field?(bound, field) ->
        contract

      is_nil(bound) ->
        tenant = %{field: field, required: true, satisfied_by: [:trusted_context]}
        %{contract | scope: Map.put(contract.scope, :tenant, tenant)}

      # The child keeps its own declared tenancy; the root tenant column is
      # bound to the trusted tenant as well.
      true ->
        %{contract | scope: Map.put(contract.scope, :root_tenant_column, field)}
    end
  end

  defp child_tenant_column(contract, _root, _context), do: contract

  defp declares_field?(relation, field),
    do: Enum.any?(Core.relation_fields(relation), &tenant_field?(&1, field))

  defp base_tenant_contract(contract, %Operation{} = operation, context, opts) do
    declared = map_value(contract.source, :tenant_field)
    scope_tenant = contract.scope[:tenant]
    root = Keyword.get(opts, :graph_root_tenant)

    cond do
      is_nil(declared) ->
        contract

      site_child?(root, declared) ->
        scope =
          contract.scope
          |> Map.delete(:tenant)
          |> Map.put(:site_pin, %{field: field_id(declared), values: root.site_set, child: true})

        %{contract | scope: scope}

      is_map(scope_tenant) and tenant_field?(scope_tenant[:field], declared) ->
        contract

      is_map(scope_tenant) ->
        site = field_id(scope_tenant[:field])

        values =
          intersect_pins(
            trusted_site_values(operation, site),
            if(root && root.site_field == site, do: root.site_set)
          )

        scope =
          contract.scope
          |> Map.put(:tenant, Map.put(scope_tenant, :field, field_id(declared)))
          |> Map.put(:site_pin, %{field: site, values: values, child: false})

        %{contract | scope: scope}

      is_nil(context[:tenant_id]) ->
        contract

      true ->
        tenant = %{field: field_id(declared), required: true, satisfied_by: [:trusted_context]}
        %{contract | scope: Map.put(contract.scope, :tenant, tenant)}
    end
  end

  @doc false
  # The root's tenant columns and pinned site set (nil when unpinned), handed
  # to graph children.
  @spec graph_root_tenant(Operation.t(), map()) :: map() | nil
  def graph_root_tenant(%Operation{} = operation, context) do
    # The root tenant column is source.tenant_field, else the write scope's
    # tenant field (lessons 24 and 29k): a root tenanted only by
    # writes.scope.tenant still checks its children's tenant columns.
    with {:ok, contract} <- compile_contract(operation.domain),
         declared when not is_nil(declared) <-
           map_value(contract.source, :tenant_field) || get_in(contract.scope, [:tenant, :field]) do
      effective = effective_tenant_contract(contract, operation, context)
      pin = effective.scope[:site_pin] || %{}

      %{
        field: field_id(declared),
        site_field: Map.get(pin, :field),
        site_set: Map.get(pin, :values)
      }
    else
      _ -> nil
    end
  end

  defp site_child?(nil, _declared), do: false

  defp site_child?(root, declared) do
    not is_nil(root.site_field) and tenant_field?(declared, root.site_field) and
      not tenant_field?(declared, root.field)
  end

  # Sites pinned by trusted predicates only (lesson 47b): the domain's
  # required filters, the trusted tenant context's required filters, and a
  # query enforced as the host's trusted scope. Caller filters on the write
  # and ordinary query evidence never pin a site.
  defp trusted_site_values(%Operation{} = operation, field) do
    enforced =
      case operation.query_enforcement do
        %{host_scope: true} = evidence -> Map.get(evidence, :filters, [])
        _ -> []
      end

    (List.wrap(map_value(operation.domain, :required_filters)) ++
       enforced ++ Keyword.get(operation.opts || [], :trusted_required_filters, []))
    |> site_values(field)
  end

  # The values every positive top-level conjunct on `field` admits (their
  # intersection), or nil when no conjunct pins it.
  defp site_values(filters, field) do
    filters
    |> Enum.flat_map(&site_conjunct_sets(&1, field))
    |> Enum.reduce(nil, &intersect_pins(&2, &1))
  end

  defp site_conjunct_sets({:and, filters}, field) when is_list(filters),
    do: Enum.flat_map(filters, &site_conjunct_sets(&1, field))

  defp site_conjunct_sets({filter_field, value}, field)
       when is_atom(filter_field) or is_binary(filter_field) do
    if filter_field not in [:or, :not] and tenant_field?(filter_field, field),
      do: site_value_set(value),
      else: []
  end

  defp site_conjunct_sets({filter_field, comparator, value}, field)
       when is_atom(filter_field) or is_binary(filter_field) do
    if tenant_field?(filter_field, field), do: site_value_set({comparator, value}), else: []
  end

  defp site_conjunct_sets(_filter, _field), do: []

  defp site_value_set({comparator, values})
       when comparator in [:in, "in"] and is_list(values) and values != [],
       do: [values]

  defp site_value_set({comparator, value}) when comparator in [:eq, "eq", :=, "="],
    do: site_value_set(value)

  defp site_value_set(values) when is_list(values) and values != [],
    do: if(Enum.all?(values, &scalar?/1), do: [values], else: [])

  defp site_value_set(value), do: if(scalar?(value), do: [[value]], else: [])

  defp scalar?(value), do: is_binary(value) or is_number(value)

  defp intersect_pins(nil, other), do: other
  defp intersect_pins(left, nil), do: left
  defp intersect_pins(left, right), do: Enum.filter(left, &(&1 in right))

  # A graph child on the root's scope column is confined to the root's pinned
  # site set; with no pinned set it cannot be bounded and is refused.
  defp bind_site_pin(filters, %{scope: %{site_pin: %{child: true, field: field, values: values}}}) do
    case values do
      nil -> site_scope_missing(field)
      [] -> tenant_mismatch(field)
      [value] -> {:ok, filters ++ [{field, value}]}
      values -> {:ok, filters ++ [{field, :in, values}]}
    end
  end

  defp bind_site_pin(filters, _contract), do: {:ok, filters}

  # Lesson 47b: under a trusted tenant, a write that sets the site column
  # (every insert or upsert, and an update assigning it) needs a trusted site
  # pin, and its value must lie inside the pinned set. An insert omitting the
  # site is filled only when exactly one site is pinned.
  defp pin_site_assignment(assignments, %Operation{type: type}, contract, context)
       when type in [:insert, :upsert, :update] do
    case contract.scope[:site_pin] do
      %{field: field, values: values} = pin ->
        if pin.child or not is_nil(context[:tenant_id]),
          do: check_site_assignment(assignments, type, field, values),
          else: {:ok, assignments}

      _ ->
        {:ok, assignments}
    end
  end

  defp pin_site_assignment(assignments, _operation, _contract, _context), do: {:ok, assignments}

  defp check_site_assignment(assignments, type, field, values) do
    assignment = Enum.find(assignments, &(field_id(&1.field) == field))

    cond do
      type == :update and is_nil(assignment) ->
        {:ok, assignments}

      is_nil(values) ->
        site_scope_missing(field)

      is_nil(assignment) and length(values) == 1 ->
        {:ok, assignments ++ [%{field: field, value: {:literal, hd(values)}}]}

      is_nil(assignment) ->
        site_scope_missing(field)

      match?({:literal, _}, assignment.value) and elem(assignment.value, 1) in values ->
        {:ok, assignments}

      true ->
        tenant_mismatch(field)
    end
  end

  # Values Updato itself fills from trusted sources (the single trusted site
  # pin, a graph child's root tenant column) are governed autofill: written
  # whether or not the column is caller-insertable. A caller-supplied value
  # of the same column is checked like any other (lesson 47b).
  defp governed_fill?(contract, %Operation{} = operation, field, value, context) do
    not caller_supplied?(operation, field) and
      (single_pinned_site?(contract, field, value) or
         (tenant_field?(contract.scope[:root_tenant_column] || "", field) and
            value == context[:tenant_id]))
  end

  defp caller_supplied?(%Operation{type: :update, changes: changes}, field),
    do: has_field?(changes, field)

  defp caller_supplied?(%Operation{attrs: attrs}, field), do: has_field?(attrs, field)

  defp has_field?(values, field) when is_map(values),
    do:
      Enum.any?(Map.keys(values), &((is_atom(&1) or is_binary(&1)) and tenant_field?(&1, field)))

  defp has_field?(_values, _field), do: false

  # A graph child that keeps its own tenancy but also stores the root tenant
  # column binds that column to the trusted tenant as well (lesson 47b).
  defp root_tenant_assignment(assignments, %Operation{type: type}, contract, context)
       when type in [:insert, :upsert, :update] do
    field = contract.scope[:root_tenant_column]
    tenant_id = context[:tenant_id]

    if is_nil(field) or is_nil(tenant_id) do
      {:ok, assignments}
    else
      case Enum.find(assignments, &tenant_field?(&1.field, field)) do
        nil when type == :update -> {:ok, assignments}
        nil -> {:ok, assignments ++ [%{field: field_id(field), value: {:literal, tenant_id}}]}
        %{value: {:literal, ^tenant_id}} -> {:ok, assignments}
        _other -> tenant_mismatch(field)
      end
    end
  end

  defp root_tenant_assignment(assignments, _operation, _contract, _context),
    do: {:ok, assignments}

  defp bind_root_tenant_column(filters, contract, context) do
    case {contract.scope[:root_tenant_column], context[:tenant_id]} do
      {nil, _tenant_id} -> filters
      {_field, nil} -> filters
      {field, tenant_id} -> filters ++ [{field_id(field), tenant_id}]
    end
  end

  defp single_pinned_site?(contract, field, value) do
    case contract.scope[:site_pin] do
      %{field: site, values: [pinned]} -> tenant_field?(site, field) and pinned == value
      _ -> false
    end
  end

  defp site_scope_missing(field) do
    {:error,
     Error.new(:missing_tenant_scope, "site writes need a trusted site pin",
       details: %{field: field}
     )}
  end

  defp trusted_context(operation, opts) do
    execution_context = Keyword.get(opts, :context, %{})

    case Tenant.resolve_trusted_context(operation, execution_context) do
      {:ok, context} ->
        {:ok, context}

      {:error, conflict} ->
        invalidate_action_authorization(operation, conflict)

        {:error,
         Error.new(:tenant_mismatch, "Trusted tenant context is ambiguous",
           details: %{
             code: :conflicting_trusted_tenant_context,
             conflict: conflict
           }
         )}
    end
  end

  defp invalidate_action_authorization(%Operation{action_policy: policy}, conflict)
       when is_map(policy) do
    grant = map_value(policy, :authorization_grant)

    if grant do
      _ = ActionAuthorization.consume(grant, %{invalid_tenant_context: conflict})
    end

    :ok
  end

  defp invalidate_action_authorization(%Operation{}, _conflict), do: :ok

  defp spec_value(spec, key) when is_map(spec) do
    Map.get(spec, key) || Map.get(spec, Atom.to_string(key))
  end

  defp field_id(field) when is_atom(field), do: Atom.to_string(field)
  defp field_id(field) when is_binary(field), do: field
  defp tenant_field?(left, right), do: field_id(left) == field_id(right)

  # Whether a filter names a tenant column anywhere: every atom or string
  # in the term (filter keys, nested boolean groups, comparator tuples) is
  # compared with the tenant fields, bare or as a qualified name's last
  # segment. Over-matching only tightens the post-image.
  defp reads_tenant_field?(_filter, []), do: false

  defp reads_tenant_field?(filter, tenant_fields) do
    filter
    |> term_names()
    |> Enum.any?(fn name ->
      Enum.any?(tenant_fields, fn field ->
        tenant_field?(name, field) or name |> String.split(".") |> List.last() == field
      end)
    end)
  end

  defp term_names(term) when is_binary(term), do: [term]

  defp term_names(term) when is_atom(term) and not is_nil(term) and not is_boolean(term),
    do: [Atom.to_string(term)]

  defp term_names(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.flat_map(&term_names/1)

  defp term_names(term) when is_list(term), do: Enum.flat_map(term, &term_names/1)

  defp term_names(%{__struct__: _}), do: []

  defp term_names(term) when is_map(term),
    do: Enum.flat_map(term, fn {key, value} -> term_names(key) ++ term_names(value) end)

  defp term_names(_term), do: []
end
