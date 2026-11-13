defmodule SelectoUpdato.ActionExecutionAdapterTest do
  use ExUnit.Case, async: false

  alias SelectoUpdato.{ActionExecutionAdapter, ActionPlan, PlannedOperation}

  defmodule WriteAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    alias Selecto.Write.{Command, Result}

    def name, do: :action_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false
    def write_capabilities(_connection), do: full_write_capabilities()

    defp full_write_capabilities do
      %{
        protocol_version: 1,
        insert: true,
        update: true,
        upsert: true,
        delete: true,
        returning: true,
        generated_keys: :returning,
        transactions: true,
        atomic_batch: true,
        write_graph: true
      }
    end

    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}

    def execute_write(_connection, %Command{} = command, _opts) do
      send(self(), {:action_write, command})
      {:ok, %Result{operation: command.operation, affected_rows: 1}}
    end
  end

  defmodule BuilderAdapter do
    def execute_action(plan, context, opts) do
      selecto = %Selecto{
        adapter: SelectoUpdato.ActionExecutionAdapterTest.WriteAdapter,
        connection: :recording
      }

      context =
        Map.put(
          context,
          :choice_source_membership_resolver,
          Keyword.get(opts, :choice_source_membership_resolver)
        )

      operation = SelectoUpdato.with_tenant(plan.operation_builder, Map.get(context, :tenant))
      SelectoUpdato.execute(operation, selecto, context: context)
    end

    def dry_run_action(plan, context, opts) do
      selecto = %Selecto{
        adapter: SelectoUpdato.ActionExecutionAdapterTest.WriteAdapter,
        connection: :recording
      }

      context =
        Map.put(
          context,
          :choice_source_membership_resolver,
          Keyword.get(opts, :choice_source_membership_resolver)
        )

      operation = SelectoUpdato.with_tenant(plan.operation_builder, Map.get(context, :tenant))
      SelectoUpdato.preview(operation, selecto, context: context)
    end
  end

  defmodule ContextSwapAdapter do
    def execute_action(plan, context, opts) do
      selecto = %Selecto{
        adapter: SelectoUpdato.ActionExecutionAdapterTest.WriteAdapter,
        connection: :recording
      }

      operation = SelectoUpdato.with_tenant(plan.operation_builder, Map.get(context, :tenant))

      context =
        context
        |> Map.merge(Keyword.fetch!(opts, :swap_context))
        |> Map.put(
          :choice_source_membership_resolver,
          Keyword.get(opts, :choice_source_membership_resolver)
        )

      SelectoUpdato.execute(operation, selecto, context: context)
    end
  end

  defmodule DuplicateIdentityAdapter do
    def execute_action(plan, context, opts) do
      grant = plan.operation_builder.action_policy.authorization_grant
      send(self(), {:duplicate_identity_grant, grant})

      operation =
        plan.operation_builder
        |> SelectoUpdato.with_tenant(Map.get(context, :tenant))
        |> SelectoUpdato.apply_execution_scope()

      context =
        context
        |> Map.merge(Keyword.fetch!(opts, :duplicate_identity))
        |> Map.put(
          :choice_source_membership_resolver,
          Keyword.get(opts, :choice_source_membership_resolver)
        )

      SelectoUpdato.PortableCommand.compile(operation,
        context: context,
        action_phase: :execute
      )
    end
  end

  defmodule Adapter do
    def execute_action(plan, context, opts) do
      {:ok,
       %{
         mode: :execute,
         action: plan.action,
         operation_builder: plan.operation_builder,
         context: context,
         opts: opts
       }}
    end

    def dry_run_action(plan, context, opts) do
      {:ok,
       %{
         mode: :dry_run,
         action: plan.action,
         operation_builder: plan.operation_builder,
         context: context,
         opts: opts
       }}
    end
  end

  defmodule CallbackProbeAdapter do
    def execute_action(plan, _context, _opts) do
      send(self(), {:callback_probe, plan})
      {:ok, plan.operation_builder}
    end
  end

  defmodule ExecuteOnlyAdapter do
    def execute_action(_plan, _context, _opts), do: {:ok, :executed}
  end

  defmodule Actor do
    defstruct [:id, :email]
  end

  defmodule MissingExecuteAdapter do
    def dry_run_action(_plan, _context, _opts), do: {:ok, :dry_run}
  end

  defmodule Resolver do
    def decide(%{capability: "allowed.action"}, _context, _opts), do: :enabled
    def decide(%{capability: "work_items.archive"}, _context, _opts), do: :enabled

    def decide(%{capability: "disabled.action"}, _context, _opts) do
      %{
        status: :disabled,
        reason: "No permission for this action.",
        code: :missing_permission,
        audit: %{policy: :test}
      }
    end
  end

  test "resolves an explicit host config adapter" do
    assert ActionExecutionAdapter.for_config(%{
             action_execution_adapter: Adapter
           }) == {:ok, Adapter}
  end

  test "resolves execute-only adapters because dry-run remains optional" do
    assert ActionExecutionAdapter.for_config(%{action_execution_adapter: ExecuteOnlyAdapter}) ==
             {:ok, ExecuteOnlyAdapter}
  end

  test "returns none when no host adapter is configured" do
    assert ActionExecutionAdapter.for_config(%{}) == :none
    assert ActionExecutionAdapter.for_config(%{repo: :ignored_persistence_detail}) == :none
  end

  test "fails closed for malformed configured adapters" do
    assert {:error, {:validation_error, _message, details}} =
             ActionExecutionAdapter.for_config(%{action_execution_adapter: "not a module"})

    assert details.code == :invalid_action_execution_adapter
    assert details.adapter == ~s("not a module")
  end

  test "fails closed for adapters without execute callback" do
    assert {:error, {:validation_error, _message, details}} =
             ActionExecutionAdapter.for_config(%{action_execution_adapter: MissingExecuteAdapter})

    assert details.code == :unsupported_action_execution_adapter
    assert details.callback == :execute_action
    assert details.adapter =~ "MissingExecuteAdapter"
  end

  test "delegates execute and dry-run callbacks" do
    plan = contract_only_plan(capability: nil)
    context = %{tenant: 7}

    assert {:ok, execute_payload} =
             ActionExecutionAdapter.execute(Adapter, plan, context, timeout: 10)

    assert execute_payload.mode == :execute
    assert execute_payload.action == "archive"
    assert execute_payload.operation_builder == nil
    assert execute_payload.context.tenant == 7
    assert execute_payload.context.action_authorization.phase == :execute
    assert is_reference(execute_payload.context.action_authorization.authorization_grant)
    assert execute_payload.opts == [timeout: 10]

    assert {:ok, preview_payload} = ActionExecutionAdapter.dry_run(Adapter, plan, context)
    assert preview_payload.mode == :dry_run
    assert preview_payload.action == "archive"
    assert preview_payload.operation_builder == nil
    assert preview_payload.context.tenant == 7
    assert preview_payload.context.action_authorization.phase == :preview
    assert is_reference(preview_payload.context.action_authorization.authorization_grant)
    assert preview_payload.opts == []
  end

  test "passes enabled capability decisions into adapter context" do
    plan = contract_only_plan()

    assert {:ok, payload} =
             ActionExecutionAdapter.execute(Adapter, plan, %{}, capability_resolver: Resolver)

    assert payload.context.capability_decision.status == :enabled
    assert payload.context.capability_decision.capability == "work_items.archive"
    assert payload.context.action_authorization.status == :enabled
    assert payload.context.action_authorization.capability == "work_items.archive"
    assert payload.context.action_authorization.phase == :execute
  end

  test "opaque planned builders fail closed outside the authorized adapter boundary" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(
               Selecto.Domain.Examples.work_items(),
               %{action: :archive, target: 7}
             )

    selecto = %Selecto{adapter: WriteAdapter, connection: :recording}

    assert %PlannedOperation{} = plan.operation_builder

    assert {:error,
            %SelectoUpdato.Error{
              type: :authorization,
              details: %{code: :opaque_planned_operation}
            }} = SelectoUpdato.execute(plan.operation_builder, selecto)

    assert {:error, %{details: %{code: :opaque_planned_operation}}} =
             SelectoUpdato.preview(plan.operation_builder, selecto)

    assert {:error, %{details: %{code: :opaque_planned_operation}}} =
             SelectoUpdato.dry_run(plan.operation_builder, selecto)

    assert {:error, %{details: %{code: :opaque_planned_operation}}} =
             SelectoUpdato.PortableCommand.compile(plan.operation_builder)

    refute_receive {:action_write, _command}

    resolver = fn request, _context, _opts ->
      if request.capability == "work_items.archive", do: :enabled, else: :hidden
    end

    assert {:ok, %Selecto.Write.Result{operation: :update}} =
             ActionExecutionAdapter.execute(BuilderAdapter, plan, %{tenant: %{tenant_id: 9}},
               capability_resolver: resolver,
               choice_source_membership_resolver: fn _request ->
                 Selecto.Domain.Choices.valid(:action_transition)
               end
             )

    assert_receive {:action_write, %Selecto.Write.Command{operation: :update}}
  end

  test "preview authorization evidence cannot be replayed for execution" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(
               Selecto.Domain.Examples.work_items(),
               %{action: :archive, target: 7}
             )

    resolver = fn _request, _context, _opts -> :enabled end

    assert {:ok, %{context: preview_context, operation_builder: authorized_builder}} =
             ActionExecutionAdapter.dry_run(Adapter, plan, %{}, capability_resolver: resolver)

    selecto = %Selecto{adapter: WriteAdapter, connection: :recording}

    assert {:error,
            %SelectoUpdato.Error{
              type: :authorization,
              details: %{code: :action_authorization_phase_mismatch}
            }} = SelectoUpdato.execute(authorized_builder, selecto, context: preview_context)

    refute_receive {:action_write, _command}
  end

  test "declared preconditions reach the adapter in the final mutation predicate" do
    domain =
      Selecto.Domain.Examples.work_items()
      |> put_in([:actions, :archive, :preconditions], [
        {:lte, :priority, 3},
        {:in, :owner_id, [7, 8]},
        {:gte, :private_metric, 0}
      ])

    assert {:ok, plan} = SelectoUpdato.plan_domain_action(domain, %{action: :archive, target: 7})

    assert {:ok, %Selecto.Write.Result{operation: :update}} =
             ActionExecutionAdapter.execute(BuilderAdapter, plan, %{tenant: %{tenant_id: 9}},
               capability_resolver: fn _request, _context, _opts -> :enabled end,
               choice_source_membership_resolver: fn _request ->
                 Selecto.Domain.Choices.valid(:action_precondition)
               end
             )

    assert_receive {:action_write, %Selecto.Write.Command{predicate: {:and, predicates}}}
    assert {:eq, {:field, "id"}, {:literal, 7}} in predicates
    assert {:lte, {:field, "priority"}, {:literal, 3}} in predicates
    assert {:in, {:field, "owner_id"}, [{:literal, 7}, {:literal, 8}]} in predicates
    assert {:gte, {:field, "private_metric"}, {:literal, 0}} in predicates
    assert {:eq, {:field, "state"}, {:literal, "done"}} in predicates
    assert {:eq, {:field, "tenant_id"}, {:literal, 9}} in predicates
  end

  test "a trusted context's required filters bound a planned action without voiding its grant" do
    domain = Selecto.Domain.Examples.work_items()
    assert {:ok, plan} = SelectoUpdato.plan_domain_action(domain, %{action: :archive, target: 7})
    context = %{tenant: %{tenant_id: 9}, required_filters: [{"owner_id", 7}]}

    assert {:ok, %Selecto.Write.Result{operation: :update}} =
             ActionExecutionAdapter.execute(BuilderAdapter, plan, context,
               capability_resolver: fn _request, _context, _opts -> :enabled end,
               choice_source_membership_resolver: fn _request ->
                 Selecto.Domain.Choices.valid(:action_precondition)
               end
             )

    assert_receive {:action_write, %Selecto.Write.Command{predicate: {:and, predicates}}}
    assert {:eq, {:field, "owner_id"}, {:literal, 7}} in predicates
    assert {:eq, {:field, "tenant_id"}, {:literal, 9}} in predicates
  end

  test "a grant issued under trusted required filters writes under those only" do
    domain = Selecto.Domain.Examples.work_items()
    context = %{tenant: %{tenant_id: 9}, required_filters: [{"owner_id", 7}]}

    for swap <- [
          %{required_filters: [{"owner_id", 8}]},
          %{required_filters: [{"priority", 1}]},
          %{required_filters: []},
          %{required_filters: [{"owner_id", 7}, {"owner_id", 8}]}
        ] do
      assert {:ok, plan} =
               SelectoUpdato.plan_domain_action(domain, %{action: :archive, target: 7})

      assert {:error, %SelectoUpdato.Error{details: %{code: :action_authorization_mismatch}}} =
               ActionExecutionAdapter.execute(ContextSwapAdapter, plan, context,
                 capability_resolver: fn _request, _context, _opts -> :enabled end,
                 swap_context: swap,
                 choice_source_membership_resolver: fn _request ->
                   Selecto.Domain.Choices.valid(:action_precondition)
                 end
               ),
             inspect(swap)

      refute_received {:action_write, _command}
    end

    # The same filters, spelled with an atom, are the same binding.
    assert {:ok, plan} = SelectoUpdato.plan_domain_action(domain, %{action: :archive, target: 7})

    assert {:ok, _result} =
             ActionExecutionAdapter.execute(ContextSwapAdapter, plan, context,
               capability_resolver: fn _request, _context, _opts -> :enabled end,
               swap_context: %{required_filters: [{:owner_id, 7}]},
               choice_source_membership_resolver: fn _request ->
                 Selecto.Domain.Choices.valid(:action_precondition)
               end
             )
  end

  test "copying or forging opaque handles cannot weaken a planned action" do
    refute function_exported?(SelectoUpdato.ActionAuthorization, :issue, 3)
    refute function_exported?(SelectoUpdato.ActionAuthorization, :seal_planned_action, 2)
    refute function_exported?(SelectoUpdato.PlannedOperation, :seal, 2)

    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(
               Selecto.Domain.Examples.work_items(),
               %{action: :archive, target: 7}
             )

    assert %PlannedOperation{} = handle = plan.operation_builder
    refute Map.has_key?(handle, :action_policy)

    assert_raise KeyError, fn -> apply(Map, :replace!, [handle, :action_policy, nil]) end

    copied_token = %PlannedOperation{token: handle.token}
    mismatched_plan = %{plan | operation_builder: copied_token, target: 99}

    assert {:error, {:validation_error, _message, %{code: :action_policy_mismatch}}} =
             ActionExecutionAdapter.execute(BuilderAdapter, mismatched_plan, %{},
               capability_resolver: fn _request, _context, _opts -> :enabled end
             )

    forged_plan = %{plan | operation_builder: %PlannedOperation{token: make_ref()}}

    assert {:error, {:validation_error, _message, %{code: :unregistered_planned_operation}}} =
             ActionExecutionAdapter.execute(BuilderAdapter, forged_plan, %{},
               capability_resolver: fn _request, _context, _opts -> :enabled end
             )

    copied_with_stripped_policy = Map.put(handle, :action_policy, nil)

    assert {:error, %{details: %{code: :opaque_planned_operation}}} =
             SelectoUpdato.execute(
               copied_with_stripped_policy,
               %Selecto{adapter: WriteAdapter, connection: :recording}
             )

    refute_receive {:action_write, _command}
  end

  test "passes declared action audit envelope into adapter context" do
    plan =
      contract_only_plan(
        target: %{"id" => 42},
        reason: "Ready",
        audit: %{
          event: "invoice.approved",
          include_actor: true,
          include_tenant: true,
          include_target: true,
          include_inputs: true,
          include_preview_id: true,
          metadata: %{source: "test"}
        }
      )

    context = %{actor: "user-7", tenant: "tenant-3", preview_id: "preview-1"}

    assert {:ok, payload} =
             ActionExecutionAdapter.execute(Adapter, plan, context, capability_resolver: Resolver)

    assert payload.context.action_audit.event == "invoice.approved"
    assert payload.context.action_audit.phase == :execute
    assert payload.context.action_audit.action == "archive"
    assert payload.context.action_audit.capability == "work_items.archive"
    assert payload.context.action_audit.actor == "user-7"
    assert payload.context.action_audit.tenant == "tenant-3"
    assert payload.context.action_audit.target == %{"id" => 42}
    assert payload.context.action_audit.inputs == %{"reason" => "Ready"}
    assert payload.context.action_audit.preview_id == "preview-1"
    assert payload.context.action_audit.metadata == %{"source" => "test"}
    assert payload.context.action_audit.capability_decision.status == :enabled
    assert payload.context.action_audit.capability_decision.capability == "work_items.archive"
    assert payload.context.action_audit.timestamp =~ ~r/^\d{4}-\d{2}-\d{2}T/
  end

  test "compacts struct actors in action audit envelopes" do
    plan =
      contract_only_plan(
        capability: nil,
        audit: %{event: "invoice.approved", include_actor: true}
      )

    assert {:ok, payload} =
             ActionExecutionAdapter.execute(Adapter, plan, %{
               actor: %Actor{id: 7, email: "a@example.test"}
             })

    assert payload.context.action_audit.actor == %{id: 7}
  end

  test "omits action audit envelope when action does not declare audit metadata" do
    plan = contract_only_plan()

    assert {:ok, payload} =
             ActionExecutionAdapter.execute(Adapter, plan, %{}, capability_resolver: Resolver)

    refute Map.has_key?(payload.context, :action_audit)
  end

  test "fails closed for capability-gated actions without a resolver" do
    plan = contract_only_plan()

    assert {:error, {:validation_error, message, details}} =
             ActionExecutionAdapter.execute(Adapter, plan, %{})

    assert message == "Action execute requires a host capability resolver."
    assert details.code == :missing_capability_resolver
    assert details.status == :hidden
    assert details.capability == "work_items.archive"
  end

  test "fails closed when a resolver disables an action" do
    plan = contract_only_plan()

    resolver = fn _request, _context, _opts ->
      %{
        status: :disabled,
        reason: "No permission for this action.",
        code: :missing_permission,
        audit: %{policy: :test}
      }
    end

    assert {:error, {:validation_error, message, details}} =
             ActionExecutionAdapter.dry_run(Adapter, plan, %{}, capability_resolver: resolver)

    assert message == "No permission for this action."
    assert details.code == :missing_permission
    assert details.status == :disabled
    assert details.audit == %{policy: :test}
  end

  test "resolver exceptions and timeouts fail closed without poisoning the grant service" do
    plan = contract_only_plan()
    service = Process.whereis(SelectoUpdato.ActionAuthorization)
    assert is_pid(service)

    raising_resolver = fn _request, _context, _opts -> raise "policy backend failed" end

    assert {:error, {:validation_error, _message, %{code: :capability_resolver_exception}}} =
             ActionExecutionAdapter.execute(Adapter, plan, %{},
               capability_resolver: raising_resolver
             )

    slow_resolver = fn _request, _context, _opts ->
      Process.sleep(50)
      :enabled
    end

    assert {:error, {:validation_error, _message, %{code: :capability_resolver_timeout}}} =
             ActionExecutionAdapter.execute(Adapter, plan, %{},
               capability_resolver: slow_resolver,
               capability_resolver_timeout: 5
             )

    assert Process.whereis(SelectoUpdato.ActionAuthorization) == service
    assert Process.alive?(service)

    assert {:ok, %{mode: :execute}} =
             ActionExecutionAdapter.execute(Adapter, plan, %{}, capability_resolver: Resolver)
  end

  test "hand-built nil-operation plans cannot invoke a trusted adapter" do
    forged_plan = %ActionPlan{
      action: "archive",
      capability: "work_items.archive",
      operation: "update",
      operation_builder: nil
    }

    assert {:error, {:validation_error, _message, %{code: :invalid_planned_operation}}} =
             ActionExecutionAdapter.execute(CallbackProbeAdapter, forged_plan, %{},
               capability_resolver: Resolver
             )

    refute_receive {:callback_probe, _plan}
  end

  test "contract-only plans require registered immutable provenance" do
    plan = contract_only_plan()
    assert %PlannedOperation{} = plan.operation_builder

    assert {:ok, nil} =
             ActionExecutionAdapter.execute(CallbackProbeAdapter, plan, %{},
               capability_resolver: Resolver
             )

    assert_receive {:callback_probe, %ActionPlan{operation_builder: nil}}

    modified_plan = %{plan | target: %{"id" => 99}}

    assert {:error, {:validation_error, _message, %{code: :action_policy_mismatch}}} =
             ActionExecutionAdapter.execute(CallbackProbeAdapter, modified_plan, %{},
               capability_resolver: Resolver
             )

    refute_receive {:callback_probe, _plan}
  end

  test "contract-only action grants bind the authorized plan and are single-use" do
    plan = contract_only_plan()

    assert {:ok, authorized_plan, decision, grant} =
             SelectoUpdato.ActionAuthorization.authorize_and_issue(
               plan,
               :execute,
               %{tenant: 7},
               capability_resolver: Resolver
             )

    assert authorized_plan.operation_builder == nil
    assert authorized_plan.authorization_grant == grant

    context = %{
      tenant: 7,
      capability_decision: SelectoUpdato.CapabilityDecision.to_map(decision),
      action_authorization: %{
        action: authorized_plan.action,
        capability: authorized_plan.capability,
        phase: :execute,
        status: :enabled,
        authorization_grant: grant
      }
    }

    assert :ok =
             SelectoUpdato.ActionAuthorization.consume_plan(
               authorized_plan,
               :execute,
               context
             )

    assert {:error,
            %SelectoUpdato.Error{
              type: :authorization,
              details: %{code: :unregistered_action_authorization}
            }} =
             SelectoUpdato.ActionAuthorization.consume_plan(
               authorized_plan,
               :execute,
               context
             )
  end

  test "contract-only action grants reject an altered authorized plan" do
    plan = contract_only_plan()

    assert {:ok, authorized_plan, decision, grant} =
             SelectoUpdato.ActionAuthorization.authorize_and_issue(
               plan,
               :execute,
               %{},
               capability_resolver: Resolver
             )

    context = %{
      capability_decision: SelectoUpdato.CapabilityDecision.to_map(decision),
      action_authorization: %{
        action: authorized_plan.action,
        capability: authorized_plan.capability,
        phase: :execute,
        status: :enabled,
        authorization_grant: grant
      }
    }

    altered_plan = %{authorized_plan | target: %{"id" => 99}}

    assert {:error,
            %SelectoUpdato.Error{
              type: :authorization,
              details: %{code: :action_authorization_mismatch}
            }} =
             SelectoUpdato.ActionAuthorization.consume_plan(
               altered_plan,
               :execute,
               context
             )
  end

  test "unconsumed action grants expire without relying on adapter cleanup" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(
               Selecto.Domain.Examples.work_items(),
               %{action: :archive, target: 7}
             )

    resolver = fn _request, _context, _opts -> :enabled end

    assert {:ok, authorized_plan, _decision, grant} =
             SelectoUpdato.ActionAuthorization.authorize_and_issue(
               plan,
               :execute,
               %{},
               capability_resolver: resolver,
               action_authorization_grant_ttl: 5
             )

    assert authorized_plan.operation_builder.action_policy.authorization_grant == grant
    Process.sleep(25)

    assert {:error,
            %SelectoUpdato.Error{
              type: :authorization,
              details: %{code: :unregistered_action_authorization}
            }} =
             SelectoUpdato.ActionAuthorization.consume(grant, %{
               action: plan.action,
               capability: plan.capability,
               operation: authorized_plan.operation_builder.type,
               phase: :execute
             })
  end

  test "authorized operation grants remain single-use under concurrent compilation" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(
               Selecto.Domain.Examples.work_items(),
               %{action: :archive, target: 7}
             )

    resolver = fn _request, _context, _opts -> :enabled end

    assert {:ok, authorized_plan, decision, grant} =
             SelectoUpdato.ActionAuthorization.authorize_and_issue(
               plan,
               :execute,
               %{tenant_id: 9},
               capability_resolver: resolver
             )

    operation = authorized_plan.operation_builder
    policy = operation.action_policy

    context = %{
      tenant_id: 9,
      choice_source_membership_resolver: fn _request ->
        Selecto.Domain.Choices.valid(:concurrent_authorization_probe)
      end,
      action_authorization: %{
        action: plan.action,
        capability: plan.capability,
        phase: :execute,
        status: :enabled,
        authorization_grant: grant
      },
      capability_decision: SelectoUpdato.CapabilityDecision.to_map(decision)
    }

    results =
      1..2
      |> Task.async_stream(
        fn _index ->
          SelectoUpdato.PortableCommand.compile(operation,
            context: context,
            action_phase: :execute
          )
        end,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %Selecto.Write.Command{}, _context}, &1)) == 1

    assert Enum.count(
             results,
             &match?(
               {:error,
                %SelectoUpdato.Error{
                  details: %{code: :unregistered_action_authorization}
                }},
               &1
             )
           ) == 1

    assert policy.authorization_grant == grant
  end

  test "authorization grants are bound to the exact sealed operation payload" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(
               Selecto.Domain.Examples.work_items(),
               %{action: :archive, target: 7}
             )

    assert {:ok, authorized_plan, decision, grant} =
             SelectoUpdato.ActionAuthorization.authorize_and_issue(
               plan,
               :execute,
               %{tenant_id: 9},
               capability_resolver: fn _request, _context, _opts -> :enabled end
             )

    operation = authorized_plan.operation_builder
    tampered_operation = %{operation | changes: Map.put(operation.changes, "title", "tampered")}

    context = %{
      tenant_id: 9,
      choice_source_membership_resolver: fn _request ->
        Selecto.Domain.Choices.valid(:payload_binding_probe)
      end,
      action_authorization: %{
        action: plan.action,
        capability: plan.capability,
        phase: :execute,
        status: :enabled,
        authorization_grant: grant
      },
      capability_decision: SelectoUpdato.CapabilityDecision.to_map(decision)
    }

    assert {:error,
            %SelectoUpdato.Error{
              type: :authorization,
              details: %{code: :action_authorization_mismatch}
            }} =
             SelectoUpdato.PortableCommand.compile(tampered_operation,
               context: context,
               action_phase: :execute
             )

    assert {:error, %SelectoUpdato.Error{details: %{code: :unregistered_action_authorization}}} =
             SelectoUpdato.ActionAuthorization.consume(grant, %{})
  end

  test "a grant consumed before callback-backed validation stays burned on later failure" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(
               Selecto.Domain.Examples.work_items(),
               %{action: :archive, target: 7}
             )

    assert {:ok, authorized_plan, decision, grant} =
             SelectoUpdato.ActionAuthorization.authorize_and_issue(
               plan,
               :execute,
               %{actor: %{id: "actor-a"}, tenant_id: 9},
               capability_resolver: Resolver
             )

    context = %{
      actor: %{id: "actor-a"},
      tenant_id: 9,
      action_authorization: %{
        action: plan.action,
        capability: plan.capability,
        phase: :execute,
        status: :enabled,
        authorization_grant: grant
      },
      capability_decision: SelectoUpdato.CapabilityDecision.to_map(decision)
    }

    assert {:error,
            %SelectoUpdato.Error{
              type: :validation,
              details: %{code: :choice_membership_resolver_required}
            }} =
             SelectoUpdato.PortableCommand.compile(authorized_plan.operation_builder,
               context: context,
               action_phase: :execute
             )

    context =
      Map.put(context, :choice_source_membership_resolver, fn _request ->
        Selecto.Domain.Choices.valid(:burned_authorization_probe)
      end)

    assert {:error,
            %SelectoUpdato.Error{
              type: :authorization,
              details: %{code: :unregistered_action_authorization}
            }} =
             SelectoUpdato.PortableCommand.compile(authorized_plan.operation_builder,
               context: context,
               action_phase: :execute
             )
  end

  test "authorization grants cannot cross actor or tenant context" do
    for {swap_context, expected_error} <- [
          {%{actor: %{id: "actor-b"}}, {:authorization, :action_authorization_mismatch}},
          {%{actor: %{id: "actor-a", role: :injected}},
           {:authorization, :action_authorization_mismatch}},
          {%{tenant: %{tenant_id: 10}}, {:tenant_mismatch, :conflicting_trusted_tenant_context}},
          {%{tenant_id: 10}, {:tenant_mismatch, :conflicting_trusted_tenant_context}}
        ] do
      assert {:ok, plan} =
               SelectoUpdato.plan_domain_action(
                 Selecto.Domain.Examples.work_items(),
                 %{action: :archive, target: 7}
               )

      context = %{actor: %{id: "actor-a"}, tenant: %{tenant_id: 9}}
      test_pid = self()

      assert {:error, %SelectoUpdato.Error{} = error} =
               ActionExecutionAdapter.execute(ContextSwapAdapter, plan, context,
                 capability_resolver: Resolver,
                 choice_source_membership_resolver: fn _request ->
                   send(test_pid, :unauthorized_choice_resolver_called)
                   Selecto.Domain.Choices.valid(:authorization_context_probe)
                 end,
                 swap_context: swap_context
               )

      assert {error.type, error.details.code} == expected_error

      refute_receive :unauthorized_choice_resolver_called
      refute_receive {:action_write, _command}
    end
  end

  test "identity supplied through opts is propagated and bound to the grant" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(
               Selecto.Domain.Examples.work_items(),
               %{action: :archive, target: 7}
             )

    assert {:ok, %Selecto.Write.Result{operation: :update}} =
             ActionExecutionAdapter.execute(BuilderAdapter, plan, %{},
               capability_resolver: Resolver,
               actor: %{id: "actor-a"},
               tenant: %{tenant_id: 9},
               choice_source_membership_resolver: fn _request ->
                 Selecto.Domain.Choices.valid(:opts_authorization_context_probe)
               end
             )

    assert_receive {:action_write, %Selecto.Write.Command{operation: :update}}
  end

  test "duplicate actor and tenant spellings added by a callback invalidate the grant" do
    for {duplicate_identity, expected_error} <- [
          {%{"actor" => %{id: "actor-b"}}, {:authorization, :authorization_context_mismatch}},
          {%{"tenant" => %{tenant_id: 10}},
           {:tenant_mismatch, :conflicting_trusted_tenant_context}},
          {%{actor: %{"id" => "actor-b", id: "actor-a"}},
           {:authorization, :authorization_context_mismatch}}
        ] do
      assert {:ok, plan} =
               SelectoUpdato.plan_domain_action(
                 Selecto.Domain.Examples.work_items(),
                 %{action: :archive, target: 7}
               )

      context = %{actor: %{id: "actor-a"}, tenant: %{tenant_id: 9}}

      assert {:error, %SelectoUpdato.Error{} = error} =
               ActionExecutionAdapter.execute(DuplicateIdentityAdapter, plan, context,
                 capability_resolver: Resolver,
                 choice_source_membership_resolver: fn _request ->
                   Selecto.Domain.Choices.valid(:duplicate_identity_probe)
                 end,
                 duplicate_identity: duplicate_identity
               )

      assert {error.type, error.details.code} == expected_error

      assert_receive {:duplicate_identity_grant, grant}

      assert {:error,
              %SelectoUpdato.Error{
                details: %{code: :unregistered_action_authorization}
              }} = SelectoUpdato.ActionAuthorization.consume(grant, %{})

      refute_receive {:action_write, _command}
    end
  end

  test "conflicting identity sources fail before resolver or adapter invocation" do
    for {context, opts, field} <- [
          {%{actor: %{id: "actor-a"}}, [actor: %{id: "actor-b"}], :actor},
          {%{"actor" => %{id: "actor-b"}, actor: %{id: "actor-a"}}, [], :actor},
          {%{actor: %{"id" => "actor-b", id: "actor-a"}}, [], :actor},
          {%{tenant: %{tenant_id: 9}}, [tenant: %{tenant_id: 10}], :tenant},
          {%{"tenant" => %{tenant_id: 10}, tenant: %{tenant_id: 9}}, [], :tenant},
          {%{"tenant_id" => 10, tenant_id: 9}, [], :tenant},
          {%{tenant: %{"tenant_id" => 10, tenant_id: 9}}, [], :tenant},
          {%{tenant: %{tenant_id: 9}, tenant_id: 10}, [], :tenant},
          {%{tenant: %{tenant_id: 9, tenant_field: "account_id"}, tenant_field: "tenant_id"}, [],
           :tenant},
          {%{}, [tenant: %{tenant_id: 9}, tenant_id: 10], :tenant},
          {%{}, [tenant: %{"tenant_id" => 10, tenant_id: 9}], :tenant}
        ] do
      assert {:ok, plan} =
               SelectoUpdato.plan_domain_action(
                 Selecto.Domain.Examples.work_items(),
                 %{action: :archive, target: 7}
               )

      test_pid = self()

      resolver = fn _request, _context, _opts ->
        send(test_pid, :conflicting_identity_resolver_called)
        :enabled
      end

      assert {:error,
              {:validation_error, _message,
               %{code: :authorization_context_mismatch, fields: [^field]}}} =
               ActionExecutionAdapter.execute(
                 CallbackProbeAdapter,
                 plan,
                 context,
                 Keyword.put(opts, :capability_resolver, resolver)
               )

      refute_receive :conflicting_identity_resolver_called
      refute_receive {:callback_probe, _plan}
    end
  end

  test "authorization service restart invalidates plans and grants" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(
               Selecto.Domain.Examples.work_items(),
               %{action: :archive, target: 7}
             )

    assert {:ok, authorized_plan, _decision, grant} =
             SelectoUpdato.ActionAuthorization.authorize_and_issue(
               plan,
               :execute,
               %{actor: %{id: "actor-a"}, tenant: %{tenant_id: 9}},
               capability_resolver: Resolver
             )

    old_service = Process.whereis(SelectoUpdato.ActionAuthorization)
    monitor = Process.monitor(old_service)
    GenServer.stop(old_service, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^old_service, :shutdown}
    assert new_service = await_authorization_service(old_service)
    assert new_service != old_service

    assert {:ok, authorization_context} =
             SelectoUpdato.ActionAuthorization.authorization_context(
               %{actor: %{id: "actor-a"}, tenant: %{tenant_id: 9}},
               []
             )

    assert {:error, {:validation_error, _message, %{code: :unregistered_planned_operation}}} =
             ActionExecutionAdapter.execute(BuilderAdapter, plan, %{},
               capability_resolver: Resolver
             )

    assert {:error,
            %SelectoUpdato.Error{
              type: :authorization,
              details: %{code: :unregistered_action_authorization}
            }} =
             SelectoUpdato.ActionAuthorization.consume(grant, %{
               action: plan.action,
               capability: plan.capability,
               operation: authorized_plan.operation_builder.type,
               phase: :execute,
               authorization_context: authorization_context
             })
  end

  test "opaque planned operations expire fail closed" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(
               Selecto.Domain.Examples.work_items(),
               %{action: :archive, target: 7},
               planned_operation_ttl: 5
             )

    Process.sleep(25)

    assert {:error, {:validation_error, _message, %{code: :unregistered_planned_operation}}} =
             ActionExecutionAdapter.execute(BuilderAdapter, plan, %{},
               capability_resolver: fn _request, _context, _opts -> :enabled end
             )

    refute_receive {:action_write, _command}
  end

  test "fails closed when dry-run callback is missing" do
    assert {:error, {:validation_error, _message, details}} =
             ActionExecutionAdapter.dry_run(ExecuteOnlyAdapter, %ActionPlan{}, %{})

    assert details.code == :unsupported_action_dry_run
    assert details.callback == :dry_run_action
  end

  test "execute rejects non-module adapter values instead of raising" do
    assert {:error, {:validation_error, _message, details}} =
             ActionExecutionAdapter.execute("not a module", %ActionPlan{}, %{})

    assert details.code == :invalid_action_execution_adapter
  end

  defp contract_only_plan(opts \\ []) do
    action = get_in(Selecto.Domain.Examples.work_items(), [:actions, :archive])

    action =
      if Keyword.has_key?(opts, :capability) do
        case Keyword.get(opts, :capability) do
          nil -> Map.delete(action, :capability)
          capability -> Map.put(action, :capability, capability)
        end
      else
        action
      end

    action =
      if Keyword.has_key?(opts, :audit) do
        Map.put(action, :audit, Keyword.fetch!(opts, :audit))
      else
        action
      end

    domain = put_in(Selecto.Domain.Examples.work_items(), [:actions, :archive], action)

    {:ok, document, _diagnostics} =
      SelectoUpdato.DomainContract.json_document(domain,
        generated_at: "2026-08-12T00:00:00Z"
      )

    intent = %{
      "action" => "archive",
      "target" => Keyword.get(opts, :target, %{"id" => 7}),
      "inputs" => %{"reason" => Keyword.get(opts, :reason)}
    }

    {:ok, plan} = SelectoUpdato.plan_domain_action(document, intent)
    plan
  end

  defp await_authorization_service(old_service, attempts \\ 50)

  defp await_authorization_service(_old_service, 0), do: nil

  defp await_authorization_service(old_service, attempts) do
    case Process.whereis(SelectoUpdato.ActionAuthorization) do
      pid when is_pid(pid) and pid != old_service ->
        pid

      _other ->
        Process.sleep(2)
        await_authorization_service(old_service, attempts - 1)
    end
  end
end
