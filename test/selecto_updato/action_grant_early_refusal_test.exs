defmodule SelectoUpdato.ActionGrantEarlyRefusalTest do
  use ExUnit.Case, async: false
  alias SelectoUpdato.{ActionAuthorization, CapabilityDecision, Error, PortableCommand}

  test "early phase and evidence refusals invalidate authority before returning" do
    for {field, value, expected_code} <- [
          {:phase, :preview, :action_authorization_phase_mismatch},
          {:action, "other", :action_authorization_mismatch},
          {:capability, "other", :action_authorization_mismatch},
          {:status, :disabled, :action_authorization_denied}
        ],
        compiler <- [:compile, :compile_flat] do
      {operation, context} = authorized_operation()
      changed_context = put_in(context, [:action_authorization, field], value)

      assert {:error, %Error{type: :authorization, details: %{code: ^expected_code}}} =
               apply(PortableCommand, compiler, [
                 operation,
                 [context: changed_context, action_phase: :execute]
               ])

      assert {:error, %Error{details: %{code: :unregistered_action_authorization}}} =
               apply(PortableCommand, compiler, [
                 operation,
                 [context: context, action_phase: :execute]
               ])

      refute_receive :choice_callback_called
    end
  end

  test "operation-policy refusal and domain admission failure cannot leave a live grant" do
    for change <- [:operation, :domain], compiler <- [:compile, :compile_flat] do
      {operation, context} = authorized_operation()

      changed =
        case change do
          :operation -> %{operation | type: :delete}
          :domain -> %{operation | domain: %{}}
        end

      expected_type =
        if change == :domain, do: :invalid_domain, else: :write_operation_not_enabled

      assert {:error, %Error{type: ^expected_type}} =
               apply(PortableCommand, compiler, [
                 changed,
                 [context: context, action_phase: :execute]
               ])

      assert {:error, %Error{details: %{code: :unregistered_action_authorization}}} =
               apply(PortableCommand, compiler, [
                 operation,
                 [context: context, action_phase: :execute]
               ])

      refute_receive :choice_callback_called
    end
  end

  test "matching authority still compiles and callback validation receives exactly one attempt" do
    {operation, context} = authorized_operation()

    assert {:ok, %Selecto.Write.Command{}, _context} =
             PortableCommand.compile(operation, context: context, action_phase: :execute)

    assert_receive :choice_callback_called

    assert {:error, %Error{details: %{code: :unregistered_action_authorization}}} =
             PortableCommand.compile(operation, context: context, action_phase: :execute)

    refute_receive :choice_callback_called
  end

  test "contract-only phase refusal also burns the genuine plan grant" do
    domain = Selecto.Domain.Examples.work_items()

    {:ok, document, _} =
      SelectoUpdato.DomainContract.json_document(domain,
        generated_at: "2026-10-07T00:00:00Z"
      )

    {:ok, plan} =
      SelectoUpdato.plan_domain_action(document, %{action: :archive, target: %{id: 7}})

    {:ok, authorized, decision, grant} =
      ActionAuthorization.authorize_and_issue(plan, :execute, %{actor: %{id: 42}, tenant_id: 9},
        capability_resolver: fn _, _, _ -> :enabled end
      )

    context = %{
      actor: %{id: 42},
      tenant_id: 9,
      capability_decision: CapabilityDecision.to_map(decision),
      action_authorization: %{
        action: plan.action,
        capability: plan.capability,
        phase: :execute,
        status: :enabled,
        authorization_grant: grant
      }
    }

    assert authorized.operation_builder == nil

    refused = ActionAuthorization.consume_plan(authorized, :preview, context)
    retried = ActionAuthorization.consume_plan(authorized, :execute, context)

    if prefix = System.get_env("SELECTO_ACTION_GRANT_EVIDENCE_PREFIX") do
      File.write!(
        prefix <> ".contract-only.json",
        Jason.encode!(
          %{
            boundary: "native_contract_only_grant_service",
            phase_refusal: consumption_result(refused),
            restored_execute: consumption_result(retried)
          },
          pretty: true
        )
      )
    end

    assert {:error, %Error{details: %{code: :action_authorization_phase_mismatch}}} =
             refused

    assert {:error, %Error{details: %{code: :unregistered_action_authorization}}} =
             retried
  end

  defp consumption_result(:ok), do: %{outcome: "consumed"}

  defp consumption_result({:error, %Error{} = error}),
    do: %{
      outcome: "refused",
      type: error.type,
      code: error.details[:code] || error.type,
      raw_native_error: inspect(error, limit: :infinity, printable_limit: :infinity)
    }

  defp authorized_operation do
    {:ok, plan} =
      SelectoUpdato.plan_domain_action(
        Selecto.Domain.Examples.work_items(),
        %{action: :archive, target: 7}
      )

    context = %{actor: %{id: 42}, tenant_id: 9}

    {:ok, authorized, decision, grant} =
      ActionAuthorization.authorize_and_issue(plan, :execute, context,
        capability_resolver: fn _, _, _ -> :enabled end
      )

    test_pid = self()

    context =
      context
      |> Map.put(:capability_decision, CapabilityDecision.to_map(decision))
      |> Map.put(:action_authorization, %{
        action: plan.action,
        capability: plan.capability,
        phase: :execute,
        status: :enabled,
        authorization_grant: grant
      })
      |> Map.put(:choice_source_membership_resolver, fn _ ->
        send(test_pid, :choice_callback_called)
        Selecto.Domain.Choices.valid(:early_refusal_control)
      end)

    {authorized.operation_builder, context}
  end
end
