defmodule SelectoUpdato.Verification.TrustBoundarySafety do
  @moduledoc """
  Bounded adversarial verification of Updato's final command trust boundary.

  Each state is a distinct caller-controlled weakening attempt. The model
  proves that normalization ambiguity, undeclared identifiers, domain-policy
  expansion, missing choice membership, direct opaque planned operations, and
  forged, unregistered, or modified planned-action provenance all fail before a
  command or trusted adapter invocation is authorized.
  """

  alias Selecto.Verification.BoundedModel

  @spec verify() :: BoundedModel.report()
  def verify do
    BoundedModel.check("selecto_updato.trust_boundary.v1", states(), invariants())
  end

  @doc false
  def states do
    [
      adversarial_state(
        :duplicate_assignment,
        duplicate_assignment(),
        :duplicate_assignment_identifier
      ),
      adversarial_state(:duplicate_filter, duplicate_filter(), :duplicate_filter_identifier),
      adversarial_state(
        :duplicate_returning,
        duplicate_returning(),
        :duplicate_returning_identifier
      ),
      adversarial_state(:undeclared_filter, undeclared_filter(), :undeclared_write_identifier),
      adversarial_state(
        :undeclared_returning,
        undeclared_returning(),
        :undeclared_write_identifier
      ),
      adversarial_state(
        :weakened_cardinality,
        weakened_cardinality(),
        :expected_cardinality_policy_violation
      ),
      adversarial_state(:expanded_returning, expanded_returning(), :returning_policy_violation),
      adversarial_state(
        :missing_choice_resolver,
        missing_choice_resolver(),
        :choice_membership_resolver_required
      ),
      action_state(:opaque_planned_operation, :opaque),
      action_state(:forged_planned_operation, :forged),
      provenance_state(:unregistered_nil_plan),
      provenance_state(:modified_contract_only_plan)
    ]
  end

  defp invariants do
    [
      {"adversarial_intent_fails_closed", &adversarial_intent_fails_closed/1},
      {"failure_reason_matches_boundary", &failure_reason_matches_boundary/1}
    ]
  end

  defp adversarial_intent_fails_closed(%{result: {:error, %SelectoUpdato.Error{}}}), do: :ok

  defp adversarial_intent_fails_closed(%{
         result: {:error, {:validation_error, _message, %{code: _code}}}
       }),
       do: :ok

  defp adversarial_intent_fails_closed(state) do
    {:error, %{case: state.case, dispatchable_result: state.result}}
  end

  defp failure_reason_matches_boundary(%{
         expected_code: code,
         result: {:error, %SelectoUpdato.Error{details: %{code: code}}}
       }),
       do: :ok

  defp failure_reason_matches_boundary(%{
         expected_code: code,
         result: {:error, {:validation_error, _message, %{code: code}}}
       }),
       do: :ok

  defp failure_reason_matches_boundary(state) do
    {:error,
     %{
       case: state.case,
       expected_code: state.expected_code,
       actual_result: state.result
     }}
  end

  defp adversarial_state(case_name, operation, expected_code) do
    %{
      case: case_name,
      expected_code: expected_code,
      result: SelectoUpdato.PortableCommand.compile(operation)
    }
  end

  defp action_state(case_name, mode) do
    {:ok, plan} =
      SelectoUpdato.plan_domain_action(
        Selecto.Domain.Examples.work_items(),
        %{action: :archive, target: 7}
      )

    {operation, context, expected_code} =
      case mode do
        :opaque ->
          {plan.operation_builder, %{}, :opaque_planned_operation}

        :forged ->
          {%SelectoUpdato.PlannedOperation{token: make_ref()}, %{}, :opaque_planned_operation}
      end

    %{
      case: case_name,
      expected_code: expected_code,
      result:
        SelectoUpdato.PortableCommand.compile(operation,
          context: context,
          action_phase: :execute
        )
    }
  end

  defp provenance_state(:unregistered_nil_plan = case_name) do
    plan = %SelectoUpdato.ActionPlan{
      action: "archive",
      capability: "work_items.archive",
      operation: "update",
      operation_builder: nil
    }

    provenance_result(case_name, plan, :invalid_planned_operation)
  end

  defp provenance_state(:modified_contract_only_plan = case_name) do
    {:ok, document, _diagnostics} =
      SelectoUpdato.DomainContract.json_document(Selecto.Domain.Examples.work_items(),
        generated_at: "2026-08-12T00:00:00Z"
      )

    {:ok, plan} =
      SelectoUpdato.plan_domain_action(document, %{
        "action" => "archive",
        "target" => %{"id" => 7}
      })

    provenance_result(case_name, %{plan | target: %{"id" => 99}}, :action_policy_mismatch)
  end

  defp provenance_result(case_name, plan, expected_code) do
    resolver = fn _request, _context, _opts -> :enabled end

    %{
      case: case_name,
      expected_code: expected_code,
      result:
        SelectoUpdato.ActionAuthorization.authorize_and_issue(
          plan,
          :execute,
          %{},
          capability_resolver: resolver
        )
    }
  end

  defp duplicate_assignment do
    domain()
    |> SelectoUpdato.new()
    |> SelectoUpdato.insert(%{:name => "one", "name" => "two"})
  end

  defp duplicate_filter do
    domain()
    |> update_operation()
    |> SelectoUpdato.filters([{:id, 1}, {"id", 2}])
  end

  defp duplicate_returning do
    domain(returning: :all)
    |> update_operation()
    |> SelectoUpdato.filter({:id, 1})
    |> SelectoUpdato.returning([:id, "id"])
  end

  defp undeclared_filter do
    domain()
    |> update_operation()
    |> SelectoUpdato.filter({:unscoped_secret, 1})
  end

  defp undeclared_returning do
    domain(returning: :all)
    |> update_operation()
    |> SelectoUpdato.filter({:id, 1})
    |> SelectoUpdato.returning([:unscoped_secret])
  end

  defp weakened_cardinality do
    domain()
    |> update_operation()
    |> SelectoUpdato.filter({:id, 1})
    |> SelectoUpdato.expected_cardinality(:many)
  end

  defp expanded_returning do
    domain()
    |> update_operation()
    |> SelectoUpdato.filter({:id, 1})
    |> SelectoUpdato.returning(:all)
  end

  defp missing_choice_resolver do
    domain()
    |> SelectoUpdato.new()
    |> SelectoUpdato.update(%{assignee_id: 7})
    |> SelectoUpdato.filter({:id, 1})
  end

  defp update_operation(domain) do
    domain
    |> SelectoUpdato.new()
    |> SelectoUpdato.update(%{name: "updated"})
  end

  defp domain(opts \\ []) do
    returning = Keyword.get(opts, :returning, :none)

    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name, :assignee_id],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          assignee_id: %{type: :integer, choice_source: :assignees}
        },
        associations: %{}
      },
      schemas: %{},
      choice_sources: %{
        assignees: %{domain: :assignees, value_field: :id, label_field: :name}
      },
      writes: %{
        operations: %{
          insert: %{enabled: true, returning: returning},
          update: %{
            enabled: true,
            require_filter: true,
            expected_cardinality: {:exactly, 1},
            returning: returning
          }
        },
        fields: %{
          name: %{insertable: true, updatable: true},
          assignee_id: %{updatable: true}
        }
      }
    }
  end
end
