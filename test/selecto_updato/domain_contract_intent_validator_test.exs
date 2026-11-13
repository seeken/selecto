defmodule SelectoUpdato.DomainContractIntentValidatorTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.Choices
  alias Selecto.Domain.Choices.Request
  alias SelectoUpdato.DomainContract

  test "accepts operation intents whose fields are writable for the operation" do
    assert %{valid?: true, errors: []} =
             SelectoUpdato.validate_domain_intent(write_domain(), %{
               operation: :insert,
               attrs: %{title: "Review", state: "draft"}
             })

    assert %{valid?: true, errors: []} =
             SelectoUpdato.validate_domain_intent(write_domain(), %{
               operation: "update",
               changes: %{"title" => "Ready"}
             })
  end

  test "appends choice-source diagnostics when a membership resolver is configured" do
    test_pid = self()
    choice_filters = [{"tenant_id", 12}]

    resolver = fn %Request{} = request ->
      send(test_pid, {:choice_request, request})

      if request.value == "draft" do
        Choices.valid(:choice_valid)
      else
        Choices.invalid(:choice_filtered, user_message: "State is not available")
      end
    end

    assert %{valid?: true, errors: []} =
             DomainContract.validate_intent(
               choice_domain(),
               %{operation: :insert, attrs: %{title: "Review", state: "draft"}},
               actor: :analyst,
               tenant: "tenant-12",
               choice_source_filters: choice_filters,
               choice_source_context: %{surface: :test},
               choice_source_membership_resolver: resolver
             )

    assert_receive {:choice_request, request}
    assert request.field == "state"
    assert request.value == "draft"
    assert request.choice_source == :state_choices
    assert request.actor == :analyst
    assert request.tenant == "tenant-12"
    assert request.filters == choice_filters
    assert request.context == %{surface: :test}

    assert %{valid?: false, errors: [error]} =
             DomainContract.validate_intent(
               choice_domain(),
               %{operation: :insert, attrs: %{title: "Review", state: "hidden"}},
               choice_source_membership_resolver: resolver
             )

    assert error.code == :choice_source_invalid
    assert error.path == ["attrs"]
    assert error.field == "state"
    assert error.choice_source == "state_choices"
    assert error.reason == "choice_filtered"
    assert error.message == "State is not available"
  end

  test "rejects operations not exposed by the contract" do
    assert %{valid?: false, errors: [error]} =
             DomainContract.validate_intent(write_domain(), %{operation: :delete})

    assert error.code == :operation_not_found
    assert error.path == "operation"
    assert error.value == "delete"
    assert error.allowed == ["insert", "update"]
  end

  test "rejects non-writable fields for an operation" do
    assert %{valid?: false, errors: [error]} =
             DomainContract.validate_intent(write_domain(), %{
               operation: :insert,
               fields: [:title, :reviewed_at]
             })

    assert error.code == :field_not_insertable
    assert error.field == "reviewed_at"
  end

  test "rejects unknown write fields" do
    assert %{valid?: false, errors: [error]} =
             DomainContract.validate_intent(write_domain(), %{
               operation: :update,
               changes: %{missing: "value"}
             })

    assert error.code == :field_not_found
    assert error.field == "missing"
    assert error.allowed == ["reviewed_at", "state", "title"]
  end

  test "accepts and rejects action intents from the contract" do
    assert {:ok, contract, _diagnostics} = DomainContract.build(action_domain())

    assert %{valid?: true, errors: []} =
             DomainContract.validate_intent(contract, %{action: :approve})

    assert %{valid?: false, errors: [error]} =
             DomainContract.validate_intent(contract, %{"action" => "archive"})

    assert error.code == :action_not_found
    assert error.allowed == ["approve"]
  end

  test "requires an operation or action target" do
    assert %{valid?: false, errors: [error]} =
             DomainContract.validate_intent(write_domain(), %{fields: [:title]})

    assert error.code == :missing_intent_target
  end

  defp action_domain do
    write_domain()
    |> Map.put(:actions, %{
      approve: %{
        type: :transition,
        transition: %{field: :state, from: :draft, to: :approved},
        execution: %{kind: :updato, operation: :update, set: %{state: :approved}}
      }
    })
  end

  defp choice_domain do
    write_domain()
    |> put_in([:source, :columns, :state], %{
      type: :string,
      label: "State",
      choice_source: :state_choices,
      reference: %{
        choice_source: :state_choices,
        value_source: :state,
        caption_source: :label
      }
    })
    |> Map.put(:choice_sources, %{
      state_choices: %{
        domain: :states,
        value_field: :state,
        label_field: :label,
        filters: [["eq", "states.active", true]],
        constraint_policy: %{domain_of_interest: :fail_closed}
      }
    })
  end

  defp write_domain do
    %{
      name: "Work Items",
      source: %{
        source_table: "work_items",
        primary_key: :id,
        fields: [:id, :title, :state, :reviewed_at],
        columns: %{
          id: %{type: :integer},
          title: %{type: :string},
          state: %{type: :string},
          reviewed_at: %{type: :utc_datetime}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true, require_filter: true}
        },
        fields: %{
          title: %{insertable: true, updatable: true},
          state: %{insertable: true, updatable: false},
          reviewed_at: %{insertable: false, updatable: true}
        },
        transitions: %{
          state: %{draft: [:approved]}
        }
      }
    }
  end
end
