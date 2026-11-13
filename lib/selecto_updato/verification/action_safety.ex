defmodule SelectoUpdato.Verification.ActionSafety do
  @moduledoc """
  Bounded verification of action-plan and capability-boundary invariants.

  The model plans a synthetic but production-shaped transition action from the
  canonical Selecto example domain, then exhaustively checks preview and
  execution authorization under missing, enabled, disabled, and hidden policy
  decisions.
  """

  alias Selecto.Verification.BoundedModel
  alias SelectoUpdato.{CapabilityDecision, PlannedOperation}

  @phases [:preview, :execute]
  @resolver_decisions [:missing, :enabled, :disabled, :hidden]

  @doc """
  Runs the built-in action planning and authorization model.
  """
  @spec verify() :: BoundedModel.report()
  def verify do
    {:ok, plan} =
      SelectoUpdato.plan_domain_action(
        Selecto.Domain.Examples.work_items(),
        %{action: "archive", target: 7}
      )

    states =
      for phase <- @phases,
          resolver_decision <- @resolver_decisions do
        %{
          phase: phase,
          resolver_decision: resolver_decision,
          plan: plan,
          authorization: authorize(plan, phase, resolver_decision)
        }
      end

    BoundedModel.check("selecto_updato.action_capability.v1", states, invariants())
  end

  defp invariants do
    [
      {"plan_preserves_declared_capability", &plan_preserves_declared_capability/1},
      {"plan_preserves_write_boundary", &plan_preserves_write_boundary/1},
      {"transition_precondition_is_preserved", &transition_precondition_is_preserved/1},
      {"capability_authorization_fails_closed", &capability_authorization_fails_closed/1}
    ]
  end

  defp plan_preserves_declared_capability(state) do
    request = SelectoUpdato.CapabilityResolver.action_request(state.plan, state.phase)

    if state.plan.capability == "work_items.archive" and
         request.capability == state.plan.capability,
       do: :ok,
       else: {:error, %{plan: state.plan.capability, request: request.capability}}
  end

  defp plan_preserves_write_boundary(state) do
    plan = state.plan

    cond do
      plan.operation != "update" ->
        {:error, %{unexpected_operation: plan.operation}}

      plan.changes != %{state: "archived"} ->
        {:error, %{unexpected_changes: plan.changes}}

      {"id", 7} not in plan.filters ->
        {:error, %{target_filter_missing: plan.filters}}

      not match?(%PlannedOperation{}, plan.operation_builder) ->
        {:error, %{unexpected_builder: plan.operation_builder}}

      true ->
        :ok
    end
  end

  defp transition_precondition_is_preserved(state) do
    expected = %{type: :field_equals, field: "state", value: "done"}

    if Enum.any?(state.plan.preconditions, fn precondition ->
         Enum.all?(expected, fn {key, value} -> Map.get(precondition, key) == value end)
       end),
       do: :ok,
       else: {:error, %{missing_transition_precondition: state.plan.preconditions}}
  end

  defp capability_authorization_fails_closed(%{resolver_decision: :enabled} = state) do
    case state.authorization do
      {:ok, %CapabilityDecision{status: :enabled, capability: "work_items.archive"}} -> :ok
      other -> {:error, %{enabled_policy_not_honored: other}}
    end
  end

  defp capability_authorization_fails_closed(state) do
    case state.authorization do
      {:error, _reason} -> :ok
      other -> {:error, %{non_enabled_policy_was_allowed: other}}
    end
  end

  defp authorize(plan, phase, :missing) do
    SelectoUpdato.authorize_domain_action(plan, phase)
  end

  defp authorize(plan, phase, decision) do
    resolver = fn request, _context, _opts ->
      if request.capability == "work_items.archive", do: decision, else: :hidden
    end

    SelectoUpdato.authorize_domain_action(plan, phase, %{}, capability_resolver: resolver)
  end
end
