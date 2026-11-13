defmodule SelectoUpdato.TenantWriteSafetyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @write_types [:insert, :upsert, :update, :delete]

  property "tenant-required operations fail validation when scope is missing" do
    check all(type <- member_of(@write_types)) do
      op =
        tenant_required_domain()
        |> SelectoUpdato.new()
        |> build_operation(type)

      assert {:error, %SelectoUpdato.Error{type: :missing_tenant_scope}} =
               SelectoUpdato.validate_tenant_scope(op)
    end
  end

  property "tenant context id satisfies tenant scope for all write types" do
    check all(
            type <- member_of(@write_types),
            tenant_id <- string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      with_id =
        tenant_required_domain()
        |> SelectoUpdato.new()
        |> build_operation(type)
        |> SelectoUpdato.with_tenant(%{tenant_id: tenant_id})
        |> SelectoUpdato.apply_tenant_scope()

      assert :ok = SelectoUpdato.validate_tenant_scope(with_id)
    end
  end

  property "payload tenant_id satisfies scope for write types with payloads" do
    check all(
            type <- member_of([:insert, :upsert, :update]),
            tenant_id <- string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      op =
        tenant_required_domain()
        |> SelectoUpdato.new()
        |> build_operation(type, tenant_id)

      assert :ok = SelectoUpdato.validate_tenant_scope(op)
    end
  end

  property "explicit tenant filter always satisfies required tenant scope" do
    check all(
            type <- member_of(@write_types),
            tenant_id <- string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      op =
        tenant_required_domain()
        |> SelectoUpdato.new()
        |> build_operation(type)
        |> SelectoUpdato.require_tenant_filter("tenant_id", tenant_id)

      assert :ok = SelectoUpdato.validate_tenant_scope(op)
      assert {"tenant_id", tenant_id} in op.filters
    end
  end

  defp build_operation(op, :insert) do
    SelectoUpdato.insert(op, %{name: "item", status: "draft"})
  end

  defp build_operation(op, :upsert) do
    SelectoUpdato.upsert(op, %{name: "item", status: "draft"})
  end

  defp build_operation(op, :update) do
    op
    |> SelectoUpdato.update(%{status: "updated"})
    |> SelectoUpdato.filter({"id", 1})
  end

  defp build_operation(op, :delete) do
    op
    |> SelectoUpdato.delete()
    |> SelectoUpdato.filter({"id", 1})
  end

  defp build_operation(op, :insert, tenant_id) do
    SelectoUpdato.insert(op, %{name: "item", status: "draft", tenant_id: tenant_id})
  end

  defp build_operation(op, :upsert, tenant_id) do
    SelectoUpdato.upsert(op, %{name: "item", status: "draft", tenant_id: tenant_id})
  end

  defp build_operation(op, :update, tenant_id) do
    op
    |> SelectoUpdato.update(%{status: "updated", tenant_id: tenant_id})
    |> SelectoUpdato.filter({"id", 1})
  end

  defp tenant_required_domain do
    %{
      source: %{source_table: "items"},
      tenant_required: true,
      columns: %{
        "id" => %{type: :integer},
        "tenant_id" => %{type: :string},
        "name" => %{type: :string},
        "status" => %{type: :string}
      }
    }
  end
end
