defmodule SelectoUpdato.ActionExecutionAdapter do
  @moduledoc """
  Host-owned execution boundary for planned domain actions.

  `SelectoUpdato.ActionPlanner` can produce a safe, non-executing action plan.
  Applying plans with collection operations requires application context that
  core Updato must not guess: actor authorization, tenant scoping, parent row
  loading, and relationship ownership checks. This module defines the adapter
  boundary for host apps to supply that behavior explicitly.
  """

  alias SelectoUpdato.{ActionAuthorization, ActionPlan}

  @type context :: map()
  @type result :: {:ok, term()} | {:error, term()}
  @type resolution :: {:ok, module()} | {:error, term()} | :none

  @callback execute_action(ActionPlan.t(), context(), keyword()) :: result()
  @callback dry_run_action(ActionPlan.t(), context(), keyword()) :: result()

  @optional_callbacks dry_run_action: 3

  @doc """
  Resolve an action execution adapter from generated API config.

  Host apps provide `:action_execution_adapter` directly. Resolution never
  inspects an Ecto repository or application persistence configuration.
  """
  @spec for_config(map()) :: resolution()
  def for_config(%{} = config) do
    case map_value(config, :action_execution_adapter) do
      nil -> :none
      adapter -> validate_adapter(adapter)
    end
  end

  def for_config(_config), do: :none

  @doc """
  Execute a planned action through a host-provided adapter.

  For domain-backed actions, the adapter receives an authorized plan whose
  `operation_builder` is an executable `%SelectoUpdato.Operation{}` plus
  phase-bound `:action_authorization` evidence. Contract-only plans retain a
  `nil` operation builder but require the same registered provenance and
  authorization. Before authorization, action plans contain only an opaque
  planned-operation handle that raw write APIs cannot accept.
  Hosts that execute the authorized builder through `SelectoUpdato.execute/3`
  must pass this context through unchanged.
  """
  @spec execute(module(), ActionPlan.t(), context(), keyword()) :: result()
  def execute(adapter, plan, context, opts \\ [])

  def execute(adapter, %ActionPlan{} = plan, context, opts) when is_atom(adapter) do
    with :ok <- ensure_adapter_callback(adapter, :execute_action),
         {:ok, authorized_plan, decision, grant} <-
           ActionAuthorization.authorize_and_issue(plan, :execute, context, opts) do
      invoke_adapter(
        adapter,
        :execute_action,
        authorized_plan,
        put_action_context(context, authorized_plan, :execute, decision, opts),
        opts,
        grant
      )
    end
  end

  def execute(adapter, %ActionPlan{}, _context, _opts) do
    invalid_adapter(adapter)
  end

  @doc """
  Dry-run a planned action through a host-provided adapter.
  """
  @spec dry_run(module(), ActionPlan.t(), context(), keyword()) :: result()
  def dry_run(adapter, plan, context, opts \\ [])

  def dry_run(adapter, %ActionPlan{} = plan, context, opts) when is_atom(adapter) do
    with :ok <- ensure_adapter_callback(adapter, :dry_run_action),
         {:ok, authorized_plan, decision, grant} <-
           ActionAuthorization.authorize_and_issue(plan, :preview, context, opts) do
      invoke_adapter(
        adapter,
        :dry_run_action,
        authorized_plan,
        put_action_context(context, authorized_plan, :preview, decision, opts),
        opts,
        grant
      )
    end
  end

  def dry_run(adapter, %ActionPlan{}, _context, _opts) do
    invalid_adapter(adapter)
  end

  defp validate_adapter(adapter) when is_atom(adapter) do
    with :ok <- ensure_adapter_callback(adapter, :execute_action) do
      {:ok, adapter}
    end
  end

  defp validate_adapter(adapter), do: invalid_adapter(adapter)

  defp ensure_adapter_callback(adapter, callback) do
    if adapter_callback_exported?(adapter, callback) do
      :ok
    else
      unsupported(code_for_callback(callback), adapter, callback)
    end
  end

  defp invalid_adapter(adapter) do
    {:error,
     {:validation_error, "Action execution adapter must be a module.",
      %{
        code: :invalid_action_execution_adapter,
        adapter: inspect(adapter)
      }}}
  end

  defp unsupported(code, adapter, callback) do
    {:error,
     {:validation_error, "Action execution adapter does not support #{callback}.",
      %{
        code: code,
        adapter: inspect(adapter),
        callback: callback
      }}}
  end

  defp code_for_callback(:execute_action), do: :unsupported_action_execution_adapter
  defp code_for_callback(:dry_run_action), do: :unsupported_action_dry_run

  defp put_action_context(context, plan, phase, decision, opts) when is_map(context) do
    context
    |> put_authorized_identity(opts)
    |> put_capability_decision(decision)
    |> put_action_authorization(plan, phase, decision)
    |> maybe_put_action_audit(plan, phase, decision, opts)
  end

  defp put_authorized_identity(context, opts) do
    context
    |> maybe_put_identity(:actor, Keyword.get(opts, :actor))
    |> maybe_put_identity(:tenant, Keyword.get(opts, :tenant))
    |> maybe_put_identity(:tenant_id, Keyword.get(opts, :tenant_id))
    |> maybe_put_identity(:tenant_field, Keyword.get(opts, :tenant_field))
  end

  defp maybe_put_identity(context, _key, nil), do: context

  defp maybe_put_identity(context, key, value) do
    if is_nil(map_value(context, key)), do: Map.put(context, key, value), else: context
  end

  defp put_capability_decision(context, %{capability: nil}), do: context

  defp put_capability_decision(context, decision) when is_map(context) do
    Map.put(context, :capability_decision, SelectoUpdato.CapabilityDecision.to_map(decision))
  end

  defp put_action_authorization(context, %ActionPlan{} = plan, phase, decision) do
    decision = SelectoUpdato.CapabilityDecision.to_map(decision)

    Map.put(context, :action_authorization, %{
      action: plan.action,
      capability: plan.capability,
      phase: phase,
      status: decision.status,
      authorization_grant: action_authorization_grant(plan)
    })
  end

  defp action_authorization_grant(%ActionPlan{operation_builder: %{action_policy: policy}})
       when is_map(policy) do
    map_value(policy, :authorization_grant)
  end

  defp action_authorization_grant(%ActionPlan{} = plan), do: plan.authorization_grant

  defp invoke_adapter(adapter, callback, plan, context, opts, grant) do
    try do
      apply(adapter, callback, [plan, context, opts])
    after
      ActionAuthorization.revoke(grant)
    end
  end

  defp maybe_put_action_audit(context, %ActionPlan{} = plan, phase, decision, opts) do
    if empty_audit?(plan.audit) do
      context
    else
      Map.put(context, :action_audit, action_audit_envelope(plan, phase, context, decision, opts))
    end
  end

  defp action_audit_envelope(%ActionPlan{} = plan, phase, context, decision, opts) do
    audit = map_or_empty(plan.audit)

    %{
      event: map_value(audit, :event),
      phase: phase,
      action: plan.action,
      capability: plan.capability,
      actor:
        audit_subject(
          audit_value(
            audit,
            :include_actor,
            map_value(context, :actor) || Keyword.get(opts, :actor)
          )
        ),
      tenant:
        audit_subject(
          audit_value(
            audit,
            :include_tenant,
            map_value(context, :tenant) || Keyword.get(opts, :tenant)
          )
        ),
      target: json_safe(audit_value(audit, :include_target, plan.target)),
      inputs: json_safe(audit_value(audit, :include_inputs, plan.inputs)),
      capability_decision: capability_decision_for_audit(decision),
      preview_id:
        audit_value(
          audit,
          :include_preview_id,
          json_safe(map_value(context, :preview_id) || Keyword.get(opts, :preview_id))
        ),
      metadata: json_safe(map_value(audit, :metadata)),
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
    |> Map.new()
  end

  defp audit_value(audit, key, value) do
    if truthy?(map_value(audit, key)), do: value
  end

  defp audit_subject(nil), do: nil
  defp audit_subject(%{id: id}), do: %{id: json_safe(id)}
  defp audit_subject(%{"id" => id}), do: %{"id" => json_safe(id)}
  defp audit_subject(value), do: json_safe(value)

  defp capability_decision_for_audit(%{capability: nil}), do: nil

  defp capability_decision_for_audit(decision) do
    SelectoUpdato.CapabilityDecision.to_map(decision)
  end

  defp adapter_callback_exported?(adapter, callback) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, callback, 3)
  end

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp json_safe(value), do: SelectoUpdato.DomainContract.json_safe(value)

  defp empty_audit?(audit), do: audit in [nil, %{}]

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp truthy?(value), do: value in [true, "true", 1, "1", true]
end
