defmodule SelectoUpdato.CapabilityResolverTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.{ActionPlan, CapabilityDecision, CapabilityResolver}

  defmodule ModuleResolver do
    @behaviour CapabilityResolver

    @impl true
    def decide(%{phase: :preview} = request, _context, _opts) do
      {:ok,
       %CapabilityDecision{
         status: :enabled,
         capability: request.capability,
         reason: "Preview allowed"
       }}
    end
  end

  test "allows action plans without capabilities" do
    assert {:ok, %CapabilityDecision{status: :enabled, capability: nil}} =
             CapabilityResolver.authorize_action(%ActionPlan{}, :execute, %{})
  end

  test "uses module resolvers to authorize preview requests" do
    plan = %ActionPlan{
      action: "approve",
      capability: "orders.approve",
      operation: "update",
      scope: "row",
      target: %{id: 123},
      filters: [{"id", 123}]
    }

    assert {:ok, decision} =
             CapabilityResolver.authorize_action(plan, :preview, %{},
               capability_resolver: ModuleResolver
             )

    assert decision.status == :enabled
    assert decision.capability == "orders.approve"
    assert decision.reason == "Preview allowed"
  end

  test "normalizes function resolver denial into validation error details" do
    resolver = fn request, _context ->
      %{
        status: :disabled,
        capability: request.capability,
        reason: "Approval window is closed.",
        code: :approval_window_closed,
        metadata: %{retryable: false}
      }
    end

    assert {:error, {:validation_error, message, details}} =
             CapabilityResolver.authorize_action(
               %ActionPlan{action: "approve", capability: "orders.approve"},
               :execute,
               %{},
               capability_resolver: resolver
             )

    assert message == "Approval window is closed."
    assert details.code == :approval_window_closed
    assert details.status == :disabled
    assert details.metadata == %{retryable: false}
  end
end
