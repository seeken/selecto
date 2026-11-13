defmodule SelectoUpdato.TenantTest do
  use ExUnit.Case, async: true

  test "with_tenant stores normalized context" do
    op =
      domain()
      |> SelectoUpdato.new(timeout: 5000)
      |> SelectoUpdato.with_tenant(tenant_id: "acme")

    assert SelectoUpdato.tenant(op) == %{
             tenant_id: "acme",
             tenant_field: "tenant_id",
             required: nil,
             required_filters: []
           }
  end

  test "apply_tenant_scope appends required tenant filter" do
    op =
      domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: "acme"})
      |> SelectoUpdato.apply_tenant_scope()

    assert op.filters == [{"tenant_id", "acme"}]
  end

  test "apply_tenant_scope does not mistake a conflicting filter for trusted scope" do
    op =
      domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({"tenant_id", "other"})
      |> SelectoUpdato.with_tenant(%{tenant_id: "acme"})
      |> SelectoUpdato.apply_tenant_scope()

    assert op.filters == [{"tenant_id", "other"}, {"tenant_id", "acme"}]
  end

  test "validate_tenant_scope returns error when domain requires tenant scope" do
    op =
      tenant_required_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "Updated"})
      |> SelectoUpdato.filter({"id", 1})

    assert {:error, %SelectoUpdato.Error{type: :missing_tenant_scope}} =
             SelectoUpdato.validate_tenant_scope(op)
  end

  test "validate_tenant_scope passes when required tenant filter is present" do
    op =
      tenant_required_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "Updated"})
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.require_tenant_filter("tenant_id", "acme")

    assert :ok = SelectoUpdato.validate_tenant_scope(op)
  end

  test "dry_run requires a configured Selecto value" do
    op =
      tenant_required_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "Updated"})
      |> SelectoUpdato.filter({"id", 1})

    assert {:error, %SelectoUpdato.Error{type: :configured_selecto_required}} =
             SelectoUpdato.dry_run(op, __MODULE__.FakeRepo)
  end

  test "tenant-required insert can satisfy scope from attrs payload" do
    op =
      tenant_required_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{name: "Item", tenant_id: "acme"})

    assert :ok = SelectoUpdato.validate_tenant_scope(op)
  end

  test "canonical tenant scope reads required field from writes.scope" do
    op =
      canonical_tenant_scope_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "Updated"})
      |> SelectoUpdato.filter({"id", 1})

    assert {:error, %SelectoUpdato.Error{type: :missing_tenant_scope} = error} =
             SelectoUpdato.validate_tenant_scope(op)

    assert error.details.tenant_field == "account_id"
  end

  test "canonical tenant scope defaults to trusted context, not payload" do
    payload_only =
      canonical_tenant_scope_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{name: "Item", account_id: "acme"})

    assert {:error, %SelectoUpdato.Error{type: :missing_tenant_scope}} =
             SelectoUpdato.validate_tenant_scope(payload_only)

    trusted_context =
      canonical_tenant_scope_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{name: "Item"})
      |> SelectoUpdato.with_tenant(%{tenant_id: "acme"})

    assert :ok = SelectoUpdato.validate_tenant_scope(trusted_context)
  end

  test "canonical tenant scope can explicitly allow payload satisfaction" do
    op =
      canonical_tenant_scope_domain([:payload])
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{name: "Item", account_id: "acme"})

    assert :ok = SelectoUpdato.validate_tenant_scope(op)
  end

  test "apply_execution_scope injects trusted canonical tenant filter" do
    op =
      canonical_tenant_scope_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "Updated"})
      |> SelectoUpdato.filter({"id", 1})

    scoped = SelectoUpdato.apply_execution_scope(op, tenant: %{tenant_id: "acme"})

    assert {"account_id", "acme"} in scoped.filters

    assert SelectoUpdato.applied_scope(scoped) == %{
             tenant: %{
               required: true,
               field: "account_id",
               sources: [
                 %{
                   source: :trusted_context,
                   field: "account_id",
                   value: "acme",
                   filter: {"account_id", "acme"}
                 }
               ]
             }
           }

    assert :ok = SelectoUpdato.validate_tenant_scope(scoped)
  end

  test "apply_execution_scope records conflicting trusted tenant sources" do
    operation =
      portable_tenant_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: "operation-tenant"})
      |> SelectoUpdato.update(%{name: "Updated"})
      |> SelectoUpdato.filter({"id", 1})

    scoped =
      SelectoUpdato.apply_execution_scope(operation,
        tenant: %{tenant_id: "execution-tenant"}
      )

    assert %{
             operation_tenant: %{
               tenant_id: "operation-tenant",
               tenant_field: "tenant_id"
             },
             execution_tenant: %{
               tenant_id: "execution-tenant",
               tenant_field: "tenant_id"
             }
           } = SelectoUpdato.Tenant.context_conflict(scoped)

    assert {:error,
            %SelectoUpdato.Error{
              type: :tenant_mismatch,
              details: %{code: :conflicting_trusted_tenant_context}
            }} = SelectoUpdato.PortableCommand.compile(scoped)
  end

  test "execution scope rejects internally ambiguous trusted tenant contexts" do
    base =
      portable_tenant_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.update(%{name: "Updated"})
      |> SelectoUpdato.filter({"id", 1})

    ambiguous_operations = [
      SelectoUpdato.apply_execution_scope(base,
        tenant: %{tenant_id: "tenant-a"},
        tenant_id: "tenant-b"
      ),
      SelectoUpdato.apply_execution_scope(base,
        tenant_id: "tenant-a",
        tenant_id: "tenant-b"
      ),
      SelectoUpdato.apply_execution_scope(base,
        tenant: %{"tenant_id" => "tenant-b", tenant_id: "tenant-a"}
      ),
      SelectoUpdato.apply_execution_scope(base,
        tenant: %{
          "tenant_field" => "other_tenant_id",
          tenant_field: "tenant_id",
          tenant_id: "tenant-a"
        }
      ),
      base
      |> SelectoUpdato.with_tenant(%{"tenant_id" => "tenant-b", tenant_id: "tenant-a"})
      |> SelectoUpdato.apply_execution_scope()
    ]

    for operation <- ambiguous_operations do
      assert {:error,
              %SelectoUpdato.Error{
                type: :tenant_mismatch,
                details: %{code: :conflicting_trusted_tenant_context}
              }} = SelectoUpdato.PortableCommand.compile(operation)
    end
  end

  test "equivalent atom and string tenant identities remain valid" do
    operation =
      portable_tenant_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{"tenant_id" => "tenant-a", tenant_id: "tenant-a"})
      |> SelectoUpdato.update(%{name: "Updated"})
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.apply_execution_scope()

    assert {:ok, %Selecto.Write.Command{}, %{tenant_id: "tenant-a"}} =
             SelectoUpdato.PortableCommand.compile(operation)
  end

  test "portable compilation rejects ambiguous tenant identity in opts context" do
    operation =
      portable_tenant_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: "tenant-a"})
      |> SelectoUpdato.update(%{name: "Updated"})
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.apply_execution_scope()

    ambiguous_contexts = [
      %{"tenant_id" => "tenant-b", tenant_id: "tenant-a"},
      %{
        "tenant" => %{tenant_id: "tenant-b"},
        tenant: %{tenant_id: "tenant-a"}
      },
      %{
        tenant: %{tenant_id: "tenant-a", tenant_field: "account_id"},
        tenant_field: "tenant_id"
      }
    ]

    for context <- ambiguous_contexts do
      assert {:error,
              %SelectoUpdato.Error{
                type: :tenant_mismatch,
                details: %{code: :conflicting_trusted_tenant_context}
              }} = SelectoUpdato.PortableCommand.compile(operation, context: context)
    end
  end

  defp domain do
    %{
      source: %{source_table: "items"},
      columns: %{
        "id" => %{type: :integer},
        "tenant_id" => %{type: :string},
        "name" => %{type: :string}
      }
    }
  end

  defp tenant_required_domain do
    Map.put(domain(), :tenant_required, true)
  end

  defp canonical_tenant_scope_domain(satisfied_by \\ nil) do
    tenant =
      %{
        required: true,
        field: :account_id
      }
      |> maybe_put(:satisfied_by, satisfied_by)

    domain()
    |> put_in([:columns, "account_id"], %{type: :string})
    |> Map.put(:writes, %{scope: %{tenant: tenant}})
  end

  defp portable_tenant_domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :tenant_id, :name],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :string},
          name: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      writes: %{
        operations: %{update: %{enabled: true, require_filter: true}},
        fields: %{
          tenant_id: %{insertable: true, immutable: true},
          name: %{updatable: true}
        },
        scope: %{
          tenant: %{required: true, field: :tenant_id, satisfied_by: [:trusted_context]}
        },
        relationships: %{}
      }
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defmodule FakeRepo do
  end
end
