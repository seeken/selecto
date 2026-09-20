defmodule Selecto.DomainEditorsTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain

  test "publishes governed record editors and rejects fields outside update authority" do
    assert {:ok, normalized, _} = Domain.validate(domain())
    ui = Domain.project(normalized, :ui)

    assert ui.editors.order_profile.fields == [
             %{field: :status, control: :select, options: [%{value: "open", label: "Open"}]}
           ]

    assert ui.detail_actions.edit_order.type == :record_editor

    bad = put_in(domain(), [:editors, :order_profile, :fields], [:id])
    assert {:error, diagnostics} = Domain.validate(bad)
    assert Enum.any?(diagnostics.errors, &(&1.code == :editor_field_not_updatable))
  end

  test "allows public readonly association fields and bounded to-many collections" do
    authored =
      domain()
      |> put_in([:source, :associations], %{
        items: %{queryable: :items, owner_key: :id, related_key: :order_id, cardinality: :many}
      })
      |> put_in([:schemas], %{
        items: %{
          source_table: "order_items",
          primary_key: :id,
          fields: [:id, :order_id, :name],
          columns: %{
            id: %{type: :integer},
            order_id: %{type: :integer},
            name: %{type: :string}
          }
        }
      })
      |> put_in([:editors, :order_profile, :fields], [
        %{field: :status},
        %{field: "items.name", readonly: true, help: "Current item", section: "Details"}
      ])
      |> put_in([:editors, :order_profile, :collections], [
        %{id: :order_items, fields: ["items.name"], order_by: [["items.name", "asc"]], limit: 25}
      ])

    assert {:ok, normalized, _} = Domain.validate(authored)
    assert normalized.editors.order_profile.collections |> length() == 1

    bad = put_in(authored, [:editors, :order_profile, :fields, Access.at(1), :readonly], false)
    assert {:error, diagnostics} = Domain.validate(bad)
    assert Enum.any?(diagnostics.errors, &(&1.code == :editor_field_not_updatable))

    bad = put_in(authored, [:editors, :order_profile, :collections, Access.at(0), :limit], 101)
    assert {:error, diagnostics} = Domain.validate(bad)
    assert Enum.any?(diagnostics.errors, &(&1.code == :invalid_editor_collection_limit))
  end

  defp domain do
    %{
      schema_version: 1,
      name: :orders,
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :status],
        columns: %{id: %{type: :integer}, status: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{operations: %{update: %{enabled: true}}, fields: %{status: %{updatable: true}}},
      editors: %{
        order_profile: %{
          label: "Edit order",
          fields: [
            %{field: :status, control: :select, options: [%{value: "open", label: "Open"}]}
          ],
          actions: []
        }
      },
      detail_actions: %{
        edit_order: %{
          name: "Edit order",
          type: :record_editor,
          required_fields: [:id],
          payload: %{editor: :order_profile}
        }
      }
    }
  end
end
