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
