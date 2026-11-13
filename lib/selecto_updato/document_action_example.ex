defmodule SelectoUpdato.DocumentActionExample do
  @moduledoc """
  Independently authored reservation and revision actions for synthetic work orders.

  This explicit write/action policy accompanies `Selecto.Document.Fixtures`; it
  is not generated from inference. Applications author and review their own policy.
  """

  @doc "An explicit ObjectId identity variant; the original domain authoring remains unchanged."
  def object_id_domain(release \\ Selecto.Document.Fixtures.object_id_release()) do
    release
    |> domain()
    |> put_in([:source, :columns, :id, :type], :object_id)
    |> put_in([:actions, :reserve_part, :inputs, :part_id, :type], :object_id)
  end

  @doc "Explicit scalar patch policy with a selected, replayable postimage."
  def patch_domain(release \\ Selecto.Document.Fixtures.patch_release()) do
    domain =
      if release["shape"]["fields"]["id"]["type"] == "object_id",
        do: object_id_domain(release),
        else: domain(release)

    fields = [:title, :priority, :expedited, :due_at, :customer_id]

    columns = %{
      title: %{type: :string},
      priority: %{type: :integer},
      expedited: %{type: :boolean},
      due_at: %{type: :string},
      customer_id: %{type: :object_id}
    }

    action = %{
      type: :detail_action,
      scope: :row,
      capability: "work_orders.revise",
      inputs: %{
        title: %{type: :string, required: true},
        priority: %{type: :integer, required: true},
        expedited: %{type: :boolean, required: true},
        expected_version: %{type: :integer, required: true},
        idempotency_key: %{type: :string, required: true}
      },
      execution: %{
        kind: :updato,
        operation: :update,
        set: %{},
        returning: [:id, :title, :priority, :expedited, :due_at, :version, :customer_id],
        document: %{
          shape_release: release,
          relation: "work_orders",
          expected_version_from: :expected_version,
          idempotency_key_from: :idempotency_key,
          mutations: [
            %{op: :set, field: :title, value_from: :title},
            %{op: :set, field: :priority, value_from: :priority},
            %{op: :set, field: :expedited, value_from: :expedited},
            %{op: :unset, field: :due_at}
          ],
          effects: ["work_orders.revised/v1"]
        }
      }
    }

    domain
    |> update_in([:source, :fields], &(&1 ++ fields))
    |> update_in([:source, :columns], &Map.merge(&1, columns))
    |> update_in([:writes, :fields], fn existing ->
      Enum.reduce(fields, existing, fn field, acc ->
        Map.put(acc, field, %{updatable: false, document_actions: [:revise_work_order]})
      end)
    end)
    |> put_in([:capabilities, "work_orders.revise"], %{
      operations: [:action, :update],
      action: :revise_work_order
    })
    |> put_in([:actions, :revise_work_order], action)
  end

  def domain(release \\ Selecto.Document.Fixtures.release()) do
    %{
      name: "Document Work Orders",
      source: %{
        source_table: "work_orders",
        primary_key: :id,
        fields: [:id, :tenant_id, :version, :parts],
        columns: %{
          id: %{type: :string},
          tenant_id: %{type: :string},
          version: %{type: :integer},
          parts: %{type: :map}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          update: %{
            enabled: true,
            require_filter: true,
            expected_cardinality: {:exactly, 1},
            returning: :none
          }
        },
        fields: %{
          id: %{updatable: false, server_managed: true},
          tenant_id: %{updatable: false, server_managed: true},
          version: %{updatable: false, server_managed: true},
          parts: %{updatable: false, document_actions: [:reserve_part]}
        },
        scope: %{tenant: %{required: true, field: :tenant_id}}
      },
      capabilities: %{
        "work_orders.parts.reserve" => %{
          operations: [:action, :update],
          action: :reserve_part
        }
      },
      actions: %{
        reserve_part: %{
          type: :detail_action,
          scope: :row,
          capability: "work_orders.parts.reserve",
          inputs: %{
            part_id: %{type: :string, required: true},
            quantity: %{type: :integer, required: true},
            expected_version: %{type: :integer, required: true},
            idempotency_key: %{type: :string, required: true}
          },
          execution: %{
            kind: :updato,
            operation: :update,
            set: %{},
            returning: :none,
            document: %{
              shape_release: release,
              relation: "work_orders",
              expected_version_from: :expected_version,
              idempotency_key_from: :idempotency_key,
              mutations: [
                %{
                  op: :update_element,
                  path: ["parts"],
                  identity: %{path: ["part_id"], value_from: :part_id},
                  patch: [%{op: :increment, path: ["reserved"], value_from: :quantity}]
                }
              ],
              effects: ["work_orders.part_reserved/v1"]
            }
          }
        }
      }
    }
  end
end
