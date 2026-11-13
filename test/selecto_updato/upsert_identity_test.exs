defmodule SelectoUpdato.UpsertIdentityTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.{ActionExecutionAdapter, PortableCommand}

  defmodule CompilePort do
    def execute_action(plan, context, opts) do
      operation =
        if target = Keyword.get(opts, :replacement_target),
          do: SelectoUpdato.conflict_target(plan.operation_builder, target),
          else: plan.operation_builder

      case PortableCommand.compile(operation, context: context, action_phase: :execute) do
        {:ok, command, _context} -> {:ok, command}
        {:error, _} = error -> error
      end
    end
  end

  test "selected variants and execution cases preserve ordered conflict identity before grants" do
    for action <- ["variant", "case", "combined"] do
      assert {:ok, plan} =
               SelectoUpdato.plan_domain_action(domain(), %{
                 "action" => action,
                 "inputs" => %{"choice" => "alternate"}
               })

      assert plan.execution.conflict_target == ["alternate"]
      assert plan.operation_intent.conflict_target == ["alternate"]
      assert {:ok, command} = ActionExecutionAdapter.execute(CompilePort, plan, %{})
      assert command.metadata.conflict_target == [:alternate]
      assert command.metadata.upsert_update_fields == ["name"]
      assert command.expected_cardinality == {:exactly, 1}
    end
  end

  test "changing a selected conflict identity refuses the issued action grant" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(domain(), %{
               "action" => "variant",
               "inputs" => %{"choice" => "alternate"}
             })

    assert {:error, %{details: %{code: :action_authorization_mismatch}}} =
             ActionExecutionAdapter.execute(CompilePort, plan, %{}, replacement_target: [:id])
  end

  test "undeclared, reordered, duplicate, and absent targets expose the stable admission code" do
    for target <- [[:name], [:alternate, :tenant_id], [:id, :id], nil] do
      operation =
        domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.upsert(%{id: 1, alternate: "a", tenant_id: 7, name: "selected"})

      operation = %{operation | conflict_target: target}

      assert {:error, %{details: %{code: :conflict_target_not_declared}}} =
               PortableCommand.compile(operation)
    end
  end

  defp domain do
    execution = %{
      "kind" => "updato",
      "operation" => "upsert",
      "conflict_target" => ["id"],
      "set" => %{"id" => 1, "alternate" => "b", "tenant_id" => 7, "name" => "selected"}
    }

    selected = %{execution | "conflict_target" => ["alternate"]}
    cases = [%{"when" => %{"choice" => "alternate"}, "conflict_target" => ["alternate"]}]

    action = %{
      "type" => "create",
      "inputs" => %{"choice" => %{"type" => "string", "required" => true}},
      "execution" => execution
    }

    %{
      name: "Upsert identity",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :alternate, :tenant_id, :name],
        columns: %{
          id: %{type: :integer},
          alternate: %{type: :string},
          tenant_id: %{type: :integer},
          name: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{
          upsert: %{
            enabled: true,
            conflict_targets: [[:id], [:alternate], [:tenant_id, :alternate]]
          }
        },
        fields: %{
          id: %{insertable: true},
          alternate: %{insertable: true},
          tenant_id: %{insertable: true},
          name: %{insertable: true, updatable: true}
        }
      },
      actions: %{
        "variant" =>
          Map.put(action, "variants", [
            %{"id" => "alternate", "when" => %{"choice" => "alternate"}, "execution" => selected}
          ]),
        "case" => %{action | "execution" => Map.put(execution, "cases", cases)},
        "combined" =>
          Map.put(action, "variants", [
            %{
              "id" => "alternate",
              "when" => %{"choice" => "alternate"},
              "execution" => Map.put(execution, "cases", cases)
            }
          ])
      }
    }
  end
end
