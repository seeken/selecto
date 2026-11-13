defmodule SelectoUpdato.ActionPlannerTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.{ActionPlan, DomainContract, Operation, PlannedOperation}

  test "plans an updato action into a scoped update operation" do
    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(action_domain(), %{
               action: :mark_waiver_received,
               target: %{id: 42}
             })

    assert plan.action == "mark_waiver_received"
    assert plan.type == :detail_action
    assert plan.label == "Mark waiver received"
    assert plan.description == "Record that the registration waiver was received."
    assert plan.capability == "camp_registration.mark_waiver_received"
    assert plan.icon == :check

    assert plan.confirmation == %{
             message: "Mark this waiver as received?",
             required: true
           }

    assert plan.audit == %{
             event: "camp_registration.waiver_received",
             include_actor: true,
             include_inputs: true,
             include_target: true
           }

    assert plan.presentation == %{tone: :success}
    assert plan.operation == "update"
    assert plan.scope == "row"
    assert plan.filters == [{"id", 42}]
    assert plan.changes == %{waiver_received: true}
    assert plan.returning == :record
    assert plan.expected_cardinality == {:exactly, 1}

    assert plan.operation_intent == %{
             action: "mark_waiver_received",
             operation: "update",
             scope: "row",
             target: %{id: 42},
             filters: [%{field: "id", comparator: "eq", value: 42}],
             changes: %{waiver_received: true},
             returning: :record
           }

    assert %Operation{
             type: :update,
             filters: [{"id", 42}],
             changes: %{waiver_received: true},
             returning: :all,
             expected_cardinality: {:exactly, 1}
           } = authorized_operation(plan)

    assert %PlannedOperation{} = plan.operation_builder
  end

  test "plans canonical ecosystem actions without host execution" do
    assert {:ok, %ActionPlan{} = work_item_plan} =
             SelectoUpdato.plan_domain_action(Selecto.Domain.Examples.work_items(), %{
               action: :archive,
               target: %{id: 42},
               inputs: %{reason: "completed"}
             })

    assert work_item_plan.action == "archive"
    assert work_item_plan.capability == "work_items.archive"
    assert work_item_plan.filters == [{"id", 42}, {"state", "done"}]
    assert work_item_plan.changes == %{state: "archived"}
    assert work_item_plan.inputs["reason"] == "completed"

    assert {:ok, %ActionPlan{} = camp_plan} =
             SelectoUpdato.plan_domain_action(Selecto.Domain.Examples.camp_registrations(), %{
               action: :check_in_camper,
               target: %{id: 7},
               inputs: %{
                 documents_complete: "true",
                 checked_in_at: "2026-05-18T14:30:00Z"
               }
             })

    assert camp_plan.action == "check_in_camper"
    assert camp_plan.capability == "camp.check_in"
    assert camp_plan.filters == [{"id", 7}, {"status", "registered"}]
    assert camp_plan.changes == %{status: "checked_in"}
    assert camp_plan.inputs["documents_complete"] == true
    assert camp_plan.inputs["checked_in_at"] == "2026-05-18T14:30:00Z"
  end

  test "accepts explicit filter scopes" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(action_domain(), %{
               action: "mark_waiver_received",
               filters: [
                 %{"field" => "tenant_id", "value" => 7},
                 {"id", 12}
               ]
             })

    assert plan.filters == [{"tenant_id", 7}, {"id", 12}]

    assert plan.operation_intent.filters == [
             %{field: "tenant_id", comparator: "eq", value: 7},
             %{field: "id", comparator: "eq", value: 12}
           ]

    assert plan.scope == "row"
  end

  test "plans a bulk update action from a non-primary-key filter scope" do
    domain =
      action_domain()
      |> put_in([:writes, :operations, :update], %{
        enabled: true,
        require_filter: true,
        bulk: true,
        returning: :count
      })
      |> put_in([:actions, :bulk_mark_waiver_received], %{
        type: :bulk_action,
        scope: :bulk,
        capability: "camp_registration.bulk_mark_waiver_received",
        execution: %{
          kind: :updato,
          operation: :update,
          set: %{waiver_received: true}
        }
      })
      |> put_in([:capabilities, "camp_registration.bulk_mark_waiver_received"], %{
        operations: [:action, :update],
        action: :bulk_mark_waiver_received
      })

    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :bulk_mark_waiver_received,
               filters: [%{field: :status, value: "registered"}]
             })

    assert plan.scope == "bulk"
    assert plan.filters == [{"status", "registered"}]
    assert plan.changes == %{waiver_received: true}
    assert plan.returning == :count
    assert plan.operation_intent.scope == "bulk"

    assert %Operation{
             type: :update,
             filters: [{"status", "registered"}],
             changes: %{waiver_received: true},
             returning: :none
           } = authorized_operation(plan)
  end

  test "preserves a concrete bulk target and derives exact cardinality" do
    domain =
      action_domain()
      |> put_in([:writes, :operations, :update], %{
        enabled: true,
        require_filter: true,
        bulk: true,
        returning: :count
      })
      |> put_in([:actions, :bulk_mark_waiver_received], %{
        type: :bulk_action,
        scope: :bulk,
        capability: "camp_registration.bulk_mark_waiver_received",
        execution: %{
          kind: :updato,
          operation: :update,
          set: %{waiver_received: true}
        }
      })
      |> put_in([:capabilities, "camp_registration.bulk_mark_waiver_received"], %{
        operations: [:action, :update],
        action: :bulk_mark_waiver_received
      })

    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :bulk_mark_waiver_received,
               target: %{ids: ["41", "42", "43"]}
             })

    assert plan.scope == "bulk"
    assert plan.filters == [{"id", :in, [41, 42, 43]}]
    assert plan.expected_cardinality == {:exactly, 3}

    assert %Operation{
             filters: [{"id", :in, [41, 42, 43]}],
             expected_cardinality: {:exactly, 3}
           } = authorized_operation(plan)
  end

  test "allows a row action to opt into concrete bulk selection" do
    domain =
      action_domain()
      |> put_in([:writes, :operations, :update, :bulk], true)
      |> put_in([:actions, :mark_waiver_received, :bulk], %{enabled: true})

    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :mark_waiver_received,
               target: %{ids: [41, 42]}
             })

    assert plan.scope == "bulk"
    assert plan.target == %{ids: [41, 42]}
    assert plan.expected_cardinality == {:exactly, 2}
  end

  test "enforces published action selection cardinality for concrete ids" do
    domain =
      action_domain()
      |> put_in([:writes, :operations, :update, :bulk], true)
      |> put_in([:actions, :mark_waiver_received, :bulk], %{enabled: true})
      |> put_in([:actions, :mark_waiver_received, :selection], %{
        mode: :rows,
        min_rows: 2,
        max_rows: 3
      })

    assert {:error, %{code: :action_cardinality_mismatch, minimum: 2, actual: 1}} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :mark_waiver_received,
               target: %{ids: [41]}
             })

    assert {:error, %{code: :action_cardinality_mismatch, maximum: 3, actual: 4}} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :mark_waiver_received,
               target: %{ids: [41, 42, 43, 44]}
             })
  end

  test "rejects empty and duplicate bulk target ids" do
    domain =
      action_domain()
      |> put_in([:writes, :operations, :update, :bulk], true)
      |> put_in([:actions, :mark_waiver_received, :scope], :bulk)
      |> put_in([:actions, :mark_waiver_received, :type], :bulk_action)

    for ids <- [[], [42, 42]] do
      assert {:error, %{code: :invalid_action_target}} =
               SelectoUpdato.plan_domain_action(domain, %{
                 action: :mark_waiver_received,
                 target: %{ids: ids}
               })
    end
  end

  test "rejects row-scoped actions planned against bulk filters" do
    assert {:error, error} =
             SelectoUpdato.plan_domain_action(action_domain(), %{
               action: :mark_waiver_received,
               filters: [%{field: :status, value: "registered"}]
             })

    assert error.code == :action_scope_mismatch
    assert error.declared_scope == "row"
    assert error.planned_scope == "bulk"
  end

  test "rejects bulk action planning when the write operation is not bulk-enabled" do
    domain =
      action_domain()
      |> put_in([:actions, :bulk_mark_waiver_received], %{
        type: :bulk_action,
        scope: :bulk,
        capability: "camp_registration.bulk_mark_waiver_received",
        execution: %{
          kind: :updato,
          operation: :update,
          set: %{waiver_received: true}
        }
      })
      |> put_in([:capabilities, "camp_registration.bulk_mark_waiver_received"], %{
        operations: [:action, :update],
        action: :bulk_mark_waiver_received
      })

    assert {:error, error} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :bulk_mark_waiver_received,
               filters: [%{field: :status, value: "registered"}]
             })

    assert error.code == :bulk_action_operation_not_enabled
    assert error.path == [:operations, "update", :bulk]
  end

  test "plans against JSON-safe contract input with opaque nil-operation provenance" do
    assert {:ok, document, _diagnostics} =
             DomainContract.json_document(action_domain(), generated_at: "2026-05-07T00:00:00Z")

    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(document, %{
               "action" => "mark_waiver_received",
               "target" => %{"id" => 43}
             })

    assert plan.action == "mark_waiver_received"
    assert plan.filters == [{"id", 43}]
    assert plan.changes == %{"waiver_received" => true}
    assert plan.returning == "record"
    assert %PlannedOperation{} = plan.operation_builder
  end

  test "merges declared action preconditions into the mandatory operation filters" do
    domain =
      action_domain()
      |> put_in([:actions, :mark_waiver_received, :preconditions], [
        {:neq, :status, "cancelled"},
        %{field: :tenant_id, comparator: :in, value: [7, 9]}
      ])

    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :mark_waiver_received,
               target: %{id: 42}
             })

    assert plan.filters == [
             {"id", 42},
             {"status", :neq, "cancelled"},
             {"tenant_id", :in, [7, 9]}
           ]

    assert plan.preconditions == [
             %{
               type: :filter,
               field: "status",
               comparator: :neq,
               value: "cancelled",
               reason: :action_precondition
             },
             %{
               type: :filter,
               field: "tenant_id",
               comparator: :in,
               value: [7, 9],
               reason: :action_precondition
             }
           ]

    assert %Operation{
             type: :update,
             filters: [
               {"id", 42},
               {"status", :neq, "cancelled"},
               {"tenant_id", :in, [7, 9]}
             ]
           } = authorized_operation(plan)
  end

  test "rejects malformed and unknown guards through authored and JSON contract paths" do
    for {guards, code} <- [
          {%{}, :invalid_action_preconditions},
          {[{"missing", true}], :action_precondition_field_not_found},
          {[{"owner.id", 1}], :action_precondition_field_not_found}
        ] do
      domain = put_in(action_domain(), [:actions, :mark_waiver_received, :preconditions], guards)
      assert {:ok, document, _diagnostics} = DomainContract.json_document(domain)

      for input <- [domain, document] do
        assert {:error, error} =
                 SelectoUpdato.plan_domain_action(input, %{
                   action: :mark_waiver_received,
                   target: 42
                 })

        assert error.code == code
      end
    end
  end

  test "preserves declared action preconditions through the JSON contract" do
    domain =
      action_domain()
      |> put_in([:actions, :mark_waiver_received, :preconditions], [
        {:gte, :tenant_id, 7}
      ])

    assert {:ok, document, _diagnostics} =
             DomainContract.json_document(domain, generated_at: "2026-09-03T00:00:00Z")

    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(document, %{
               "action" => "mark_waiver_received",
               "target" => %{"id" => 42}
             })

    assert plan.filters == [{"id", 42}, {"tenant_id", :gte, 7}]

    assert plan.preconditions == [
             %{
               type: :filter,
               field: "tenant_id",
               comparator: :gte,
               value: 7,
               reason: :action_precondition
             }
           ]
  end

  test "declared guards survive caller filters and remain alongside transition preconditions" do
    domain =
      check_in_domain()
      |> put_in([:actions, :check_in_camper, :preconditions], [{:waiver_received, true}])

    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :check_in_camper,
               target: 42,
               inputs: %{documents_complete: true},
               preconditions: [],
               filters: [%{field: :waiver_received, value: false}]
             })

    assert plan.filters == [
             {"waiver_received", false},
             {"id", 42},
             {"waiver_received", true},
             {"status", "registered"}
           ]

    assert [%{type: :filter}, %{type: :field_equals}] = plan.preconditions
    assert plan.operation_intent.preconditions == plan.preconditions
  end

  test "fails closed when preconditions would be ignored by insert or upsert" do
    for operation <- [:insert, :upsert] do
      domain =
        action_domain()
        |> put_in([:writes, :operations, operation], %{enabled: true})
        |> put_in([:actions, :mark_waiver_received, :execution, :operation], operation)
        |> put_in([:actions, :mark_waiver_received, :preconditions], [{:status, "registered"}])

      assert {:error, error} =
               SelectoUpdato.plan_domain_action(domain, %{
                 action: :mark_waiver_received,
                 target: 42
               })

      assert error.code == :action_preconditions_unsupported_operation
    end
  end

  test "fails closed for relational preconditions on event-stream actions" do
    domain =
      event_stream_domain()
      |> put_in([:actions, :propose_substitution, :preconditions], [{:status, "registered"}])

    assert {:error, error} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :propose_substitution,
               target: %{id: "order-7"},
               inputs: %{expected_version: 2, unavailable_sku: "X", substitute_sku: "Y"}
             })

    assert error.code == :action_preconditions_unsupported_executor
  end

  test "selects an action variant from normalized inputs" do
    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(check_in_domain(), %{
               action: :check_in_camper,
               target: %{id: 42},
               inputs: %{documents_complete: "true"}
             })

    assert plan.variant == "standard_check_in"
    assert plan.inputs["documents_complete"] == true
    assert plan.inputs["checked_in_at"] == {:system, :now}
    assert plan.changes == %{checked_in_at: {:system, :now}, status: "checked_in"}

    assert plan.preconditions == [
             %{
               type: :field_equals,
               field: "status",
               value: "registered",
               reason: :transition_from,
               transition: %{field: "status", from: "registered", to: "checked_in"}
             }
           ]

    assert plan.operation_intent.inputs == %{
             "checked_in_at" => {:system, :now},
             "documents_complete" => true
           }

    assert plan.operation_intent.variant == "standard_check_in"
    assert plan.operation_intent.preconditions == plan.preconditions

    assert plan.operation_intent.changes == %{
             checked_in_at: {:system, :now},
             status: "checked_in"
           }
  end

  test "normalizes selected variant collection patches" do
    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(check_in_domain(), %{
               action: :check_in_camper,
               target: %{id: 42},
               inputs: %{
                 documents_complete: false,
                 follow_up_note: "Guardian will bring the waiver.",
                 missing_documents: [
                   %{
                     op: "add",
                     client_id: "tmp-waiver",
                     position: 1,
                     document_type: "waiver",
                     note: "Needs signature"
                   },
                   %{
                     op: "reorder",
                     id: 17,
                     position: 2
                   }
                 ]
               }
             })

    assert plan.variant == "missing_documents"

    assert plan.collection_patches == %{
             "missing_documents" => %{
               from_input: "missing_documents",
               target: {:relationship, "registration_missing_documents"},
               strategy: "patch",
               identity: "id",
               order_field: "position",
               entries: [
                 %{
                   "op" => "add",
                   "client_id" => "tmp-waiver",
                   "position" => 1,
                   "document_type" => "waiver",
                   "note" => "Needs signature",
                   "resolved" => false
                 },
                 %{
                   "op" => "reorder",
                   "id" => 17,
                   "position" => 2
                 }
               ]
             }
           }

    assert plan.collection_operations == %{
             "missing_documents" => %{
               from_input: "missing_documents",
               target: {:relationship, "registration_missing_documents"},
               target_kind: :relationship,
               relationship: "registration_missing_documents",
               strategy: "patch",
               ownership: :owned,
               requires_host_scope: true,
               operations: [
                 %{
                   action: :insert,
                   source_op: "add",
                   client_identity: "tmp-waiver",
                   attrs: %{
                     "position" => 1,
                     "document_type" => "waiver",
                     "note" => "Needs signature",
                     "resolved" => false
                   }
                 },
                 %{
                   action: :update,
                   source_op: "reorder",
                   identity: 17,
                   changes: %{"position" => 2}
                 }
               ]
             }
           }

    assert plan.operation_intent.collection_patches == plan.collection_patches
    assert plan.operation_intent.collection_operations == plan.collection_operations
  end

  test "rejects collection operations disallowed by the target relationship" do
    domain =
      check_in_domain()
      |> put_in(
        [:writes, :relationships, :registration_missing_documents, :allowed_ops],
        [:insert]
      )

    assert {:error, error} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :check_in_camper,
               target: %{id: 42},
               inputs: %{
                 documents_complete: false,
                 follow_up_note: "Nope",
                 missing_documents: [
                   %{
                     op: "reorder",
                     id: 17,
                     position: 1
                   }
                 ]
               }
             })

    assert error.code == :collection_operation_not_allowed_for_target
    assert error.path == [:collection_patches, "missing_documents", :entries, 0, :op]
    assert error.target_operation == "update"
  end

  test "rejects missing selected variant inputs" do
    assert {:error, error} =
             SelectoUpdato.plan_domain_action(check_in_domain(), %{
               action: :check_in_camper,
               target: %{id: 42},
               inputs: %{documents_complete: false, missing_documents: []}
             })

    assert error.code == :missing_required_action_input
    assert error.path == [:intent, :inputs, "follow_up_note"]
  end

  test "rejects disallowed collection operations" do
    assert {:error, error} =
             SelectoUpdato.plan_domain_action(check_in_domain(), %{
               action: :check_in_camper,
               target: %{id: 42},
               inputs: %{
                 documents_complete: false,
                 follow_up_note: "Nope",
                 missing_documents: [
                   %{
                     op: "replace",
                     client_id: "tmp-waiver",
                     position: 1,
                     document_type: "waiver"
                   }
                 ]
               }
             })

    assert error.code == :collection_operation_not_allowed
    assert error.path == [:intent, :inputs, "missing_documents", 0, "op"]
  end

  test "selects an execution case from normalized inputs" do
    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(case_action_domain(), %{
               action: :toggle_waiver,
               target: %{id: 42},
               inputs: %{received: "false"}
             })

    assert plan.inputs == %{"received" => false}
    assert plan.changes == %{waiver_received: false}
  end

  test "rejects execution input references that are not available" do
    domain =
      action_domain()
      |> put_in([:actions, :mark_waiver_received, :execution, :set], %{
        waiver_received: {:input, :missing_input}
      })

    assert {:error, error} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :mark_waiver_received,
               target: 42
             })

    assert error.code == :missing_action_input_reference
    assert error.path == [:execution, :set, "waiver_received"]
    assert error.input == "missing_input"
  end

  test "applies a small transform pipeline to execution input references" do
    domain =
      action_domain()
      |> put_in([:source, :fields], [:id, :tenant_id, :status, :waiver_received, :note])
      |> put_in([:source, :columns, :note], %{type: :string})
      |> put_in([:writes, :fields, :note], %{insertable: true, updatable: true})
      |> put_in([:actions, :record_note], %{
        capability: "camp_registration.record_note",
        inputs: %{
          note: %{type: :string, required: true}
        },
        execution: %{
          kind: :updato,
          operation: :update,
          set: %{note: {:input, :note, [:trim, :blank_to_nil]}}
        }
      })
      |> put_in([:capabilities, "camp_registration.record_note"], %{
        operations: [:action, :update],
        action: :record_note
      })

    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :record_note,
               target: %{id: 42},
               inputs: %{note: "  Bring waiver  "}
             })

    assert plan.changes == %{note: "Bring waiver"}
  end

  test "applies JSON-safe input transform placeholders" do
    assert {:ok, document, _diagnostics} =
             action_domain()
             |> put_in([:source, :fields], [:id, :tenant_id, :status, :waiver_received, :note])
             |> put_in([:source, :columns, :note], %{type: :string})
             |> put_in([:writes, :fields, :note], %{insertable: true, updatable: true})
             |> put_in([:actions, :record_note], %{
               capability: "camp_registration.record_note",
               inputs: %{note: %{type: :string, required: true}},
               execution: %{
                 kind: :updato,
                 operation: :update,
                 set: %{note: ["input", "note", ["trim", "downcase"]]}
               }
             })
             |> put_in([:capabilities, "camp_registration.record_note"], %{
               operations: [:action, :update],
               action: :record_note
             })
             |> DomainContract.json_document(generated_at: "2026-05-08T00:00:00Z")

    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(document, %{
               "action" => "record_note",
               "target" => %{"id" => 42},
               "inputs" => %{"note" => "  BRING WAIVER  "}
             })

    assert plan.changes == %{"note" => "bring waiver"}
  end

  test "resolves fallback expressions in execution templates" do
    domain =
      action_domain()
      |> put_in([:source, :fields], [:id, :tenant_id, :status, :waiver_received, :note])
      |> put_in([:source, :columns, :note], %{type: :string})
      |> put_in([:writes, :fields, :note], %{insertable: true, updatable: true})
      |> put_in([:actions, :record_note], %{
        capability: "camp_registration.record_note",
        inputs: %{note: %{type: :string, required: false}},
        execution: %{
          kind: :updato,
          operation: :update,
          set: %{
            note:
              {:fallback,
               [
                 {:input, :note, [:trim, :blank_to_nil]},
                 "No note"
               ]}
          }
        }
      })
      |> put_in([:capabilities, "camp_registration.record_note"], %{
        operations: [:action, :update],
        action: :record_note
      })

    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :record_note,
               target: %{id: 42},
               inputs: %{note: "   "}
             })

    assert plan.changes == %{note: "No note"}
  end

  test "resolves trusted context expressions from planner opts" do
    domain =
      action_domain()
      |> put_in([:source, :fields], [
        :id,
        :tenant_id,
        :status,
        :waiver_received,
        :reviewed_by_id
      ])
      |> put_in([:source, :columns, :reviewed_by_id], %{type: :integer})
      |> put_in([:writes, :fields, :reviewed_by_id], %{insertable: true, updatable: true})
      |> put_in([:actions, :record_review], %{
        capability: "camp_registration.record_review",
        execution: %{
          kind: :updato,
          operation: :update,
          set: %{reviewed_by_id: {:context, :actor_id}}
        }
      })
      |> put_in([:capabilities, "camp_registration.record_review"], %{
        operations: [:action, :update],
        action: :record_review
      })

    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(
               domain,
               %{
                 action: :record_review,
                 target: %{id: 42},
                 inputs: %{actor_id: 999},
                 context: %{actor_id: 999}
               },
               trusted_context: %{actor_id: 17}
             )

    assert plan.changes == %{reviewed_by_id: 17}
  end

  test "does not trust context values from the action intent" do
    domain =
      action_domain()
      |> put_in([:source, :fields], [
        :id,
        :tenant_id,
        :status,
        :waiver_received,
        :reviewed_by_id
      ])
      |> put_in([:source, :columns, :reviewed_by_id], %{type: :integer})
      |> put_in([:writes, :fields, :reviewed_by_id], %{insertable: true, updatable: true})
      |> put_in([:actions, :record_review], %{
        capability: "camp_registration.record_review",
        execution: %{
          kind: :updato,
          operation: :update,
          set: %{reviewed_by_id: {:context, :actor_id}}
        }
      })
      |> put_in([:capabilities, "camp_registration.record_review"], %{
        operations: [:action, :update],
        action: :record_review
      })

    assert {:error, error} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :record_review,
               target: %{id: 42},
               inputs: %{actor_id: 999},
               context: %{actor_id: 999}
             })

    assert error.code == :missing_action_context_reference
    assert error.path == [:execution, :set, "reviewed_by_id"]
    assert error.context == "actor_id"
  end

  test "resolves arithmetic and date transforms in execution templates" do
    domain =
      action_domain()
      |> put_in([:source, :fields], [
        :id,
        :tenant_id,
        :status,
        :waiver_received,
        :priority_score,
        :follow_up_on
      ])
      |> put_in([:source, :columns, :priority_score], %{type: :integer})
      |> put_in([:source, :columns, :follow_up_on], %{type: :date})
      |> put_in([:writes, :fields, :priority_score], %{insertable: true, updatable: true})
      |> put_in([:writes, :fields, :follow_up_on], %{insertable: true, updatable: true})
      |> put_in([:actions, :schedule_follow_up], %{
        capability: "camp_registration.schedule_follow_up",
        inputs: %{
          base_score: %{type: :integer, required: true},
          preferred_date: %{type: :date, required: true}
        },
        execution: %{
          kind: :updato,
          operation: :update,
          set: %{
            priority_score: {:input, :base_score, [{:add, 3}, {:multiply, 2}]},
            follow_up_on: ["input", "preferred_date", [["date_add", 7, "day"]]]
          }
        }
      })
      |> put_in([:capabilities, "camp_registration.schedule_follow_up"], %{
        operations: [:action, :update],
        action: :schedule_follow_up
      })

    assert {:ok, %ActionPlan{} = plan} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :schedule_follow_up,
               target: %{id: 42},
               inputs: %{base_score: "4", preferred_date: "2026-05-08"}
             })

    assert plan.changes == %{priority_score: 14, follow_up_on: "2026-05-15"}
  end

  test "rejects unsupported input transforms" do
    domain =
      action_domain()
      |> put_in([:source, :fields], [:id, :tenant_id, :status, :waiver_received, :note])
      |> put_in([:source, :columns, :note], %{type: :string})
      |> put_in([:writes, :fields, :note], %{insertable: true, updatable: true})
      |> put_in([:actions, :record_note], %{
        capability: "camp_registration.record_note",
        inputs: %{note: %{type: :string, required: true}},
        execution: %{
          kind: :updato,
          operation: :update,
          set: %{note: {:input, :note, [:rot13]}}
        }
      })
      |> put_in([:capabilities, "camp_registration.record_note"], %{
        operations: [:action, :update],
        action: :record_note
      })

    assert {:error, error} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :record_note,
               target: %{id: 42},
               inputs: %{note: "Bring waiver"}
             })

    assert error.code == :unsupported_action_input_transform
    assert error.path == [:execution, :set, "note"]
    assert error.transform == "rot13"
  end

  test "rejects action transitions that do not update the transition field to the target" do
    domain =
      check_in_domain()
      |> put_in(
        [:actions, :check_in_camper, :variants, Access.at(0), :execution, :set, :status],
        "waitlisted"
      )

    assert {:error, error} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :check_in_camper,
               target: %{id: 42},
               inputs: %{documents_complete: true}
             })

    assert error.code == :action_transition_change_mismatch
    assert error.path == [:execution, :set, "status"]
    assert error.expected == "checked_in"
    assert error.value == "waitlisted"
  end

  test "rejects action transitions disallowed by writes.transitions" do
    domain =
      check_in_domain()
      |> put_in([:writes, :transitions, :status], %{
        "registered" => ["cancelled"]
      })

    assert {:error, error} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :check_in_camper,
               target: %{id: 42},
               inputs: %{documents_complete: true}
             })

    assert error.code == :action_transition_not_allowed
    assert error.field == "status"
    assert error.from == "registered"
    assert error.to == "checked_in"
  end

  test "requires a target or filter when the operation contract requires one" do
    assert {:error, error} =
             SelectoUpdato.plan_domain_action(action_domain(), %{
               action: :mark_waiver_received
             })

    assert error.code == :missing_required_filter
    assert error.path == [:intent, :filters]
  end

  test "rejects unsupported action executors" do
    domain =
      action_domain()
      |> put_in([:actions, :mark_waiver_received, :execution, :kind], :external)

    assert {:error, error} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :mark_waiver_received,
               target: 42
             })

    assert error.code == :unsupported_action_executor
  end

  test "plans an event-stream action without materializing a SQL operation" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(event_stream_domain(), %{
               action: :propose_substitution,
               target: %{id: "order-7"},
               inputs: %{
                 expected_version: 2,
                 unavailable_sku: "X",
                 substitute_sku: "Y"
               }
             })

    assert plan.action == "propose_substitution"
    assert plan.operation == nil
    assert %PlannedOperation{} = plan.operation_builder
    assert plan.scope == "row"
    assert plan.inputs["expected_version"] == 2

    assert plan.operation_intent == %{
             executor: "event_stream",
             aggregate: :fulfillment_order,
             bounded_context: :fulfillment,
             stream_id: {:target, :id},
             consistency: :expected_version,
             possible_events: ["order_substitution_proposed"]
           }

    resolver = fn _request, _context, _opts -> :enabled end

    assert {:ok, authorized, _decision, grant} =
             SelectoUpdato.ActionAuthorization.authorize_and_issue(
               plan,
               :execute,
               %{tenant_id: "smolco"},
               capability_resolver: resolver
             )

    assert authorized.operation_builder == nil
    assert authorized.authorization_grant == grant
    SelectoUpdato.ActionAuthorization.revoke(grant)
  end

  test "rejects actions that produce non-writable operation fields" do
    domain =
      action_domain()
      |> put_in([:actions, :mark_waiver_received, :execution, :set], %{status: :approved})

    assert {:error, error} =
             SelectoUpdato.plan_domain_action(domain, %{
               action: :mark_waiver_received,
               target: 42
             })

    assert error.code == :invalid_action_operation_intent
    assert %{valid?: false, errors: [field_error]} = error.validation
    assert field_error.code == :field_not_updatable
    assert field_error.field == "status"
  end

  defp authorized_operation(plan) do
    resolver = fn _request, _context, _opts -> :enabled end

    {:ok, authorized_plan, _decision, grant} =
      SelectoUpdato.ActionAuthorization.authorize_and_issue(
        plan,
        :preview,
        %{},
        capability_resolver: resolver
      )

    SelectoUpdato.ActionAuthorization.revoke(grant)
    authorized_plan.operation_builder
  end

  defp action_domain do
    %{
      name: "Camp Registrations",
      source: %{
        source_table: "camp_registrations",
        primary_key: :id,
        fields: [:id, :tenant_id, :status, :waiver_received],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          status: %{type: :string},
          waiver_received: %{type: :boolean}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          update: %{enabled: true, require_filter: true, returning: :record}
        },
        fields: %{
          status: %{insertable: true, updatable: false},
          waiver_received: %{insertable: true, updatable: true}
        }
      },
      capabilities: %{
        "camp_registration.mark_waiver_received" => %{
          operations: [:action, :update],
          action: :mark_waiver_received
        }
      },
      actions: %{
        mark_waiver_received: %{
          type: :detail_action,
          label: "Mark waiver received",
          description: "Record that the registration waiver was received.",
          capability: "camp_registration.mark_waiver_received",
          icon: :check,
          confirmation: %{required: true, message: "Mark this waiver as received?"},
          audit: %{
            event: "camp_registration.waiver_received",
            include_actor: true,
            include_inputs: true,
            include_target: true
          },
          presentation: %{tone: :success},
          execution: %{
            kind: :updato,
            operation: :update,
            set: %{waiver_received: true}
          }
        }
      }
    }
  end

  defp event_stream_domain do
    action_domain()
    |> Map.put(:events, %{
      order_substitution_proposed: %{
        schema_version: 1,
        data: %{
          unavailable_sku: %{type: :string, required: true},
          substitute_sku: %{type: :string, required: true}
        }
      }
    })
    |> put_in([:actions, :propose_substitution], %{
      type: :detail_action,
      inputs: %{
        expected_version: %{type: :integer, required: true},
        unavailable_sku: %{type: :string, required: true},
        substitute_sku: %{type: :string, required: true}
      },
      execution: %{
        kind: :event_stream,
        aggregate: :fulfillment_order,
        bounded_context: :fulfillment,
        stream_id: {:target, :id},
        consistency: :expected_version,
        possible_events: [:order_substitution_proposed]
      }
    })
  end

  defp check_in_domain do
    action_domain()
    |> put_in([:source, :fields], [
      :id,
      :tenant_id,
      :status,
      :waiver_received,
      :checked_in_at,
      :medical_form_received
    ])
    |> put_in([:source, :columns, :checked_in_at], %{type: :utc_datetime})
    |> put_in([:source, :columns, :medical_form_received], %{type: :boolean})
    |> put_in([:writes, :fields, :status], %{insertable: true, updatable: true})
    |> put_in([:writes, :fields, :checked_in_at], %{insertable: false, updatable: true})
    |> put_in([:writes, :fields, :medical_form_received], %{insertable: false, updatable: true})
    |> put_in([:writes, :transitions], %{
      status: %{"registered" => ["checked_in", "cancelled"], "checked_in" => []}
    })
    |> put_in([:writes, :relationships], %{
      registration_missing_documents: %{
        writable: true,
        cardinality: :many,
        allowed_ops: [:insert, :update, :delete],
        ownership: :owned,
        foreign_key: :camp_registration_id
      }
    })
    |> put_in([:actions, :check_in_camper], %{
      type: :transition,
      capability: "camp_registration.check_in",
      transition: %{field: :status, from: "registered", to: "checked_in"},
      inputs: %{
        checked_in_at: %{type: :utc_datetime, required: false, default: {:system, :now}},
        documents_complete: %{type: :boolean, required: true, discriminator: true},
        arrival_notes: %{type: :string, required: false}
      },
      variants: [
        %{
          id: :standard_check_in,
          when: %{documents_complete: true},
          execution: %{
            kind: :updato,
            operation: :update,
            set: %{status: "checked_in", checked_in_at: {:input, :checked_in_at}}
          }
        },
        %{
          id: :missing_documents,
          when: %{documents_complete: false},
          inputs: %{
            missing_documents: %{
              type: :collection,
              representation: :patch,
              identity: %{field: :id, client_field: :client_id},
              order: %{field: :position, mode: :dense_integer},
              allowed_ops: [:add, :remove, :update, :reorder],
              min_items: 1,
              item: %{
                document_type: %{
                  type: :enum,
                  values: ["medical_form", "waiver", "payment"],
                  required: true
                },
                note: %{type: :string, required: false},
                resolved: %{type: :boolean, required: false, default: false}
              }
            },
            follow_up_note: %{type: :string, required: true}
          },
          execution: %{
            kind: :updato,
            operation: :update,
            set: %{status: "checked_in", medical_form_received: false},
            collection_patches: %{
              missing_documents: %{
                from_input: :missing_documents,
                target: {:relationship, :registration_missing_documents},
                strategy: :patch,
                identity: :id,
                order_field: :position
              }
            }
          }
        }
      ]
    })
    |> put_in([:capabilities, "camp_registration.check_in"], %{
      operations: [:action, :update],
      action: :check_in_camper
    })
  end

  defp case_action_domain do
    action_domain()
    |> put_in([:actions, :toggle_waiver], %{
      type: :detail_action,
      capability: "camp_registration.toggle_waiver",
      inputs: %{
        received: %{type: :boolean, required: true}
      },
      execution: %{
        kind: :updato,
        operation: :update,
        cases: [
          %{when: %{received: true}, set: %{waiver_received: {:input, :received}}},
          %{when: %{received: false}, set: %{waiver_received: {:input, :received}}}
        ]
      }
    })
    |> put_in([:capabilities, "camp_registration.toggle_waiver"], %{
      operations: [:action, :update],
      action: :toggle_waiver
    })
  end
end
