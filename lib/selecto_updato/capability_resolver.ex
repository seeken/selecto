defmodule SelectoUpdato.CapabilityResolver do
  @moduledoc """
  Host-owned policy boundary for capability-gated Updato actions.

  Core Updato plans actions and validates write contracts, but host apps own
  actor policy, role membership, tenant rules, and explanation detail. This
  behavior lets generated APIs and adapters ask the host whether a planned
  action phase is `:enabled`, `:disabled`, or `:hidden`.
  """

  alias SelectoUpdato.{ActionPlan, CapabilityDecision}

  @type phase :: :preview | :execute
  @type request :: %{
          required(:phase) => phase(),
          required(:capability) => term(),
          required(:action) => String.t() | nil,
          required(:operation) => String.t() | nil,
          required(:scope) => String.t() | nil,
          required(:target) => term(),
          required(:filters) => [term()] | nil,
          required(:transition) => map() | nil,
          required(:preconditions) => [map()] | nil,
          required(:collection_operations) => map() | nil
        }
  @type context :: map()
  @type decision :: CapabilityDecision.t() | :enabled | :disabled | :hidden | boolean() | map()
  @type result :: {:ok, decision()} | {:error, term()} | decision()

  @callback decide(request(), context(), keyword()) :: result()

  @doc """
  Authorizes an action plan phase.

  If the plan has no capability, it is allowed without consulting a resolver.
  If a capability exists, callers must provide a resolver through
  `:capability_resolver` in opts or context. Sensitive action phases fail closed
  when no resolver is present.
  """
  @spec authorize_action(ActionPlan.t(), phase(), context(), keyword()) ::
          {:ok, CapabilityDecision.t()} | {:error, term()}
  def authorize_action(%ActionPlan{} = plan, phase, context, opts \\ [])
      when phase in [:preview, :execute] do
    capability = plan.capability

    cond do
      is_nil(capability) ->
        CapabilityDecision.normalize(:enabled, nil)

      resolver = resolver(context, opts) ->
        plan
        |> action_request(phase)
        |> call_resolver(resolver, context, opts)
        |> normalize_result(capability)

      true ->
        denied(
          :missing_capability_resolver,
          "Action #{phase} requires a host capability resolver.",
          capability,
          phase
        )
    end
  end

  @doc """
  Returns a JSON-friendly request map for policy resolvers and logs.
  """
  @spec action_request(ActionPlan.t(), phase()) :: request()
  def action_request(%ActionPlan{} = plan, phase) when phase in [:preview, :execute] do
    %{
      phase: phase,
      capability: plan.capability,
      action: plan.action,
      operation: plan.operation,
      scope: plan.scope,
      target: plan.target,
      filters: plan.filters,
      transition: plan.transition,
      preconditions: plan.preconditions,
      collection_operations: plan.collection_operations
    }
  end

  defp call_resolver(request, resolver, context, opts) when is_atom(resolver) do
    if Code.ensure_loaded?(resolver) and function_exported?(resolver, :decide, 3) do
      resolver.decide(request, context, opts)
    else
      {:error,
       {:validation_error, "Capability resolver does not support decide/3.",
        %{
          code: :unsupported_capability_resolver,
          resolver: inspect(resolver),
          callback: :decide
        }}}
    end
  end

  defp call_resolver(request, resolver, context, opts) when is_function(resolver, 3) do
    resolver.(request, context, opts)
  end

  defp call_resolver(request, resolver, context, _opts) when is_function(resolver, 2) do
    resolver.(request, context)
  end

  defp call_resolver(_request, resolver, _context, _opts) do
    {:error,
     {:validation_error, "Capability resolver must be a module or function.",
      %{
        code: :invalid_capability_resolver,
        resolver: inspect(resolver)
      }}}
  end

  defp normalize_result({:ok, decision}, capability), do: normalize_result(decision, capability)
  defp normalize_result({:error, reason}, _capability), do: {:error, reason}

  defp normalize_result(decision, capability) do
    case CapabilityDecision.normalize(decision, capability) do
      {:ok, %CapabilityDecision{status: :enabled} = normalized} ->
        {:ok, normalized}

      {:ok, %CapabilityDecision{} = normalized} ->
        denied(normalized)

      {:error, reason} ->
        {:error,
         {:validation_error, "Capability resolver returned an invalid decision.",
          %{
            code: :invalid_capability_decision,
            reason: inspect(reason)
          }}}
    end
  end

  defp denied(%CapabilityDecision{} = decision) do
    {:error,
     {:validation_error, decision.reason || "Action capability denied.",
      %{
        code: decision.code || :action_capability_denied,
        status: decision.status,
        capability: decision.capability,
        reason: decision.reason,
        audit: decision.audit,
        metadata: decision.metadata
      }}}
  end

  defp denied(code, message, capability, phase) do
    {:error,
     {:validation_error, message,
      %{
        code: code,
        status: :hidden,
        phase: phase,
        capability: capability
      }}}
  end

  defp resolver(context, opts) do
    keyword_value(opts, :capability_resolver) ||
      map_value(context, :capability_resolver)
  end

  defp keyword_value(opts, key) when is_list(opts) and is_atom(key) do
    Keyword.get(opts, key)
  end

  defp keyword_value(_opts, _key), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp map_value(_map, _key), do: nil
end
