defmodule SelectoUpdato.ActionAuthorization do
  @moduledoc false

  use GenServer

  alias SelectoUpdato.{
    ActionPlan,
    CapabilityResolver,
    Error,
    Operation,
    PlannedOperation,
    Tenant
  }

  @server __MODULE__
  @default_resolver_timeout 5_000
  @max_resolver_timeout 30_000
  @default_grant_ttl 30_000
  @max_grant_ttl 60_000
  @default_planned_operation_ttl 300_000
  @max_planned_operation_ttl 3_600_000

  # Operation options that decide whether a write is admitted (choice-source
  # membership inputs) are part of the authorized payload. Tenant and scope
  # bookkeeping options are excluded because execution legitimately adds them;
  # the trusted tenant is bound separately through the authorization context.
  @admission_opt_keys [
    :actor,
    :choice_membership_resolver,
    :choice_source_context,
    :choice_source_domain,
    :choice_source_filters,
    :choice_source_membership_resolver,
    :choice_source_record
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, @server))
  end

  @spec authorize_and_issue(ActionPlan.t(), :preview | :execute, map(), keyword()) ::
          {:ok, ActionPlan.t(), SelectoUpdato.CapabilityDecision.t(), reference() | nil}
          | {:error, term()}
  def authorize_and_issue(%ActionPlan{} = plan, phase, context, opts)
      when phase in [:preview, :execute] and is_map(context) and is_list(opts) do
    with {:ok, authorization_context} <- authorization_context(context, opts) do
      case Process.whereis(@server) do
        nil ->
          unavailable_error()

        _pid ->
          timeout = resolver_timeout(opts)

          safe_call(
            {:authorize_and_issue, plan, phase, context, opts, timeout, authorization_context},
            timeout + 1_000,
            unavailable_error()
          )
      end
    end
  end

  @spec consume(term(), map()) :: :ok | {:error, Error.t()}
  def consume(grant, evidence) when is_map(evidence) do
    case Process.whereis(@server) do
      nil ->
        authorization_error(:unregistered_action_authorization)

      _pid ->
        safe_call(
          {:consume, grant, evidence},
          5_000,
          authorization_error(:unregistered_action_authorization)
        )
    end
  end

  @doc false
  @spec consume_plan(ActionPlan.t(), :preview | :execute, map(), keyword()) ::
          :ok | {:error, term()}
  def consume_plan(%ActionPlan{} = plan, phase, context, opts \\ [])
      when phase in [:preview, :execute] and is_map(context) and is_list(opts) do
    result =
      with :ok <- validate_plan_authorization(plan, phase, context),
           {:ok, authorization_context} <- authorization_context(context, opts) do
        consume(
          plan.authorization_grant,
          plan_evidence(plan, nil, phase, authorization_context)
        )
      end

    # Early phase/context admission failures must not preserve the authority
    # in the genuine plan for a later attempt with restored evidence.
    if match?({:error, _}, result) and not is_nil(plan.authorization_grant) do
      _ = consume(plan.authorization_grant, %{rejected_contract_action: true})
    end

    result
  end

  @spec revoke(term()) :: :ok
  def revoke(nil), do: :ok

  def revoke(grant) do
    if Process.whereis(@server), do: GenServer.cast(@server, {:revoke, grant})
    :ok
  end

  @doc false
  @spec operation_fingerprint(Operation.t()) :: binary()
  def operation_fingerprint(%Operation{} = operation) do
    %{
      domain: operation.domain,
      type: operation.type,
      attrs: operation.attrs,
      changes: operation.changes,
      filters: payload_filters(operation),
      query_enforcement: operation.query_enforcement,
      conflict_target: operation.conflict_target,
      returning: operation.returning,
      expected_cardinality: operation.expected_cardinality,
      extensions: operation.extensions,
      admission_opts: admission_opts(operation)
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp admission_opts(%Operation{opts: opts}) when is_list(opts) do
    @admission_opt_keys
    |> Enum.flat_map(fn key ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> [{key, value}]
        :error -> []
      end
    end)
  end

  defp admission_opts(%Operation{}), do: []

  defp payload_filters(%Operation{} = operation) do
    tenant_field =
      operation.domain
      |> SelectoUpdato.WriteContract.tenant_scope()
      |> map_or_empty()
      |> map_value(:field)
      |> case do
        nil -> nil
        field -> to_string(field)
      end

    # What the execution scope added after the grant was issued is the trusted
    # context's required filters, which authorization_context/2 binds, not the plan's.
    scope_filters = Keyword.get(operation.opts || [], :scope_filters, [])

    operation.filters
    |> List.wrap()
    |> Enum.reject(&(&1 in scope_filters))
    |> Enum.reject(fn
      {field, _value} when not is_nil(tenant_field) -> to_string(field) == tenant_field
      _filter -> false
    end)
  end

  @doc false
  @spec authorization_context(map(), keyword()) ::
          {:ok, map()} | {:error, {:validation_error, String.t(), map()}}
  def authorization_context(context, opts \\ []) when is_map(context) and is_list(opts) do
    with :ok <- validate_identity_sources(context, opts) do
      {:ok,
       %{
         actor: identity_fingerprint(actor_identity_sources(context, opts)),
         tenant: identity_fingerprint(tenant_identity_sources(context, opts)),
         # The trusted required filters bound the grant: a grant issued under
         # one set does not write under another, or under none.
         required_filters: SelectoUpdato.Tenant.trusted_filter_binding(context, opts)
       }}
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{grants: %{}, pending: %{}, planned_operations: %{}}}

  @impl true
  def handle_call(
        {:seal_planned_action, %ActionPlan{} = plan, requested_ttl},
        _from,
        state
      ) do
    case seal_candidate(plan) do
      {:ok, stored_plan, operation} ->
        ttl = planned_operation_ttl(requested_ttl)
        token = make_ref()
        timer = Process.send_after(self(), {:expire_planned_operation, token}, ttl)
        entry = %{operation: operation, plan: stored_plan, timer: timer}

        {:reply, {:ok, %PlannedOperation{token: token}},
         put_in(state.planned_operations[token], entry)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(
        {:authorize_and_issue,
         %ActionPlan{operation_builder: %PlannedOperation{token: token}} = plan, phase, context,
         opts, timeout, authorization_context},
        from,
        state
      ) do
    case Map.fetch(state.planned_operations, token) do
      {:ok, %{operation: operation, plan: %ActionPlan{} = stored_plan}}
      when is_nil(operation) or is_struct(operation, Operation) ->
        case validate_registered_plan(plan, stored_plan, operation) do
          :ok ->
            start_authorization(
              stored_plan,
              operation,
              phase,
              context,
              opts,
              timeout,
              authorization_context,
              from,
              state
            )

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      :error ->
        {:reply, invalid_planned_operation_error(:unregistered_planned_operation), state}

      _other ->
        {:reply, invalid_planned_operation_error(:invalid_planned_operation), state}
    end
  end

  def handle_call(
        {:authorize_and_issue, %ActionPlan{}, _phase, _context, _opts, _timeout,
         _authorization_context},
        _from,
        state
      ) do
    {:reply, invalid_planned_operation_error(:invalid_planned_operation), state}
  end

  def handle_call({:consume, grant, evidence}, _from, state) do
    case Map.pop(state.grants, grant) do
      {%{evidence: ^evidence, timer: timer}, remaining} ->
        Process.cancel_timer(timer)
        {:reply, :ok, %{state | grants: remaining}}

      {nil, remaining} ->
        {:reply, authorization_error(:unregistered_action_authorization),
         %{state | grants: remaining}}

      {%{timer: timer}, remaining} ->
        Process.cancel_timer(timer)

        {:reply, authorization_error(:action_authorization_mismatch),
         %{state | grants: remaining}}
    end
  end

  @impl true
  def handle_cast({:revoke, grant}, state) do
    case Map.pop(state.grants, grant) do
      {nil, grants} ->
        {:noreply, %{state | grants: grants}}

      {%{timer: timer}, grants} ->
        Process.cancel_timer(timer)
        {:noreply, %{state | grants: grants}}
    end
  end

  @impl true
  def handle_info({:authorization_result, request_ref, result}, state) do
    case pop_pending(state, request_ref) do
      {nil, state} ->
        {:noreply, state}

      {pending, state} ->
        cancel_pending(pending)
        {reply, grants} = authorization_reply(pending, result, state.grants)
        GenServer.reply(pending.from, reply)
        {:noreply, %{state | grants: grants}}
    end
  end

  def handle_info({:authorization_timeout, request_ref}, state) do
    case pop_pending(state, request_ref) do
      {nil, state} ->
        {:noreply, state}

      {pending, state} ->
        Process.exit(pending.pid, :kill)
        Process.demonitor(pending.monitor, [:flush])
        GenServer.reply(pending.from, resolver_timeout_error(pending.plan, pending.phase))
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case pending_by_monitor(state.pending, monitor) do
      nil ->
        {:noreply, state}

      {request_ref, pending} ->
        {_pending, state} = pop_pending(state, request_ref)
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, resolver_failure_error(pending.plan, pending.phase, reason))
        {:noreply, state}
    end
  end

  def handle_info({:expire_grant, grant}, state) do
    {:noreply, %{state | grants: Map.delete(state.grants, grant)}}
  end

  def handle_info({:expire_planned_operation, token}, state) do
    {:noreply, %{state | planned_operations: Map.delete(state.planned_operations, token)}}
  end

  defp start_authorization(
         plan,
         operation,
         phase,
         context,
         opts,
         timeout,
         authorization_context,
         from,
         state
       ) do
    request_ref = make_ref()
    server = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result = safe_authorize(plan, phase, context, opts)
        send(server, {:authorization_result, request_ref, result})
      end)

    timer = Process.send_after(self(), {:authorization_timeout, request_ref}, timeout)

    pending = %{
      from: from,
      plan: plan,
      operation: operation,
      phase: phase,
      pid: pid,
      monitor: monitor,
      timer: timer,
      authorization_context: authorization_context,
      grant_ttl: grant_ttl(opts)
    }

    {:noreply, put_in(state.pending[request_ref], pending)}
  end

  defp safe_authorize(plan, phase, context, opts) do
    try do
      CapabilityResolver.authorize_action(plan, phase, context, opts)
    rescue
      error ->
        resolver_exception_error(plan, phase, :raise, Exception.message(error))
    catch
      kind, reason ->
        resolver_exception_error(plan, phase, kind, inspect(reason))
    end
  end

  defp authorization_reply(pending, {:ok, decision}, grants) do
    case pending.operation do
      %Operation{action_policy: policy} = operation when is_map(policy) ->
        grant = make_ref()

        evidence =
          plan_evidence(
            pending.plan,
            operation,
            pending.phase,
            pending.authorization_context
          )

        timer = Process.send_after(self(), {:expire_grant, grant}, pending.grant_ttl)

        operation_builder = %{
          operation
          | action_policy: Map.put(policy, :authorization_grant, grant)
        }

        {{:ok, %{pending.plan | operation_builder: operation_builder}, decision, grant},
         Map.put(grants, grant, %{evidence: evidence, timer: timer})}

      nil ->
        grant = make_ref()

        evidence =
          plan_evidence(
            pending.plan,
            nil,
            pending.phase,
            pending.authorization_context
          )

        timer = Process.send_after(self(), {:expire_grant, grant}, pending.grant_ttl)

        {{:ok, %{pending.plan | authorization_grant: grant}, decision, grant},
         Map.put(grants, grant, %{evidence: evidence, timer: timer})}

      _other ->
        {{:ok, pending.plan, decision, nil}, grants}
    end
  end

  defp authorization_reply(_pending, {:error, _reason} = error, grants),
    do: {error, grants}

  defp pop_pending(state, request_ref) do
    {pending, remaining} = Map.pop(state.pending, request_ref)
    {pending, %{state | pending: remaining}}
  end

  defp pending_by_monitor(pending, monitor) do
    Enum.find(pending, fn {_request_ref, entry} -> entry.monitor == monitor end)
  end

  defp cancel_pending(pending) do
    Process.cancel_timer(pending.timer)
    Process.demonitor(pending.monitor, [:flush])
  end

  defp resolver_timeout(opts) do
    opts
    |> Keyword.get(:capability_resolver_timeout, @default_resolver_timeout)
    |> bounded_timeout(@default_resolver_timeout, @max_resolver_timeout)
  end

  defp grant_ttl(opts) do
    opts
    |> Keyword.get(:action_authorization_grant_ttl, @default_grant_ttl)
    |> bounded_timeout(@default_grant_ttl, @max_grant_ttl)
  end

  defp planned_operation_ttl(value),
    do: bounded_timeout(value, @default_planned_operation_ttl, @max_planned_operation_ttl)

  defp bounded_timeout(value, _default, maximum) when is_integer(value) and value > 0,
    do: min(value, maximum)

  defp bounded_timeout(_value, default, _maximum), do: default

  defp safe_call(message, timeout, fallback) do
    try do
      GenServer.call(@server, message, timeout)
    catch
      :exit, _reason -> fallback
    end
  end

  defp unavailable_error do
    {:error,
     {:validation_error, "Action authorization service is unavailable.",
      %{code: :action_authorization_unavailable}}}
  end

  defp resolver_exception_error(plan, phase, kind, reason) do
    {:error,
     {:validation_error, "Capability resolver failed while authorizing the action.",
      %{
        code: :capability_resolver_exception,
        action: plan.action,
        capability: plan.capability,
        phase: phase,
        exception_kind: kind,
        reason: reason
      }}}
  end

  defp resolver_timeout_error(plan, phase) do
    {:error,
     {:validation_error, "Capability resolver timed out while authorizing the action.",
      %{
        code: :capability_resolver_timeout,
        action: plan.action,
        capability: plan.capability,
        phase: phase
      }}}
  end

  defp resolver_failure_error(plan, phase, reason) do
    resolver_exception_error(plan, phase, :exit, inspect(reason, limit: 20))
  end

  defp seal_candidate(%ActionPlan{operation_builder: nil} = plan) do
    {:ok, plan, nil}
  end

  defp seal_candidate(%ActionPlan{operation_builder: %Operation{} = operation} = plan) do
    stored_plan = %{plan | operation_builder: nil}

    case validate_operation_policy(stored_plan, operation) do
      :ok -> {:ok, stored_plan, operation}
      {:error, _reason} = error -> error
    end
  end

  defp seal_candidate(%ActionPlan{}) do
    invalid_planned_operation_error(:invalid_planned_operation)
  end

  defp validate_registered_plan(plan, stored_plan, operation) do
    if %{plan | operation_builder: nil} == stored_plan and
         valid_operation_policy?(stored_plan, operation) do
      :ok
    else
      {:error,
       {:validation_error, "Planned action builder does not match its domain policy.",
        %{
          code: :action_policy_mismatch,
          action: stored_plan.action,
          capability: stored_plan.capability
        }}}
    end
  end

  defp valid_operation_policy?(_stored_plan, nil), do: true

  defp valid_operation_policy?(stored_plan, %Operation{} = operation) do
    validate_operation_policy(stored_plan, operation) == :ok
  end

  defp validate_operation_policy(
         stored_plan,
         %Operation{action_policy: policy} = operation
       )
       when is_map(policy) do
    if same_identifier?(policy[:action], stored_plan.action) and
         same_identifier?(policy[:capability], stored_plan.capability) and
         policy[:operation] == operation.type do
      :ok
    else
      invalid_planned_operation_error(:action_policy_mismatch)
    end
  end

  defp validate_operation_policy(_stored_plan, %Operation{}) do
    invalid_planned_operation_error(:missing_action_policy)
  end

  defp plan_evidence(plan, %Operation{} = operation, phase, authorization_context) do
    %{
      action: plan.action,
      capability: plan.capability,
      operation: operation.type,
      operation_fingerprint: operation_fingerprint(operation),
      phase: phase,
      authorization_context: authorization_context
    }
  end

  defp plan_evidence(plan, nil, phase, authorization_context) do
    %{
      action: plan.action,
      capability: plan.capability,
      plan_fingerprint: plan_fingerprint(plan),
      phase: phase,
      authorization_context: authorization_context
    }
  end

  defp plan_fingerprint(%ActionPlan{} = plan) do
    plan
    |> Map.from_struct()
    |> Map.put(:operation_builder, nil)
    |> Map.put(:authorization_grant, nil)
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp validate_plan_authorization(%ActionPlan{} = plan, phase, context) do
    authorization = map_value(context, :action_authorization)
    grant = plan.authorization_grant

    cond do
      not is_nil(plan.operation_builder) ->
        authorization_error(:invalid_contract_action_plan)

      not is_map(authorization) ->
        authorization_error(:missing_action_authorization)

      is_nil(grant) or map_value(authorization, :authorization_grant) != grant ->
        authorization_error(:action_authorization_mismatch)

      normalize_status(map_value(authorization, :status)) != :enabled ->
        authorization_error(:action_authorization_denied)

      not same_identifier?(map_value(authorization, :action), plan.action) ->
        authorization_error(:action_authorization_mismatch)

      not same_identifier?(map_value(authorization, :capability), plan.capability) ->
        authorization_error(:action_authorization_mismatch)

      normalize_phase(map_value(authorization, :phase)) != phase ->
        authorization_error(:action_authorization_phase_mismatch)

      true ->
        validate_plan_capability_decision(plan, context)
    end
  end

  defp validate_plan_capability_decision(%ActionPlan{capability: nil}, _context), do: :ok

  defp validate_plan_capability_decision(%ActionPlan{} = plan, context) do
    decision = map_value(context, :capability_decision)

    if is_map(decision) and normalize_status(map_value(decision, :status)) == :enabled and
         same_identifier?(map_value(decision, :capability), plan.capability) do
      :ok
    else
      authorization_error(:action_capability_evidence_mismatch)
    end
  end

  defp normalize_status(value) when value in [:enabled, "enabled"], do: :enabled
  defp normalize_status(value) when value in [:denied, "denied"], do: :denied
  defp normalize_status(value), do: value

  defp normalize_phase(value) when value in [:preview, "preview"], do: :preview
  defp normalize_phase(value) when value in [:execute, "execute"], do: :execute
  defp normalize_phase(value), do: value

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key)))

  defp validate_identity_sources(context, opts) do
    conflicts =
      for {field, sources} <- [
            actor: actor_identity_sources(context, opts),
            tenant: tenant_identity_sources(context, opts)
          ],
          conflicting_sources?(sources),
          do: field

    case conflicts do
      [] ->
        :ok

      fields ->
        {:error,
         {:validation_error, "Authorization identity sources do not agree.",
          %{code: :authorization_context_mismatch, fields: fields}}}
    end
  end

  defp actor_identity_sources(context, opts) do
    (context_value_sources(context, :actor) ++ opts_value_sources(opts, :actor))
    |> Enum.map(fn {source, actor} -> {source, normalize_actor_identity(actor)} end)
    |> reject_nil_identity_sources()
  end

  defp tenant_identity_sources(context, opts) do
    (tenant_sources(
       context_value_sources(context, :tenant),
       context_value_sources(context, :tenant_id),
       context_value_sources(context, :tenant_field)
     ) ++
       tenant_sources(
         opts_value_sources(opts, :tenant),
         opts_value_sources(opts, :tenant_id),
         opts_value_sources(opts, :tenant_field)
       ))
    |> reject_nil_identity_sources()
  end

  defp tenant_sources(tenant_sources, tenant_id_sources, tenant_field_sources) do
    tenant_field_sources =
      case reject_nil_identity_sources(tenant_field_sources) do
        [] -> [{{:tenant_field, :default}, nil}]
        sources -> sources
      end

    normalized_tenants =
      for {tenant_source, tenant} <- tenant_sources,
          {field_source, tenant_field} <- tenant_field_sources do
        {{tenant_source, field_source}, normalize_tenant_identity(tenant, tenant_field)}
      end

    normalized_ids =
      for {tenant_source, tenant_id} <- tenant_id_sources,
          {field_source, tenant_field} <- tenant_field_sources do
        {{tenant_source, field_source}, normalize_tenant_id(tenant_id, tenant_field)}
      end

    normalized_tenants ++ normalized_ids
  end

  defp normalize_tenant_identity(nil, _fallback_field), do: nil

  defp normalize_tenant_identity(tenant, fallback_field) do
    case Tenant.normalize_context(tenant) do
      %{tenant_identity_conflicts: conflicts} when conflicts != [] ->
        {:conflicting_tenant_identity, conflicts}

      %{tenant_id: tenant_id} = normalized when not is_nil(tenant_id) ->
        nested_field = normalize_tenant_field(normalized[:tenant_field])
        outer_field = normalize_tenant_field(fallback_field)

        if explicit_tenant_field?(tenant) and not is_nil(fallback_field) and
             nested_field != outer_field do
          {:conflicting_tenant_field, nested_field, outer_field}
        else
          %{
            tenant_id: tenant_id,
            tenant_field: if(is_nil(fallback_field), do: nested_field, else: outer_field)
          }
        end

      _other ->
        normalize_tenant_id(tenant, fallback_field)
    end
  end

  defp normalize_tenant_id(nil, _field), do: nil

  defp normalize_tenant_id(tenant_id, field) do
    %{tenant_id: tenant_id, tenant_field: normalize_tenant_field(field)}
  end

  defp normalize_actor_identity(nil), do: nil

  defp normalize_actor_identity(actor) when is_map(actor) do
    id_sources =
      [
        {:atom, Map.get(actor, :id)},
        {:string, Map.get(actor, "id")}
      ]
      |> Enum.reject(fn {_source, id} -> is_nil(id) end)

    case id_sources |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [] ->
        actor

      [id] ->
        actor
        |> Map.drop([:id, "id"])
        |> Map.put(:id, id)

      _ids ->
        {:conflicting_actor_identity, id_sources}
    end
  end

  defp normalize_actor_identity(actor), do: actor

  defp explicit_tenant_field?(tenant) when is_map(tenant),
    do: Map.has_key?(tenant, :tenant_field) or Map.has_key?(tenant, "tenant_field")

  defp explicit_tenant_field?(tenant) when is_list(tenant),
    do: Keyword.has_key?(tenant, :tenant_field)

  defp explicit_tenant_field?(_tenant), do: false

  defp normalize_tenant_field(nil), do: "tenant_id"
  defp normalize_tenant_field(field) when is_atom(field), do: Atom.to_string(field)
  defp normalize_tenant_field(field) when is_binary(field), do: field
  defp normalize_tenant_field(field), do: to_string(field)

  defp reject_nil_identity_sources(sources),
    do: Enum.reject(sources, fn {_source, identity} -> is_nil(identity) end)

  defp context_value_sources(context, key) do
    [
      {{:context, key, :atom}, Map.get(context, key)},
      {{:context, key, :string}, Map.get(context, Atom.to_string(key))}
    ]
  end

  defp opts_value_sources(opts, key) do
    opts
    |> Keyword.get_values(key)
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> {{:opts, key, index}, value} end)
  end

  defp conflicting_sources?(sources) do
    Enum.any?(sources, fn
      {_source, {:conflicting_tenant_identity, _conflicts}} -> true
      {_source, {:conflicting_tenant_field, _nested, _outer}} -> true
      {_source, {:conflicting_actor_identity, _sources}} -> true
      _source -> false
    end) or
      sources
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> length() > 1
  end

  defp identity_fingerprint([]), do: nil

  defp identity_fingerprint(sources) do
    sources
    |> List.first()
    |> elem(1)
  end

  defp invalid_planned_operation_error(code) do
    {:error,
     {:validation_error, "Action plan does not contain a registered opaque planned operation.",
      %{code: code}}}
  end

  defp authorization_error(code) do
    {:error,
     Error.new(:authorization, "Planned action authorization grant is invalid or expired",
       details: %{code: code}
     )}
  end

  defp same_identifier?(nil, nil), do: true

  defp same_identifier?(left, right)
       when (is_atom(left) or is_binary(left)) and (is_atom(right) or is_binary(right)),
       do: to_string(left) == to_string(right)

  defp same_identifier?(left, right), do: left == right
end
