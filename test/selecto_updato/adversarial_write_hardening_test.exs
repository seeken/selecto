defmodule SelectoUpdato.AdversarialWriteHardeningTest do
  @moduledoc """
  Regression coverage for the write-path holes catalogued in the adversarial
  scenario plan (S2, S3, S9, S25, grant binding and data-rule bypass).
  """

  use ExUnit.Case, async: true

  alias Selecto.Write.{Batch, Command, Graph, RecordRequest, RecordState}
  alias SelectoUpdato.{Error, PortableCommand}

  defmodule BatchAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :adversarial_batch
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_connection),
      do: %{
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

    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}

    def execute_write(pid, %Batch{} = batch, _opts) do
      send(pid, {:adversarial_batch, batch})

      {:ok,
       Enum.map(batch.commands, fn %Command{operation: operation} ->
         %Selecto.Write.Result{operation: operation, affected_rows: 1}
       end)}
    end

    def execute_write(pid, %Command{} = command, _opts) do
      send(pid, {:adversarial_command, command})
      {:ok, %Selecto.Write.Result{operation: command.operation, affected_rows: 1}}
    end
  end

  defmodule PreparedGraphAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :adversarial_prepared_graph
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_connection),
      do: %{
        protocol_version: 1,
        insert: true,
        update: true,
        delete: true,
        returning: true,
        generated_keys: :returning,
        transactions: true,
        write_graph: true,
        prepared_candidate_state: true
      }

    def preview_write(_connection, command, _opts), do: {:ok, %{command: command}}
    def execute_write(_connection, _write, _opts), do: raise("prepared path must be used")

    # The stored child row is a coupon line with a discount code.
    def execute_prepared_write(pid, prepare, _opts) do
      # A conforming adapter spends the governed preparation's authorization.
      prepare = Selecto.Write.Authorization.governed_preparation(prepare)

      loader = fn
        %RecordRequest{} = request ->
          send(pid, {:record_request, request})

          {:ok,
           %RecordState{
             values: %{"id" => 11, "kind" => "coupon", "discount_code" => "SAVE"},
             complete?: true,
             protection: :locked
           }}

        _request ->
          {:error, Selecto.Write.Error.new(:unexpected_request, "unexpected request")}
      end

      with {:ok, %Graph{} = graph, _context} <- prepare.(loader) do
        send(pid, {:prepared_graph, graph})
        {:ok, %Selecto.Write.Result{operation: :graph, affected_rows: 2}}
      end
    end
  end

  describe "S2: tenant field in update changes" do
    test "an update cannot move a scoped row into another tenant" do
      operation =
        items_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.update(%{tenant_id: 8, name: "planted"})

      assert {:error, %Error{type: :tenant_mismatch, details: %{field: :tenant_id}}} =
               PortableCommand.compile(operation)

      string_key = %{operation | changes: %{"tenant_id" => 8, "name" => "planted"}}
      assert {:error, %Error{type: :tenant_mismatch}} = PortableCommand.compile(string_key)

      context_only =
        items_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.update(%{tenant_id: 8})

      assert {:error, %Error{type: :tenant_mismatch}} =
               PortableCommand.compile(context_only, context: %{tenant_id: 7})
    end

    test "an update may restate the trusted tenant and stays tenant-bound" do
      operation =
        items_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.update(%{tenant_id: 7, name: "renamed"})

      assert {:ok, %Command{} = command, _context} = PortableCommand.compile(operation)
      assert %{field: "tenant_id", value: {:literal, 7}} in command.assignments

      assert command.predicate ==
               {:and,
                [
                  {:eq, {:field, "id"}, {:literal, 1}},
                  {:eq, {:field, "tenant_id"}, {:literal, 7}}
                ]}
    end

    test "a nested child update cannot move a child row into another tenant" do
      operation =
        order_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.filter({:id, 42})
        |> SelectoUpdato.update(%{
          reference: "R-1",
          items: [%{id: 11, tenant_id: 8, sku: "MOVED"}]
        })

      assert {:error, %Error{type: :tenant_mismatch}} = PortableCommand.compile(operation)

      same_tenant = %{
        operation
        | changes: %{reference: "R-1", items: [%{id: 11, tenant_id: 7, sku: "KEPT"}]}
      }

      assert {:ok, %Graph{}, _context} = PortableCommand.compile(same_tenant)
    end
  end

  describe "S25: immutable, write-once and server-managed fields" do
    test "an immutable field is rejected by a plain update even when marked updatable" do
      operation =
        items_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.update(%{code: "CHANGED"})

      assert {:error,
              %Error{
                type: :write_field_not_writable,
                details: %{field: :code, operation: :update, reason: :immutable}
              }} = PortableCommand.compile(operation)

      insert =
        items_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.insert(%{id: 2, name: "new", code: "C2"})

      assert {:ok, %Command{operation: :insert}, _context} = PortableCommand.compile(insert)
    end

    test "a write-once field may only be set while it is still null" do
      operation =
        items_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.update(%{owner: "alice", name: "renamed"})

      assert {:ok, %Command{} = command, _context} = PortableCommand.compile(operation)

      assert command.predicate ==
               {:and,
                [
                  {:eq, {:field, "id"}, {:literal, 1}},
                  {:eq, {:field, "tenant_id"}, {:literal, 7}},
                  {:is_null, {:field, "owner"}}
                ]}

      unfiltered = %{operation | filters: []}

      assert {:ok, %Command{predicate: {:and, [{:eq, {:field, "tenant_id"}, _}, _guard]}}, _} =
               PortableCommand.compile(unfiltered)

      unscoped =
        items_domain()
        |> Map.update!(:writes, &Map.delete(&1, :scope))
        |> SelectoUpdato.new()
        |> SelectoUpdato.update(%{owner: "alice"})

      assert {:error, %Error{type: :missing_predicate}} = PortableCommand.compile(unscoped)
    end

    test "conflict updates never rewrite immutable, write-once or server-managed fields" do
      operation =
        items_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.upsert(%{id: 3, name: "n", code: "C", owner: "o"})

      assert {:ok, %Command{metadata: %{upsert_update_fields: fields}}, _context} =
               PortableCommand.compile(operation)

      assert Enum.sort(fields) == ["name", "tenant_id"]
      refute "code" in fields or "owner" in fields
    end

    test "a server-managed field is never caller-written" do
      domain =
        items_domain()
        |> put_in([:writes, :fields, :name], %{
          insertable: true,
          updatable: true,
          server_managed: true
        })

      update =
        domain
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.update(%{name: "forged"})

      assert {:error,
              %Error{type: :write_field_not_writable, details: %{reason: :server_managed}}} =
               PortableCommand.compile(update)

      insert =
        domain
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.insert(%{id: 4, name: "forged"})

      assert {:error,
              %Error{type: :write_field_not_writable, details: %{reason: :server_managed}}} =
               PortableCommand.compile(insert)
    end
  end

  describe "S3: foreign-key guards carry the trusted tenant" do
    test "a guard to a schema that declares tenant_field is tenant-scoped on insert and update" do
      insert =
        tasks_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.insert(%{id: 3, project_id: 80, title: "t"})

      assert {:ok, %Command{metadata: %{foreign_key_guards: guards}}, _} =
               PortableCommand.compile(insert)

      assert %{
               field: "project_id",
               relation: "projects",
               target_field: "id",
               tenant_field: "tenant_id",
               tenant_value: 7,
               tenant_exact: false
             } in guards

      update =
        tasks_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.update(%{project_id: 80})

      assert {:ok, %Command{metadata: %{foreign_key_guards: [guard]}}, _} =
               PortableCommand.compile(update)

      assert guard.tenant_field == "tenant_id" and guard.tenant_value == 7
    end

    test "self-references use the root tenant and shared references stay unscoped" do
      operation =
        tasks_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.insert(%{id: 3, parent_id: 1, country_code: "NZ", title: "t"})

      assert {:ok, %Command{metadata: %{foreign_key_guards: guards}}, _} =
               PortableCommand.compile(operation)

      assert %{
               field: "parent_id",
               relation: "tasks",
               target_field: "id",
               tenant_field: "tenant_id",
               tenant_value: 7,
               tenant_exact: false
             } in guards

      assert %{field: "country_code", relation: "countries", target_field: "code"} in guards
    end

    test "an input reference with undeclared tenancy fails closed on a tenant-scoped write" do
      operation =
        tasks_domain()
        |> put_in([:writes, :constraints, :foreign_keys, :reviewer_id], %{
          source: :input,
          references: %{relation: "users", field: :id}
        })
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.insert(%{id: 3, reviewer_id: 5, title: "t"})

      assert {:error,
              %Error{
                type: :invalid_domain,
                details: %{code: :foreign_key_tenant_scope_undeclared, relation: "users"}
              }} = PortableCommand.compile(operation)

      declared =
        update_in(
          operation.domain,
          [:writes, :constraints, :foreign_keys, :reviewer_id, :references],
          &Map.put(&1, :tenant_field, :tenant_id)
        )

      assert {:ok, %Command{metadata: %{foreign_key_guards: guards}}, _} =
               PortableCommand.compile(%{operation | domain: declared})

      assert Enum.any?(guards, &(&1.relation == "users" and &1.tenant_value == 7))
    end

    test "trusted context references to undeclared relations keep their existing guard" do
      operation =
        tasks_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.insert(%{id: 3, title: "t"})

      assert {:ok, %Command{metadata: %{foreign_key_guards: guards}}, _} =
               PortableCommand.compile(operation, context: %{account_id: 42})

      assert %{field: "account_id", relation: "accounts", target_field: "id"} in guards
    end

    test "a tenant-scoped reference requires a trusted tenant even on an unscoped write" do
      domain =
        tasks_domain()
        |> Map.update!(:writes, &Map.delete(&1, :scope))
        |> put_in([:writes, :constraints, :foreign_keys], %{
          project_id: %{source: :input, references: %{relation: "projects", field: :id}}
        })

      operation =
        domain
        |> SelectoUpdato.new()
        |> SelectoUpdato.insert(%{id: 3, tenant_id: 7, project_id: 80, title: "t"})

      assert {:error, %Error{type: :missing_tenant_scope, details: %{relation: "projects"}}} =
               PortableCommand.compile(operation)

      assert {:ok, %Command{metadata: %{foreign_key_guards: [%{tenant_value: 7}]}}, _} =
               PortableCommand.compile(operation, context: %{tenant_id: 7})
    end

    test "a declared tenant field that the referenced schema lacks fails closed" do
      operation =
        tasks_domain()
        |> put_in([:schemas, :projects, :tenant_field], :organization_id)
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.insert(%{id: 3, project_id: 80, title: "t"})

      assert {:error,
              %Error{
                type: :invalid_domain,
                details: %{code: :unknown_foreign_key_tenant_field}
              }} = PortableCommand.compile(operation)
    end
  end

  describe "S9: upsert scope" do
    test "an upsert refuses host filters it cannot enforce" do
      operation =
        products_domain(scoped?: false)
        |> SelectoUpdato.new()
        |> SelectoUpdato.require_tenant_filter(:tenant_id, 7)
        |> SelectoUpdato.upsert(%{id: 2, tenant_id: 7, sku: "X", name: "hijack"})

      assert {:error,
              %Error{
                type: :query_enforcement,
                details: %{
                  code: :query_enforcement_unsupported_operation,
                  operation: :upsert,
                  fields: ["tenant_id"]
                }
              }} = PortableCommand.compile(operation)

      selecto = %Selecto{adapter: BatchAdapter, connection: self()}

      assert {:error, %Error{type: :query_enforcement}} =
               SelectoUpdato.execute(operation, selecto)

      refute_receive {:adversarial_command, _command}
    end

    test "a scoped upsert refuses an extra required filter but keeps the trusted tenant filter" do
      extra =
        products_domain(scoped?: true)
        |> SelectoUpdato.new(tenant: %{tenant_id: 7, required_filters: [{:name, "seven"}]})
        |> SelectoUpdato.upsert(%{id: 9, sku: "B", name: "new"})

      selecto = %Selecto{adapter: BatchAdapter, connection: self()}

      assert {:error, %Error{details: %{code: :query_enforcement_unsupported_operation}}} =
               SelectoUpdato.execute(extra, selecto, context: %{tenant_id: 7})

      plain =
        products_domain(scoped?: true)
        |> SelectoUpdato.new(tenant: %{tenant_id: 7})
        |> SelectoUpdato.upsert(%{id: 9, sku: "B", name: "new"})

      assert {:ok, %Selecto.Write.Result{operation: :upsert}} =
               SelectoUpdato.execute(plain, selecto, context: %{tenant_id: 7})

      assert_receive {:adversarial_command,
                      %Command{
                        operation: :upsert,
                        predicate: nil,
                        metadata: %{conflict_target: [:tenant_id, :sku]}
                      } = command}

      assert %{field: "tenant_id", value: {:literal, 7}} in command.assignments
    end
  end

  describe "action grants bind admission options" do
    test "changing a choice-source option after the grant is issued is rejected" do
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

      tampered = %{
        operation
        | opts: Keyword.put(operation.opts || [], :choice_source_record, %{"status" => "open"})
      }

      context = %{
        tenant_id: 9,
        choice_source_membership_resolver: fn _request ->
          Selecto.Domain.Choices.valid(:grant_option_probe)
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
              %Error{type: :authorization, details: %{code: :action_authorization_mismatch}}} =
               PortableCommand.compile(tampered, context: context, action_phase: :execute)
    end
  end

  describe "data rules that need stored state" do
    test "Multi refuses a partial update whose rule needs the stored row" do
      selecto = %Selecto{adapter: BatchAdapter, connection: self()}

      # Stored row: kind = "coupon", discount_code = "SAVE". Clearing the code
      # alone hides the condition field from a submitted-values evaluation.
      multi =
        SelectoUpdato.multi()
        |> SelectoUpdato.multi_update(:clear_code, coupon_domain(),
          filters: [{:id, 1}],
          changes: %{discount_code: nil}
        )

      assert {:error,
              %Error{
                type: :unsupported_operation,
                details: %{code: :batch_rule_strategy_unsupported, name: :clear_code}
              }} = SelectoUpdato.run(multi, selecto)

      refute_receive {:adversarial_batch, _batch}

      single =
        coupon_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.update(%{discount_code: nil})

      assert {:error, %Error{type: :unsupported_operation}} =
               SelectoUpdato.execute(single, selecto)
    end

    test "nested child updates evaluate their rules against protected stored state" do
      selecto = %Selecto{adapter: PreparedGraphAdapter, connection: self()}

      operation =
        coupon_order_domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.filter({:id, 42})
        |> SelectoUpdato.update(%{reference: "R-1", lines: [%{id: 11, discount_code: nil}]})

      assert {:error, %Error{details: %{code: :data_rule_failed}}} =
               SelectoUpdato.execute(operation, selecto)

      assert_receive {:record_request, %RecordRequest{relation: "coupon_lines"}}
      refute_receive {:prepared_graph, _graph}

      valid = %{
        operation
        | changes: %{reference: "R-1", lines: [%{id: 11, discount_code: "NEW"}]}
      }

      assert {:ok, %Selecto.Write.Result{operation: :graph}} =
               SelectoUpdato.execute(valid, selecto)

      assert_receive {:prepared_graph, %Graph{}}
    end
  end

  defp items_domain do
    %{
      name: "items",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :tenant_id, :name, :code, :owner],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          name: %{type: :string},
          code: %{type: :string},
          owner: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true},
          upsert: %{enabled: true, conflict_targets: [[:tenant_id, :id]]}
        },
        fields: %{
          id: %{insertable: true},
          tenant_id: %{insertable: true, updatable: true},
          name: %{insertable: true, updatable: true},
          code: %{insertable: true, updatable: true, immutable: true},
          owner: %{insertable: true, updatable: true, write_once: true}
        },
        scope: %{tenant: %{required: true, field: :tenant_id}}
      }
    }
  end

  defp order_domain do
    child =
      scoped_domain("order_items", [:id, :tenant_id, :order_id, :sku], %{
        tenant_id: %{insertable: true, updatable: true},
        sku: %{insertable: true, updatable: true}
      })

    scoped_domain("orders", [:id, :tenant_id, :reference], %{
      tenant_id: %{insertable: true},
      reference: %{insertable: true, updatable: true}
    })
    |> put_in([:writes, :relationships], %{
      items: %{
        writable: true,
        cardinality: :many,
        ownership: :owned,
        allowed_ops: [:insert, :update, :delete],
        domain: child,
        child_key: :order_id,
        parent_key: :id,
        strategy: :sync,
        identity_fields: [:id],
        delete_missing: true
      }
    })
  end

  defp scoped_domain(relation, fields, write_fields) do
    %{
      name: relation,
      source: %{
        source_table: relation,
        primary_key: :id,
        fields: fields,
        columns: Map.new(fields, &{&1, %{type: :string}}),
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true, expected_cardinality: {:exactly, 1}},
          update: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}}
        },
        fields: write_fields,
        scope: %{tenant: %{required: true, field: :tenant_id}},
        relationships: %{}
      }
    }
  end

  defp tasks_domain do
    %{
      name: "tasks",
      source: %{
        source_table: "tasks",
        primary_key: :id,
        tenant_field: :tenant_id,
        fields: [
          :id,
          :tenant_id,
          :project_id,
          :parent_id,
          :country_code,
          :reviewer_id,
          :account_id,
          :title
        ],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          project_id: %{type: :integer},
          parent_id: %{type: :integer},
          country_code: %{type: :string},
          reviewer_id: %{type: :integer},
          account_id: %{type: :integer},
          title: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{
        projects: %{
          source_table: "projects",
          primary_key: :id,
          tenant_field: :tenant_id,
          fields: [:id, :tenant_id, :name],
          columns: %{id: %{type: :integer}, tenant_id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        },
        countries: %{
          source_table: "countries",
          primary_key: :code,
          fields: [:code, :name],
          columns: %{code: %{type: :string}, name: %{type: :string}},
          associations: %{}
        }
      },
      joins: %{},
      writes: %{
        operations: %{insert: %{enabled: true}, update: %{enabled: true}},
        fields: %{
          id: %{insertable: true},
          tenant_id: %{insertable: true},
          project_id: %{insertable: true, updatable: true},
          parent_id: %{insertable: true, updatable: true},
          country_code: %{insertable: true, updatable: true},
          reviewer_id: %{insertable: true, updatable: true},
          account_id: %{insertable: true},
          title: %{insertable: true, updatable: true}
        },
        scope: %{tenant: %{required: true, field: :tenant_id}},
        constraints: %{
          foreign_keys: %{
            project_id: %{source: :input, references: %{relation: "projects", field: :id}},
            parent_id: %{source: :input, references: %{relation: "tasks", field: :id}},
            country_code: %{
              source: :input,
              references: %{relation: "countries", field: :code, tenant_field: false}
            },
            account_id: %{
              source: {:context, :account_id},
              references: %{relation: "accounts", field: :id}
            }
          }
        }
      }
    }
  end

  defp products_domain(scoped?: scoped?) do
    writes = %{
      operations: %{upsert: %{enabled: true, conflict_targets: conflict_targets(scoped?)}},
      fields: %{
        id: %{insertable: true},
        tenant_id: %{insertable: true},
        sku: %{insertable: true},
        name: %{insertable: true, updatable: true}
      }
    }

    writes =
      if scoped?,
        do:
          Map.put(writes, :scope, %{
            tenant: %{required: true, field: :tenant_id, satisfied_by: [:trusted_context]}
          }),
        else: writes

    %{
      name: "products",
      source: %{
        source_table: "products",
        primary_key: :id,
        tenant_field: :tenant_id,
        fields: [:id, :tenant_id, :sku, :name],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          sku: %{type: :string},
          name: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: writes
    }
  end

  defp conflict_targets(true), do: [[:tenant_id, :sku]]
  defp conflict_targets(false), do: [[:id]]

  defp coupon_domain do
    %{
      name: "coupon_lines",
      source: %{
        source_table: "coupon_lines",
        primary_key: :id,
        fields: [:id, :order_id, :kind, :discount_code],
        columns: %{
          id: %{type: :integer},
          order_id: %{type: :integer},
          kind: %{type: :string},
          discount_code: %{type: :string}
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
          id: %{insertable: true},
          kind: %{insertable: true, updatable: true},
          discount_code: %{insertable: true, updatable: true}
        }
      },
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{
          discount_code_present: %{version: 1, test: %{op: "presence.non_null"}}
        },
        normalizers: %{},
        bindings: %{
          coupon_needs_code: %{
            subject: %{scope: :candidate, path: [:discount_code]},
            rule: %{id: :discount_code_present, version: 1},
            condition: %{
              op: "path.test",
              path: [:kind],
              test: %{op: "value.eq", value: "coupon"}
            }
          }
        }
      }
    }
  end

  defp coupon_order_domain do
    %{
      name: "coupon_orders",
      source: %{
        source_table: "coupon_orders",
        primary_key: :id,
        fields: [:id, :reference],
        columns: %{id: %{type: :integer}, reference: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{update: %{enabled: true, require_filter: true}},
        fields: %{reference: %{updatable: true}},
        relationships: %{
          lines: %{
            writable: true,
            cardinality: :many,
            ownership: :owned,
            allowed_ops: [:update],
            domain: coupon_domain(),
            child_key: :order_id,
            parent_key: :id,
            strategy: :sync,
            identity_fields: [:id],
            delete_missing: false
          }
        }
      }
    }
  end
end
