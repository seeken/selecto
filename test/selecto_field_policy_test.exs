defmodule Selecto.FieldPolicyTest do
  use ExUnit.Case, async: true

  alias Selecto.FieldPolicy

  test "resolves visibility, editability, action-backed fields, and accepted assignments" do
    decisions = %{
      "orders.view_amount" => %{status: :enabled},
      "orders.edit_amount" => %{
        status: :disabled,
        reason: "Accounting is locked",
        reason_code: "locked"
      }
    }

    assert {:ok, policy} =
             FieldPolicy.new(domain(),
               authorize: &Map.get(decisions, &1.capability, %{status: :enabled})
             )

    assert {:ok, resolved} =
             FieldPolicy.resolve(policy,
               operation: :update,
               snapshot: %{id: 12, status: "A", amount: Decimal.new("99.5"), secret: "nope"},
               profile: [
                 %{field: :id},
                 %{field: :status},
                 %{
                   field: :amount,
                   view_capability: "orders.view_amount",
                   edit_capability: "orders.edit_amount"
                 },
                 %{field: :secret},
                 %{field: "customer.name"}
               ]
             )

    assert Enum.map(resolved, & &1.state) == [
             :read_only,
             :editable,
             :read_only,
             :hidden,
             :read_only
           ]

    assert Enum.at(resolved, 0).label == "Order ID"
    assert Enum.at(resolved, 2).reason_code == "locked"
    assert Enum.at(resolved, 3).reason_code == "field_not_public"

    assert {:ok, [insert]} =
             FieldPolicy.resolve(policy, operation: :insert, profile: [%{field: :status}])

    assert insert.required

    assert {:ok, [action]} =
             FieldPolicy.resolve(policy,
               operation: :update,
               profile: [%{field: :status, action: :transition_status}]
             )

    assert action.state == :action_backed

    assert {:ok, ["status"]} =
             FieldPolicy.accepted_fields(policy, operation: :update, profile: [:status, :id])
  end

  defp domain do
    %{
      schema_version: 1,
      name: :orders,
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :status, :amount, :secret, :customer_id],
        columns: %{
          id: %{type: :integer, label: "Order ID"},
          status: %{type: :string},
          amount: %{type: :decimal},
          secret: %{type: :string, internal: true},
          customer_id: %{type: :integer}
        },
        associations: %{
          customer: %{queryable: :customers, owner_key: :customer_id, related_key: :id}
        }
      },
      schemas: %{
        customers: %{
          source_table: "customers",
          primary_key: :id,
          fields: [:id, :name],
          columns: %{id: %{type: :integer}, name: %{type: :string, label: "Customer"}},
          associations: %{}
        }
      },
      joins: %{customer: %{type: :left}},
      writes: %{
        operations: %{insert: %{enabled: true}, update: %{enabled: true}},
        fields: %{
          status: %{insertable: true, updatable: true, required: true},
          amount: %{insertable: true, updatable: true}
        }
      }
    }
  end
end
