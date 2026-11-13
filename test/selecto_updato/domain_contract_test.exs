defmodule SelectoUpdato.DomainContractTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain
  alias SelectoUpdato.DomainContract

  defmodule HookRefs do
    def tag_changeset(changeset), do: changeset
    def tag_changeset_with_context(changeset, _context, _label), do: changeset
  end

  test "projects a minimal write domain without executing anything" do
    {:ok, contract, diagnostics} = SelectoUpdato.domain_contract(write_domain())

    assert contract.contract_version == 1
    assert contract.projection == :updato_write_contract
    assert contract.name == "Work Items"
    assert :writes in diagnostics.proposed_sections

    assert [
             %{id: "insert", enabled: true, returning: :all},
             %{id: "update", enabled: true, require_filter: true}
           ] = contract.operations

    assert [
             %{
               id: "state",
               type: :string,
               insertable: true,
               updatable: true,
               required_on: ["insert"],
               choice_source: "state_choices",
               reference: %{
                 choice_source: :state_choices,
                 value_source: :state,
                 caption_source: :state_label
               }
             },
             %{id: "title", type: :string, insertable: true, updatable: true}
           ] = contract.fields

    assert [
             %{
               id: "comments",
               writable: true,
               cardinality: :many,
               allowed_ops: ["insert", "update"],
               foreign_key: "work_item_id"
             }
           ] = contract.relationships

    assert contract.validations == [{:required_if, :title, :state, "open"}]
    assert contract.constraints == [{:require_relationship, :comments}]

    assert [
             %{
               field: "state",
               transitions: [%{from: "draft", to: ["open"]}, %{from: "open", to: ["closed"]}]
             }
           ] = contract.transitions
  end

  test "accepts an already normalized Selecto domain" do
    {:ok, normalized, _diagnostics} = Domain.normalize(write_domain())

    assert {:ok, contract, diagnostics} = DomainContract.build(normalized)
    assert contract.projection == :updato_write_contract
    assert Enum.map(contract.fields, & &1.id) == ["state", "title"]
    refute diagnostics.schema_version_inferred
  end

  test "preserves authored action returning selections including invalid empty lists" do
    for returning <- [[:id, :title], :none, :all, [], false] do
      domain = put_in(json_domain(), [:actions, :approve, :execution, :returning], returning)
      assert {:ok, contract, _} = DomainContract.build(domain)
      assert hd(contract.actions).execution.returning == returning

      assert {:ok, normalized, _} = Domain.normalize(domain)
      assert {:ok, normalized_contract, _} = DomainContract.build(normalized)
      assert hd(normalized_contract.actions).execution.returning == returning
    end
  end

  test "makes structured errors safe for JSON payloads" do
    error = SelectoUpdato.Error.new(:invalid_domain, "invalid", details: %{field: :assignee_id})

    assert DomainContract.json_safe(error) == %{
             "type" => "invalid_domain",
             "message" => "invalid",
             "details" => %{"field" => "assignee_id"}
           }
  end

  test "builds portable write contracts for canonical ecosystem examples" do
    expectations = Selecto.Domain.Examples.Compatibility.expectations()

    for {name, domain} <- canonical_examples() do
      expected = Map.fetch!(expectations, name)

      assert :ok = SelectoUpdato.validate_domain(domain)
      assert {:ok, contract, diagnostics} = DomainContract.build(domain), Atom.to_string(name)
      assert diagnostics.errors == []

      assert contract.projection == :updato_write_contract
      assert contract.operations != []
      assert contract.fields != []
      assert contract.actions != []
      assert contract.capabilities != []
      assert contract.choice_sources != []
      assert contract.scope.tenant.required == true
      assert contract.scope.tenant.field == expected.tenant_scope.field
      assert contract.scope.tenant.required == expected.tenant_scope.required

      assert Enum.map(contract.operations, & &1.id) |> Enum.sort() == expected.write_operation_ids
      assert Enum.map(contract.fields, & &1.id) |> Enum.sort() == expected.write_field_ids
      assert Enum.map(contract.actions, & &1.id) |> Enum.sort() == expected.action_ids

      assert Map.new(contract.actions, fn action ->
               {action.id, Enum.map(action.inputs, & &1.id) |> Enum.sort()}
             end) == expected.action_inputs

      assert Map.new(contract.actions, &{&1.id, &1.capability}) == expected.action_capabilities

      assert {:ok, document, document_diagnostics} =
               DomainContract.json_document(domain, generated_at: "2026-05-18T00:00:00Z")

      assert document_diagnostics.errors == []
      assert document["projection"] == "updato_write_contract"
      assert document["generated_at"] == "2026-05-18T00:00:00Z"
      assert document["operations"] != []
      assert document["actions"] != []
      refute inspect(document) =~ "#Function"
    end
  end

  test "projects action-only domains separately from write operations" do
    domain =
      base_domain()
      |> Map.put(:actions, %{
        reopen: %{
          label: "Reopen work item",
          description: "Move a closed item back to open.",
          type: :transition,
          icon: :rotate_ccw,
          confirmation: %{required: true, message: "Reopen this item?"},
          audit: %{event: "work_item.reopened", include_actor: true},
          preconditions: [
            {:neq, :title, "Blocked"},
            %{field: :state, comparator: :in, value: [:closed, :reviewed]}
          ],
          transition: %{field: :state, from: :closed, to: :open},
          execution: %{kind: :updato, operation: :update, set: %{state: :open}}
        }
      })

    assert {:ok, contract, _diagnostics} = DomainContract.build(domain)

    assert contract.operations == []
    assert contract.fields == []

    assert [
             %{
               id: "reopen",
               label: "Reopen work item",
               description: "Move a closed item back to open.",
               type: :transition,
               icon: :rotate_ccw,
               confirmation: %{required: true, message: "Reopen this item?"},
               audit: %{event: "work_item.reopened", include_actor: true},
               preconditions: [
                 %{field: "title", comparator: :neq, value: "Blocked"},
                 %{field: "state", comparator: :in, value: [:closed, :reviewed]}
               ],
               transition: %{field: "state", from: "closed", to: "open"},
               execution: %{kind: :updato, operation: :update, set: %{state: :open}}
             }
           ] = contract.actions
  end

  test "keeps capability-gated actions and capabilities visible" do
    domain =
      write_domain()
      |> Map.put(:capabilities, %{
        "work_item.approve" => %{operations: [:action, :update], action: :approve}
      })
      |> Map.put(:actions, %{
        approve: %{
          type: :transition,
          capability: "work_item.approve",
          inputs: %{
            notify_guardian: %{type: :boolean, required: true, discriminator: true},
            reason: %{type: :string, required: false}
          },
          variants: [
            %{
              id: :silent,
              when: %{notify_guardian: false},
              execution: %{kind: :updato, operation: :update, set: %{state: :approved}}
            },
            %{
              id: :notify_guardian,
              when: %{notify_guardian: true},
              inputs: %{
                message: %{type: :string, required: true},
                checklist_items: %{
                  type: :collection,
                  representation: :patch,
                  identity: %{field: :id, client_field: :client_id},
                  order: %{field: :position, mode: :dense_integer},
                  allowed_ops: [:add, :remove, :update, :reorder],
                  item: %{
                    label: %{type: :string, required: true},
                    done: %{type: :boolean, required: false, default: false}
                  }
                }
              },
              execution: %{
                kind: :updato,
                operation: :update,
                set: %{state: :approved},
                collection_patches: %{
                  checklist_items: %{
                    from_input: :checklist_items,
                    target: {:relationship, :approval_checklist_items},
                    strategy: :patch
                  }
                }
              }
            }
          ],
          transition: %{field: :state, from: :open, to: :approved},
          execution: %{
            kind: :updato,
            operation: :update,
            set: %{state: :approved},
            cases: [
              %{when: %{notify_guardian: false}, operation: :update, set: %{state: :approved}},
              %{when: %{notify_guardian: true}, operation: :update, set: %{state: :approved}}
            ]
          }
        }
      })

    assert {:ok, contract, diagnostics} = DomainContract.build(domain)

    assert :capabilities in diagnostics.proposed_sections

    assert [%{id: "work_item.approve", operations: ["action", "update"], action: :approve}] =
             contract.capabilities

    assert [%{id: "approve", capability: "work_item.approve"}] =
             Enum.map(contract.actions, &Map.take(&1, [:id, :capability]))

    assert [
             %{id: "notify_guardian", discriminator: true, required: true, type: :boolean},
             %{id: "reason", required: false, type: :string}
           ] = contract.actions |> List.first() |> Map.fetch!(:inputs)

    assert [silent_variant, notify_variant] =
             contract.actions |> List.first() |> Map.fetch!(:variants)

    assert silent_variant.id == "silent"
    assert Map.fetch!(silent_variant, :when) == %{notify_guardian: false}
    assert notify_variant.id == "notify_guardian"
    assert Map.fetch!(notify_variant, :when) == %{notify_guardian: true}
    assert checklist = Enum.find(notify_variant.inputs, &(&1.id == "checklist_items"))
    assert checklist.type == :collection
    assert checklist.representation == :patch
    assert checklist.identity == %{field: :id, client_field: :client_id}
    assert checklist.order == %{field: :position, mode: :dense_integer}
    assert checklist.allowed_ops == ["add", "remove", "update", "reorder"]
    assert [%{id: "done"}, %{id: "label"}] = checklist.item

    assert notify_variant.execution.collection_patches == %{
             checklist_items: %{
               from_input: :checklist_items,
               target: {:relationship, :approval_checklist_items},
               strategy: :patch
             }
           }

    assert [%{operation: :update}, %{operation: :update}] =
             contract.actions |> List.first() |> get_in([:execution, :cases])
  end

  test "projects host-code hooks without exposing executable references as raw contract data" do
    anonymous_hook = fn changeset -> changeset end

    domain =
      write_domain()
      |> put_in([:writes, :hooks], %{
        before_insert: [
          anonymous_hook,
          {HookRefs, :tag_changeset},
          {HookRefs, :tag_changeset_with_context, [:audit_label]}
        ]
      })

    assert {:ok, contract, _diagnostics} = DomainContract.build(domain)

    assert [
             %{
               id: "before_insert",
               runtime: :host_code,
               portable: false,
               count: 3,
               refs: [
                 %{kind: :function, arity: 1},
                 %{
                   kind: :module_function,
                   module: "SelectoUpdato.DomainContractTest.HookRefs",
                   function: "tag_changeset",
                   extra_args: 0
                 },
                 %{
                   kind: :module_function,
                   module: "SelectoUpdato.DomainContractTest.HookRefs",
                   function: "tag_changeset_with_context",
                   extra_args: 1
                 }
               ]
             }
           ] = contract.hooks

    refute Map.has_key?(List.first(contract.hooks), :raw)

    assert {:ok, document, _diagnostics} =
             DomainContract.json_document(domain, generated_at: "2026-05-05T00:00:00Z")

    assert [
             %{
               "id" => "before_insert",
               "runtime" => "host_code",
               "portable" => false,
               "count" => 3,
               "refs" => [
                 %{"kind" => "function", "arity" => 1},
                 %{
                   "kind" => "module_function",
                   "module" => "SelectoUpdato.DomainContractTest.HookRefs",
                   "function" => "tag_changeset",
                   "extra_args" => 0
                 },
                 %{
                   "kind" => "module_function",
                   "module" => "SelectoUpdato.DomainContractTest.HookRefs",
                   "function" => "tag_changeset_with_context",
                   "extra_args" => 1
                 }
               ]
             }
           ] = document["hooks"]

    refute inspect(document["hooks"]) =~ "#Function"
  end

  test "portable tenant scope retains a field that has never been an atom" do
    field = "tenant_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end

    domain =
      write_domain()
      |> DomainContract.json_safe()
      |> put_in(["source", "fields"], ["id", field, "title", "state"])
      |> put_in(["source", "columns", field], %{"type" => "integer"})
      |> put_in(["writes", "scope"], %{
        "tenant" => %{
          "required" => true,
          "field" => field,
          "satisfied_by" => ["trusted_context"]
        }
      })

    assert %{field: ^field} = SelectoUpdato.WriteContract.tenant_scope(domain)
    assert {:ok, contract, _} = DomainContract.build(domain)
    assert contract.scope.tenant.field == field
    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
  end

  test "projects canonical tenant scope metadata" do
    domain =
      write_domain()
      |> put_in([:writes, :scope], %{
        tenant: %{
          required: true,
          field: :tenant_id,
          satisfied_by: [:trusted_context, :prefix]
        }
      })
      |> put_in([:source, :fields], [:id, :tenant_id, :title, :state])
      |> put_in([:source, :columns, :tenant_id], %{type: :integer})

    assert {:ok, contract, _diagnostics} = DomainContract.build(domain)

    assert contract.scope == %{
             tenant: %{
               required: true,
               field: "tenant_id",
               satisfied_by: ["trusted_context", "prefix"]
             }
           }

    assert {:ok, document, _diagnostics} =
             DomainContract.json_document(domain, generated_at: "2026-05-05T00:00:00Z")

    assert document["scope"] == %{
             "tenant" => %{
               "required" => true,
               "field" => "tenant_id",
               "satisfied_by" => ["trusted_context", "prefix"]
             }
           }
  end

  test "reports future write sections without failing the projection" do
    domain =
      base_domain()
      |> Map.put(:writes, %{
        operations: %{insert: %{enabled: true}},
        workflows: %{approval: %{steps: [:review, :approve]}},
        sagas: %{publish: %{adapter: :later}}
      })

    assert {:ok, contract, diagnostics} = DomainContract.build(domain)

    assert contract.unmodeled_write_sections == [:sagas, :workflows]
    assert :unmodeled_write_sections in warning_codes(diagnostics)

    assert %{sections: [:sagas, :workflows]} =
             Enum.find(diagnostics.warnings, &(&1.code == :unmodeled_write_sections))

    assert [%{id: "insert", enabled: true}] = contract.operations
  end

  test "builds a JSON-safe document for write tools and endpoints" do
    assert {:ok, document, diagnostics} =
             DomainContract.json_document(json_domain(),
               generated_at: "2026-05-05T00:00:00Z"
             )

    assert :unmodeled_write_sections in warning_codes(diagnostics)
    assert document["contract_version"] == 1
    assert document["projection"] == "updato_write_contract"
    assert document["generated_at"] == "2026-05-05T00:00:00Z"

    assert [
             %{"id" => "insert", "returning" => "all", "raw" => %{"enabled" => true}},
             %{"id" => "update", "require_filter" => true}
           ] = document["operations"]

    assert %{"id" => "state", "type" => "string", "required_on" => ["insert"]} =
             Enum.find(document["fields"], &(&1["id"] == "state"))

    assert document["validations"] == [["required_if", "title", "state", "open"]]
    assert document["constraints"] == [["require_relationship", "comments"]]

    assert [%{"field" => "state", "raw" => %{"draft" => ["open"], "open" => ["closed"]}}] =
             document["transitions"]

    assert [
             %{
               "id" => "approve",
               "label" => "Approve",
               "description" => "Approve the work item.",
               "capability" => "work_item.approve",
               "confirmation" => %{"required" => true},
               "execution" => %{
                 "kind" => "updato",
                 "operation" => "update",
                 "set" => %{"state" => "approved"}
               }
             }
           ] = document["actions"]

    assert [%{"id" => "work_item.approve", "operations" => ["action", "update"]}] =
             document["capabilities"]

    assert document["unmodeled_write_sections"] == ["workflows"]
    assert "unmodeled_write_sections" in document["diagnostics"]["warning_codes"]
  end

  test "encodes the JSON-safe document without nulls" do
    assert {:ok, json, _diagnostics} =
             DomainContract.encode_json(json_domain(), generated_at: "2026-05-05T00:00:00Z")

    refute json =~ ":null"

    assert %{
             "projection" => "updato_write_contract",
             "actions" => [%{"id" => "approve"} | _]
           } = Jason.decode!(json)
  end

  defp write_domain do
    base_domain()
    |> Map.put(:writes, %{
      operations: %{
        insert: %{enabled: true, returning: :all},
        update: %{enabled: true, require_filter: true}
      },
      fields: %{
        state: %{insertable: true, updatable: true, required_on: [:insert]},
        title: %{insertable: true, updatable: true}
      },
      relationships: %{
        comments: %{
          writable: true,
          cardinality: :many,
          allowed_ops: [:insert, :update],
          foreign_key: :work_item_id
        }
      },
      validations: [{:required_if, :title, :state, "open"}],
      constraints: [{:require_relationship, :comments}],
      transitions: %{
        state: %{
          draft: [:open],
          open: [:closed]
        }
      }
    })
  end

  defp canonical_examples do
    [
      work_items: Selecto.Domain.Examples.work_items(),
      camp_registrations: Selecto.Domain.Examples.camp_registrations()
    ]
  end

  defp json_domain do
    write_domain()
    |> put_in([:writes, :operations, :insert], %{
      enabled: true,
      returning: :all,
      field: nil
    })
    |> put_in([:writes, :workflows], %{approval: %{steps: [:review, :approve]}})
    |> Map.put(:capabilities, %{
      "work_item.approve" => %{operations: [:action, :update], action: :approve}
    })
    |> Map.put(:actions, %{
      approve: %{
        label: "Approve",
        description: "Approve the work item.",
        type: :transition,
        capability: "work_item.approve",
        confirmation: %{required: true},
        transition: %{field: :state, from: :open, to: :approved},
        execution: %{kind: :updato, operation: :update, set: %{state: :approved}}
      }
    })
  end

  defp base_domain do
    %{
      name: "Work Items",
      source: %{
        source_table: "work_items",
        primary_key: :id,
        fields: [:id, :title, :state, :state_label, :work_item_id],
        columns: %{
          id: %{type: :integer},
          title: %{type: :string},
          state: %{type: :string},
          state_label: %{type: :string},
          work_item_id: %{type: :integer}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{
        comments: %{
          source: "comments",
          owner_key: :id,
          my_key: :work_item_id,
          cardinality: :many
        }
      },
      choice_sources: %{
        state_choices: %{
          domain: :work_item_states,
          value_field: :state,
          label_field: :state_label
        }
      }
    }
    |> put_in([:source, :columns, :state, :choice_source], :state_choices)
    |> put_in([:source, :columns, :state, :reference], %{
      choice_source: :state_choices,
      value_source: :state,
      caption_source: :state_label
    })
  end

  defp warning_codes(diagnostics) do
    Enum.map(diagnostics.warnings, & &1.code)
  end
end
