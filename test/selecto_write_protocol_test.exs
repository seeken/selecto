defmodule Selecto.WriteProtocolTest do
  use ExUnit.Case, async: true

  alias Selecto.Write

  alias Selecto.Write.{
    AdapterConformance,
    Batch,
    Capabilities,
    Command,
    CommittedEffectSink,
    Error,
    Graph,
    Preview,
    Result
  }

  alias Selecto.Write.Graph.{Binding, Node, Row}
  alias Selecto.Domain.WriteContract

  defmodule WriteAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :write_test
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
        write_graph: true,
        returning: true,
        generated_keys: :returning,
        atomic_batch: true,
        transactions: true
      }

    def preview_write(_connection, command, _opts) do
      {:ok, %Preview{statements: [%{text: "adapter-owned preview", params: [command]}]}}
    end

    def execute_write(_connection, %Batch{commands: commands}, _opts) do
      {:ok,
       Enum.map(commands, fn command ->
         %Result{operation: operation(command), affected_rows: 1, rows: [%{id: 1}]}
       end)}
    end

    def execute_write(_connection, command, _opts) do
      {:ok, %Result{operation: operation(command), affected_rows: 1, rows: [%{id: 1}]}}
    end

    defp operation(%Command{operation: operation}), do: operation
    defp operation(%Batch{commands: [%Command{operation: operation} | _]}), do: operation
    defp operation(%Graph{}), do: :graph
  end

  defmodule ReadOnlyAdapter do
    @behaviour Selecto.DB.Adapter

    def name, do: :read_only
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false
  end

  defmodule EffectAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :effect_test
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_connection),
      do: %{
        protocol_version: 1,
        insert: true,
        committed_effect_sink: true
      }

    def preview_write(_connection, _command, _opts), do: {:ok, %Preview{statements: []}}

    def execute_write(agent, command, opts) do
      Agent.update(agent, &[opts | &1])
      {:ok, %Result{operation: command.operation, affected_rows: 1}}
    end
  end

  defmodule MissingProtocolAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :missing_protocol
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false
    def write_capabilities(_connection), do: %{insert: true}
    def preview_write(agent, _write, _opts), do: Agent.update(agent, &(&1 + 1))
    def execute_write(agent, _write, _opts), do: Agent.update(agent, &(&1 + 1))
  end

  defmodule OperationReturningAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :operation_returning
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false

    def write_capabilities(_connection),
      do: %{protocol_version: 1, insert: true, update: true, returning: %{insert: true}}

    def preview_write(_connection, _write, _opts), do: {:ok, %Preview{statements: []}}

    def execute_write(_connection, command, _opts),
      do: {:ok, %Result{operation: command.operation, affected_rows: 1}}
  end

  defmodule RaisingCapabilitiesAdapter do
    @behaviour Selecto.DB.Adapter
    @behaviour Selecto.DB.WriteAdapter

    def name, do: :raising_capabilities
    def connect(connection), do: {:ok, connection}
    def execute(_connection, _query, _params, _opts), do: {:ok, %{rows: [], columns: []}}
    def placeholder(index), do: ["$", Integer.to_string(index)]
    def quote_identifier(identifier), do: ~s("#{identifier}")
    def supports?(_feature), do: false
    def write_capabilities(_connection), do: raise("capability probe secret")
    def preview_write(agent, _write, _opts), do: Agent.update(agent, &(&1 + 1))
    def execute_write(agent, _write, _opts), do: Agent.update(agent, &(&1 + 1))
  end

  test "dispatches a validated portable command to the configured write adapter" do
    command = command!(:insert)
    selecto = %Selecto{adapter: WriteAdapter, connection: :connection}

    assert {:ok, %Result{operation: :insert, affected_rows: 1}} = Write.execute(selecto, command)

    assert {:ok, %Preview{statements: [%{text: "adapter-owned preview"}]}} =
             Write.preview(selecto, command)

    assert {:ok, %{atomic_batch: true}} = Write.capabilities(selecto)
  end

  test "requires an explicit atomic committed-effect capability before dispatch" do
    sink = fn _connection, _result, _context -> :ok end
    selecto = %Selecto{adapter: WriteAdapter, connection: :connection}

    assert {:error,
            %Error{
              type: :write_capability_missing,
              details: %{missing: [:committed_effect_sink]}
            }} = Write.execute(selecto, command!(:insert), committed_effect_sink: sink)
  end

  test "passes a committed-effect sink only to an adapter that declares support" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    sink = fn _connection, _result, _context -> :ok end
    selecto = %Selecto{adapter: EffectAdapter, connection: agent}

    assert {:ok, %Result{operation: :insert}} =
             Write.execute(selecto, command!(:insert), committed_effect_sink: sink)

    assert [[committed_effect_sink: ^sink]] = Agent.get(agent, & &1)
  end

  test "committed-effect sink normalizes failures without exposing values" do
    assert :ok = CommittedEffectSink.invoke(nil, :connection, :result, %{})

    assert {:error, %Error{type: :committed_effect_failed, details: %{reason: "sink_error"}}} =
             CommittedEffectSink.invoke(
               fn _, _, _ -> {:error, {:database, "private payload"}} end,
               :connection,
               :result,
               %{}
             )

    assert {:error,
            %Error{
              type: :committed_effect_failed,
              details: %{reason: "write_error:private_sink_failure"}
            } = nested_error} =
             CommittedEffectSink.invoke(
               fn _, _, _ ->
                 {:error,
                  Error.new(:private_sink_failure, "private payload",
                    details: %{payload: "private payload"}
                  )}
               end,
               :connection,
               :result,
               %{}
             )

    refute inspect(nested_error) =~ "private payload"

    assert {:error,
            %Error{
              type: :committed_effect_failed,
              details: %{reason: "exception:RuntimeError"}
            } = error} =
             CommittedEffectSink.invoke(
               fn _, _, _ -> raise "private payload" end,
               :connection,
               :result,
               %{}
             )

    refute inspect(error) =~ "private payload"
  end

  test "fails before dispatch when the adapter omits or cannot preserve protocol capabilities" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    selecto = %Selecto{adapter: MissingProtocolAdapter, connection: agent}

    assert {:error, %Error{type: :invalid_write_capabilities}} =
             Write.execute(selecto, command!(:insert))

    assert {:error, %Error{type: :invalid_write_capabilities}} =
             Write.preview(selecto, command!(:insert))

    assert Agent.get(agent, & &1) == 0
  end

  test "capability callback crashes fail closed without dispatch or leaked exception text" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    selecto = %Selecto{adapter: RaisingCapabilitiesAdapter, connection: agent}

    assert {:error,
            %Error{
              type: :invalid_write_capabilities,
              details: %{adapter: RaisingCapabilitiesAdapter}
            } = error} = Write.execute(selecto, command!(:insert))

    refute inspect(error) =~ "capability probe secret"
    assert Agent.get(agent, & &1) == 0
  end

  test "adapter failures never retain driver structs or sensitive reason text" do
    error =
      Error.adapter_failure(
        :execution_failed,
        :example,
        %RuntimeError{message: "secret bound value"},
        "example write failed"
      )

    assert error.details == %{adapter: :example, reason: "RuntimeError"}
    refute inspect(error) =~ "secret bound value"
    assert {:ok, _json} = Jason.encode(error.details)
  end

  test "supports operation-specific returning without overclaiming other mutations" do
    selecto = %Selecto{adapter: OperationReturningAdapter, connection: :connection}

    assert {:ok, %Result{operation: :insert}} =
             Write.execute(selecto, %{command!(:insert) | returning: [:id]})

    assert {:error,
            %Error{
              type: :write_capability_missing,
              details: %{missing: [{:returning, :update}]}
            }} = Write.execute(selecto, %{command!(:update) | returning: [:id]})
  end

  test "graph preflight requires returning only for the root operation" do
    root = %{command!(:insert) | returning: [:id]}
    child = %{command!(:update) | relation: :children, returning: [:id]}

    nodes = [
      %Node{
        id: "root",
        path: [],
        relation: :items,
        strategy: :ordered,
        rows: [%Row{id: "root", path: [], command: root}]
      },
      %Node{
        id: "children",
        path: [:children],
        relation: :children,
        strategy: :ordered,
        rows: [%Row{id: "child", path: [:children, 0], command: child}]
      }
    ]

    assert {:ok, graph} = Graph.new(nodes, {"root", "root"})

    capabilities = %{
      protocol_version: 1,
      insert: true,
      update: true,
      transactions: true,
      write_graph: true,
      returning: %{insert: true},
      generated_keys: false
    }

    assert :ok = Capabilities.require(capabilities, graph)
    refute {:returning, :update} in Capabilities.requirements(graph)
    refute :generated_keys in Capabilities.requirements(graph)
  end

  test "rejects raw SQL from a portable command" do
    assert {:error, %Error{type: :invalid_command}} =
             Command.new(%{
               operation: :update,
               relation: :items,
               predicate: {:unsafe_sql, "id = 1"}
             })

    assert {:error, %Error{type: :invalid_command}} =
             Command.new(%{
               operation: :upsert,
               relation: :items,
               metadata: %{conflict_target: {:unsafe_sql, "id"}}
             })

    assert {:error, %Error{type: :invalid_command}} =
             Command.new(%{
               operation: :update,
               relation: :items,
               predicate: {:and, [{:eq, {:field, :id}, {:literal, 1}}, {:unsafe_sql, "TRUE"}]}
             })

    assert {:error, %Error{type: :invalid_command}} =
             Command.new(%{
               operation: :insert,
               relation: :items,
               assignments: [
                 %{field: :name, value: {:coalesce, [{:literal, "safe"}, {:unsafe_sql, "x"}]}}
               ]
             })
  end

  test "rejects exact and normalized duplicate assignment and returning fields" do
    for assignments <- [
          [
            %{field: :name, value: {:literal, "first"}},
            %{field: :name, value: {:literal, "second"}}
          ],
          [
            %{field: :name, value: {:literal, "first"}},
            %{field: "name", value: {:literal, "second"}}
          ]
        ] do
      assert {:error,
              %Error{
                type: :invalid_command,
                details: %{
                  code: :duplicate_assignment_identifier,
                  identifier_kind: :assignment,
                  fields: ["name"]
                }
              }} =
               Command.new(%{
                 operation: :update,
                 relation: :items,
                 assignments: assignments
               })
    end

    for returning <- [[:id, :id], [:id, "id"]] do
      assert {:error,
              %Error{
                type: :invalid_command,
                details: %{
                  code: :duplicate_returning_identifier,
                  identifier_kind: :returning,
                  fields: ["id"]
                }
              }} =
               Command.new(%{
                 operation: :update,
                 relation: :items,
                 returning: returning
               })
    end
  end

  test "allows repeated fields in generic predicates" do
    assert {:ok, %Command{}} =
             Command.new(%{
               operation: :update,
               relation: :items,
               predicate: {
                 :and,
                 [
                   {:eq, {:field, :status}, {:literal, "open"}},
                   {:neq, {:field, "status"}, {:literal, "closed"}}
                 ]
               }
             })
  end

  test "recursive safety validation preserves ordinary typed struct values" do
    assert {:ok, %Command{}} =
             Command.new(%{
               operation: :insert,
               relation: :items,
               assignments: [%{field: :due_on, value: {:literal, ~D[2026-10-01]}}],
               metadata: %{requested_on: ~D[2026-08-11]}
             })
  end

  test "malformed graph structs fail closed without raising" do
    assert {:error, %Error{type: :invalid_graph}} = Graph.new([:not_a_node], {"root", "root"})

    invalid_rows = %Node{
      id: "root",
      path: [],
      relation: :items,
      strategy: :ordered,
      rows: :not_a_list
    }

    assert {:error, %Error{type: :invalid_graph}} =
             Graph.new([invalid_rows], {"root", "root"})

    invalid_command = %Node{
      id: "root",
      path: [],
      relation: :items,
      strategy: :ordered,
      rows: [%Row{id: "root", path: [], command: nil}]
    }

    assert {:error, %Error{type: :invalid_graph}} =
             Graph.new([invalid_command], {"root", "root"})

    valid_row = %Row{id: "root", path: [], command: command!(:insert)}

    unsafe_metadata = %Node{
      id: "root",
      path: [],
      relation: :items,
      strategy: :ordered,
      rows: [valid_row],
      metadata: %{hint: {:unsafe_sql, "LOCK TABLE items"}}
    }

    assert {:error, %Error{type: :invalid_graph}} =
             Graph.new([unsafe_metadata], {"root", "root"})
  end

  test "requires atomic batches" do
    command = command!(:update)

    assert {:ok, %Batch{atomic?: true}} = Batch.new([command])
    assert {:error, %Error{type: :invalid_command}} = Batch.new([command], atomic?: false)
  end

  test "dispatches batch execution results as an ordered result list" do
    {:ok, batch} = Batch.new([command!(:insert), command!(:delete)])
    selecto = %Selecto{adapter: WriteAdapter, connection: :connection}

    assert {:ok,
            [
              %Result{operation: :insert, affected_rows: 1},
              %Result{operation: :delete, affected_rows: 1}
            ]} = Write.execute(selecto, batch)
  end

  test "validates topologically ordered generated-key write graphs" do
    root = %{command!(:insert) | returning: [:id]}

    child =
      command!(:insert)
      |> Map.put(:relation, :children)
      |> Map.update!(:assignments, &[%{field: :child_name, value: {:literal, "child"}} | &1])

    nodes = [
      %Node{
        id: "root",
        path: [],
        relation: :items,
        strategy: :ordered,
        rows: [%Row{id: "root", path: [], command: root}]
      },
      %Node{
        id: "children",
        path: [:children],
        relation: :children,
        strategy: :ordered,
        rows: [
          %Row{
            id: "0",
            path: [:children, 0],
            command: child,
            bindings: [
              %Binding{
                field: :item_id,
                from_node: "root",
                from_row: "root",
                from_field: :id
              }
            ]
          }
        ]
      }
    ]

    assert {:ok, graph} = Graph.new(nodes, {"root", "root"})

    assert {:ok, %Result{operation: :graph}} =
             Write.execute(%Selecto{adapter: WriteAdapter, connection: :connection}, graph)
  end

  test "rejects forward references and caller overrides of generated bindings" do
    command = command!(:insert)

    forward =
      %Node{
        id: "child",
        path: [:child],
        relation: :items,
        strategy: :ordered,
        rows: [
          %Row{
            id: "child",
            path: [:child],
            command: command,
            bindings: [
              %Binding{
                field: :parent_id,
                from_node: "later",
                from_row: "later",
                from_field: :id
              }
            ]
          }
        ]
      }

    later = %Node{
      id: "later",
      path: [],
      relation: :items,
      strategy: :ordered,
      rows: [%Row{id: "later", path: [], command: command}]
    }

    assert {:error, %Error{type: :invalid_graph}} =
             Graph.new([forward, later], {"later", "later"})

    overridden =
      %{
        forward
        | rows: [
            %Row{
              id: "child",
              path: [:child],
              command: command,
              bindings: [
                %Binding{
                  field: :name,
                  from_node: "later",
                  from_row: "later",
                  from_field: :id
                }
              ]
            }
          ]
      }

    assert {:error, %Error{type: :invalid_graph}} =
             Graph.new([later, overridden], {"later", "later"})
  end

  test "provides reusable non-mutating adapter conformance checks" do
    selecto = %Selecto{adapter: WriteAdapter, connection: :connection}

    assert {:ok, report} = AdapterConformance.check(selecto)
    assert report.operations == [:insert, :update, :upsert, :delete]
    assert Map.keys(report.previews) |> Enum.sort() == [:delete, :insert, :update, :upsert]
    assert %Preview{} = report.batch_preview
  end

  test "rejects retired operations at both domain and command boundaries" do
    for operation <- [:insert_all, :upsert_all, :insert_from_query, :soft_delete] do
      assert {:error, %Error{type: :invalid_command}} =
               Command.new(%{operation: operation, relation: :items})

      invalid = put_in(write_domain(), [:writes, :operations], %{operation => %{enabled: true}})
      assert {:error, %Error{type: :invalid_domain}} = WriteContract.compile(invalid)
    end
  end

  test "fails before execution when the configured adapter has no write behavior" do
    selecto = %Selecto{adapter: ReadOnlyAdapter, connection: :connection}

    assert {:error, %Error{type: :write_not_supported}} =
             Write.execute(selecto, command!(:delete))
  end

  test "compiles only an explicit write surface and never treats a read domain as writable" do
    assert {:error, %Error{type: :write_not_declared}} = WriteContract.compile(read_domain())

    assert {:ok, contract} = WriteContract.compile(write_domain())
    assert WriteContract.operation_enabled?(contract, :insert)
    assert WriteContract.operation_enabled?(contract, :update)
    refute WriteContract.operation_enabled?(contract, :delete)
    assert WriteContract.writable?(contract, :insert, :name)
    refute WriteContract.writable?(contract, :update, :tenant_id)
    assert contract.scope.tenant.field == :tenant_id
  end

  test "compiler rejects normalized registry collisions even for already-normalized domains" do
    operation_collision =
      put_in(write_domain(), [:writes, :operations], %{
        "update" => %{enabled: true, require_filter: false},
        insert: %{enabled: true},
        update: %{enabled: false}
      })

    {:ok, normalized_operation_collision, _diagnostics} =
      Selecto.Domain.normalize(operation_collision)

    assert {:error,
            %Error{
              type: :invalid_domain,
              details: %{
                code: :duplicate_write_operation_id,
                path: [:writes, :operations],
                normalized_id: "update",
                authored_ids: authored_operation_ids
              }
            }} = WriteContract.compile(normalized_operation_collision)

    assert Enum.sort_by(authored_operation_ids, &inspect/1) == ["update", :update]

    field_collision =
      put_in(write_domain(), [:writes, :fields], %{
        "name" => %{updatable: true},
        name: %{updatable: false},
        tenant_id: %{immutable: true}
      })

    {:ok, normalized_field_collision, _diagnostics} = Selecto.Domain.normalize(field_collision)

    assert {:error,
            %Error{
              type: :invalid_domain,
              details: %{
                code: :duplicate_write_field_id,
                path: [:writes, :fields],
                normalized_id: "name",
                authored_ids: authored_field_ids
              }
            }} = WriteContract.compile(normalized_field_collision)

    assert Enum.sort_by(authored_field_ids, &inspect/1) == ["name", :name]
  end

  test "permits a write domain without tenant policy but compiles tenant policy fail-closed when present" do
    tenantless_domain = update_in(write_domain(), [:writes], &Map.delete(&1, :scope))

    assert {:ok, %{scope: %{}}} = WriteContract.compile(tenantless_domain)

    invalid_tenant_domain = put_in(write_domain(), [:writes, :scope, :tenant, :required], false)

    assert {:error, %Error{type: :invalid_domain}} = WriteContract.compile(invalid_tenant_domain)
  end

  test "rejects unknown write fields before a command reaches an adapter" do
    invalid_domain =
      put_in(write_domain(), [:writes, :fields, :missing_field], %{insertable: true})

    assert {:error, %Error{type: :invalid_domain}} = WriteContract.compile(invalid_domain)
  end

  test "requires foreign-key value sources and referenced targets to be authored explicitly" do
    domain =
      write_domain()
      |> put_in([:source, :fields], [:id, :name, :tenant_id, :account_id])
      |> put_in([:source, :columns, :account_id], %{type: :integer})
      |> put_in([:writes, :fields, :account_id], %{insertable: true})
      |> put_in([:writes, :constraints], %{})
      |> put_in([:writes, :constraints, :foreign_keys], %{})

    invalid = put_in(domain, [:writes, :constraints, :foreign_keys, :account_id], %{})

    assert {:error, %Error{type: :invalid_domain}} = WriteContract.compile(invalid)

    valid =
      put_in(domain, [:writes, :constraints, :foreign_keys, :account_id], %{
        source: {:context, :account_id},
        references: %{relation: "accounts", field: :id},
        required: true
      })

    assert {:ok, contract} = WriteContract.compile(valid)

    assert contract
           |> WriteContract.foreign_keys()
           |> Map.fetch!("account_id")
           |> Map.fetch!(:source) == {:context, :account_id}
  end

  defp command!(operation) do
    {:ok, command} =
      Command.new(%{
        operation: operation,
        relation: :items,
        assignments:
          if(operation == :delete, do: [], else: [%{field: :name, value: {:literal, "item"}}]),
        predicate: {:eq, {:field, :tenant_id}, {:context, :tenant_id}},
        required_capabilities: [operation]
      })

    command
  end

  defp read_domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name, :tenant_id],
        columns: %{id: %{type: :integer}, name: %{type: :string}, tenant_id: %{type: :integer}},
        associations: %{}
      },
      schemas: %{}
    }
  end

  defp write_domain do
    Map.put(read_domain(), :writes, %{
      operations: %{insert: %{enabled: true}, update: %{enabled: true, require_filter: true}},
      fields: %{
        name: %{insertable: true, updatable: true},
        tenant_id: %{insertable: false, updatable: false, immutable: true}
      },
      scope: %{tenant: %{required: true, field: :tenant_id}}
    })
  end
end
