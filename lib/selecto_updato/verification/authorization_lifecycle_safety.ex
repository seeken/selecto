defmodule SelectoUpdato.Verification.AuthorizationLifecycleSafety do
  @moduledoc """
  Bounded event-trace verification of the planned-action authorization protocol.

  This finite reference model crosses full and contract-only plans, both action
  phases, two actors, two tenants, and enabled, denied, timed-out, crashed, and
  delayed resolver outcomes. It then explores handle expiry, resolver delivery,
  grant consumption and replay, context substitution, revocation, and service
  restart in every reachable order up to the declared depth.

  Runtime conformance tests exercise the concrete GenServer, timers, monitored
  resolver processes, and portable compiler. This model proves the protocol
  invariants independently of scheduler timing; it does not prove arbitrary
  host adapter callbacks.
  """

  alias Selecto.Verification.BoundedTraceModel

  @plan_kinds [:full, :contract_only]
  @phases [:preview, :execute]
  @subjects [:actor_a, :actor_b]
  @tenants [:tenant_a, :tenant_b]
  @resolver_outcomes [:enabled, :denied, :timeout, :crash, :delayed]
  @identity_sources [
    :context,
    :opts,
    :both_same,
    :actor_conflict,
    :tenant_conflict,
    :context_internal_tenant_conflict,
    :opts_internal_tenant_conflict,
    :context_actor_spelling_conflict,
    :context_tenant_spelling_conflict,
    :context_tenant_id_spelling_conflict,
    :actor_id_spelling_conflict,
    :nested_outer_tenant_field_conflict
  ]

  @spec verify() :: BoundedTraceModel.report()
  def verify do
    BoundedTraceModel.check(
      "selecto_updato.authorization_lifecycle.v1",
      initial_states(),
      events(),
      invariants(),
      max_depth: 6
    )
  end

  defp initial_states do
    for plan_kind <- @plan_kinds,
        phase <- @phases,
        actor <- @subjects,
        tenant <- @tenants,
        resolver <- @resolver_outcomes,
        identity_source <- @identity_sources do
      %{
        plan_kind: plan_kind,
        phase: phase,
        actor: actor,
        tenant: tenant,
        resolver: resolver,
        identity_source: identity_source,
        stage: :unsealed,
        handle_registered?: false,
        provenance_valid_at_authorization?: false,
        materialized_operation?: false,
        authorization_outcome: nil,
        grant_status: :none,
        grant_binding: nil,
        successful_consumes: 0,
        rejected_consumes: 0,
        rejected_authorizations: 0,
        late_reply_ignored?: false,
        replay_attempted?: false,
        service_restarted?: false
      }
    end
  end

  defp events do
    [
      {:seal, &seal/1},
      {:expire_handle, &expire_handle/1},
      {:authorize, &authorize/1},
      {:resolver_reply, &resolver_reply/1},
      {:resolver_timeout, &resolver_timeout/1},
      {:late_resolver_reply, &late_resolver_reply/1},
      {:consume_matching_context, &consume_matching_context/1},
      {:consume_other_actor, &consume_other_actor/1},
      {:consume_other_tenant, &consume_other_tenant/1},
      {:consume_ambiguous_actor_keys, &consume_ambiguous_actor_keys/1},
      {:consume_ambiguous_tenant_keys, &consume_ambiguous_tenant_keys/1},
      {:consume_other_phase, &consume_other_phase/1},
      {:replay, &replay/1},
      {:expire_grant, &expire_grant/1},
      {:revoke_grant, &revoke_grant/1},
      {:restart_service, &restart_service/1},
      {:authorize_invalidated_handle, &authorize_invalidated_handle/1}
    ]
  end

  defp invariants do
    [
      {"authority_requires_registered_immutable_provenance", &authority_requires_provenance/1},
      {"resolver_failures_and_late_replies_fail_closed", &resolver_failures_fail_closed/1},
      {"grants_are_phase_subject_tenant_bound_and_single_use", &grant_is_bound_and_linear/1},
      {"context_and_opts_identity_sources_must_agree", &identity_sources_agree/1},
      {"expiry_revocation_and_restart_are_monotonic", &invalidation_is_monotonic/1},
      {"contract_only_plans_never_materialize_operations", &contract_only_never_materializes/1}
    ]
  end

  defp seal(%{stage: :unsealed} = state) do
    {:next, %{state | stage: :sealed, handle_registered?: true}}
  end

  defp seal(_state), do: :disabled

  defp expire_handle(%{stage: :sealed, handle_registered?: true} = state) do
    {:next, %{state | stage: :handle_expired, handle_registered?: false}}
  end

  defp expire_handle(_state), do: :disabled

  defp authorize(%{stage: :sealed, handle_registered?: true, identity_source: source} = state)
       when source in [
              :actor_conflict,
              :tenant_conflict,
              :context_internal_tenant_conflict,
              :opts_internal_tenant_conflict,
              :context_actor_spelling_conflict,
              :context_tenant_spelling_conflict,
              :context_tenant_id_spelling_conflict,
              :actor_id_spelling_conflict,
              :nested_outer_tenant_field_conflict
            ] do
    {:next,
     %{
       state
       | stage: :authorization_rejected,
         authorization_outcome: :identity_conflict,
         rejected_authorizations: state.rejected_authorizations + 1
     }}
  end

  defp authorize(%{stage: :sealed, handle_registered?: true, resolver: :enabled} = state),
    do: {:next, authorize_success(state)}

  defp authorize(%{stage: :sealed, handle_registered?: true, resolver: :delayed} = state),
    do: {:next, %{state | stage: :resolver_pending}}

  defp authorize(%{stage: :sealed, handle_registered?: true} = state)
       when state.resolver in [:denied, :timeout, :crash] do
    {:next,
     %{
       state
       | stage: :authorization_rejected,
         authorization_outcome: state.resolver,
         rejected_authorizations: state.rejected_authorizations + 1
     }}
  end

  defp authorize(_state), do: :disabled

  defp resolver_reply(%{stage: :resolver_pending, resolver: :delayed} = state),
    do: {:next, authorize_success(state), %{delivery: :before_timeout}}

  defp resolver_reply(_state), do: :disabled

  defp resolver_timeout(%{stage: :resolver_pending} = state) do
    {:next,
     %{
       state
       | stage: :authorization_rejected,
         authorization_outcome: :timeout,
         rejected_authorizations: state.rejected_authorizations + 1
     }}
  end

  defp resolver_timeout(_state), do: :disabled

  defp late_resolver_reply(
         %{
           stage: :authorization_rejected,
           authorization_outcome: :timeout,
           late_reply_ignored?: false
         } = state
       ) do
    {:next, %{state | late_reply_ignored?: true}, %{delivery: :after_timeout, outcome: :ignored}}
  end

  defp late_resolver_reply(_state), do: :disabled

  defp consume_matching_context(%{grant_status: :live} = state) do
    {:next,
     %{
       state
       | stage: :consumed,
         grant_status: :consumed,
         successful_consumes: state.successful_consumes + 1
     }}
  end

  defp consume_matching_context(_state), do: :disabled

  defp consume_other_actor(%{grant_status: :live} = state),
    do: {:next, reject_context_substitution(state, :actor)}

  defp consume_other_actor(_state), do: :disabled

  defp consume_other_tenant(%{grant_status: :live} = state),
    do: {:next, reject_context_substitution(state, :tenant)}

  defp consume_other_tenant(_state), do: :disabled

  defp consume_ambiguous_actor_keys(%{grant_status: :live} = state),
    do: {:next, reject_context_substitution(state, :ambiguous_actor_keys)}

  defp consume_ambiguous_actor_keys(_state), do: :disabled

  defp consume_ambiguous_tenant_keys(%{grant_status: :live} = state),
    do: {:next, reject_context_substitution(state, :ambiguous_tenant_keys)}

  defp consume_ambiguous_tenant_keys(_state), do: :disabled

  defp consume_other_phase(%{grant_status: :live} = state),
    do: {:next, reject_context_substitution(state, :phase)}

  defp consume_other_phase(_state), do: :disabled

  defp replay(%{grant_status: status, replay_attempted?: false} = state)
       when status in [:consumed, :context_invalidated, :expired, :revoked, :restart_invalidated] do
    {:next,
     %{
       state
       | replay_attempted?: true,
         rejected_consumes: state.rejected_consumes + 1
     }}
  end

  defp replay(_state), do: :disabled

  defp expire_grant(%{grant_status: :live} = state),
    do: {:next, %{state | stage: :grant_expired, grant_status: :expired}}

  defp expire_grant(_state), do: :disabled

  defp revoke_grant(%{grant_status: :live} = state),
    do: {:next, %{state | stage: :grant_revoked, grant_status: :revoked}}

  defp revoke_grant(_state), do: :disabled

  defp restart_service(%{service_restarted?: false} = state) do
    grant_status =
      if state.grant_status == :live, do: :restart_invalidated, else: state.grant_status

    {:next,
     %{
       state
       | stage: :service_restarted,
         handle_registered?: false,
         grant_status: grant_status,
         service_restarted?: true
     }}
  end

  defp restart_service(_state), do: :disabled

  defp authorize_invalidated_handle(%{stage: stage} = state)
       when stage in [:handle_expired, :service_restarted] do
    {:next,
     %{
       state
       | stage: :invalidated_authorization_rejected,
         rejected_authorizations: state.rejected_authorizations + 1
     }}
  end

  defp authorize_invalidated_handle(_state), do: :disabled

  defp authorize_success(state) do
    full? = state.plan_kind == :full

    %{
      state
      | stage: :authorized,
        provenance_valid_at_authorization?: true,
        materialized_operation?: full?,
        authorization_outcome: :enabled,
        grant_status: if(full?, do: :live, else: :none),
        grant_binding: if(full?, do: grant_binding(state), else: nil)
    }
  end

  defp reject_context_substitution(state, substituted) do
    %{
      state
      | stage: :context_substitution_rejected,
        grant_status: :context_invalidated,
        rejected_consumes: state.rejected_consumes + 1,
        replay_attempted?: false
    }
    |> Map.put(:last_substitution, substituted)
  end

  defp grant_binding(state) do
    %{actor: state.actor, tenant: state.tenant, phase: state.phase, operation: :update}
  end

  defp authority_requires_provenance(state) do
    active? = state.materialized_operation? and state.grant_status == :live

    if not active? or
         (state.plan_kind == :full and state.authorization_outcome == :enabled and
            state.provenance_valid_at_authorization?),
       do: :ok,
       else: {:error, %{authority_without_provenance: state}}
  end

  defp resolver_failures_fail_closed(state) do
    failed? = state.authorization_outcome in [:denied, :timeout, :crash]

    if not failed? or (not state.materialized_operation? and state.grant_status == :none),
      do: :ok,
      else: {:error, %{resolver_failure_granted_authority: state}}
  end

  defp grant_is_bound_and_linear(state) do
    grant_seen? = state.grant_status != :none
    binding_valid? = not grant_seen? or state.grant_binding == grant_binding(state)

    if binding_valid? and state.successful_consumes <= 1,
      do: :ok,
      else: {:error, %{invalid_grant_binding_or_replay: state}}
  end

  defp invalidation_is_monotonic(state) do
    invalidated? =
      state.grant_status in [
        :consumed,
        :context_invalidated,
        :expired,
        :revoked,
        :restart_invalidated
      ]

    if not invalidated? or state.successful_consumes <= 1,
      do: :ok,
      else: {:error, %{invalidated_grant_reactivated: state}}
  end

  defp identity_sources_agree(state) do
    conflict? =
      state.identity_source in [
        :actor_conflict,
        :tenant_conflict,
        :context_internal_tenant_conflict,
        :opts_internal_tenant_conflict,
        :context_actor_spelling_conflict,
        :context_tenant_spelling_conflict,
        :context_tenant_id_spelling_conflict,
        :actor_id_spelling_conflict,
        :nested_outer_tenant_field_conflict
      ]

    if not conflict? or
         (state.authorization_outcome in [nil, :identity_conflict] and
            not state.materialized_operation? and state.grant_status == :none),
       do: :ok,
       else: {:error, %{conflicting_identity_granted_authority: state}}
  end

  defp contract_only_never_materializes(%{plan_kind: :contract_only} = state) do
    if not state.materialized_operation? and state.grant_status == :none,
      do: :ok,
      else: {:error, %{contract_only_authority: state}}
  end

  defp contract_only_never_materializes(_state), do: :ok
end
