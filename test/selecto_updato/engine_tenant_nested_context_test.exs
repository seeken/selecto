defmodule SelectoUpdato.EngineTenantNestedContextTest do
  # The engine tenant attached to a configured Selecto must agree with the
  # execution context's tenant however that context spells it. A tenant nested
  # under :tenant with its own tenant_field counts as present: injecting a bare
  # tenant_id beside it used to default the field to "tenant_id" and turn one
  # agreeing tenant into a conflicting_trusted_tenant_context refusal.
  use ExUnit.Case, async: true

  alias SelectoUpdato.{Executor, Tenant}

  defp domain do
    %{
      name: "Equipment",
      source: %{
        source_table: "equipment",
        primary_key: :id,
        fields: [:id, :site_id, :hourly_rate_cents],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          site_id: %{type: :integer},
          hourly_rate_cents: %{type: :integer}
        },
        associations: %{},
        tenant_field: :site_id
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp engine(tenant_id) do
    domain()
    |> Selecto.configure(Selecto.Runtime.Context.new(SelectoDBPostgreSQL.Adapter, :compile_only),
      validate: false
    )
    |> Selecto.with_tenant(%{tenant_id: tenant_id, tenant_field: :site_id})
  end

  defp operation do
    domain()
    |> SelectoUpdato.new(tenant: %{tenant_id: 2, tenant_field: :site_id, required: true})
    |> SelectoUpdato.update(%{hourly_rate_cents: 1850})
    |> SelectoUpdato.filter({:id, 3})
  end

  test "an agreeing tenant nested in the context is left as the only tenant" do
    context = %{actor: %{id: "rosa"}, tenant: %{id: 2, tenant_id: 2, tenant_field: :site_id}}

    assert {:ok, opts} = Executor.engine_tenant_opts(operation(), engine(2), context: context)
    assert Keyword.fetch!(opts, :context) == context
    assert {:ok, _context} = Tenant.resolve_trusted_context(operation(), context)
  end

  test "a disagreeing tenant nested in the context is refused" do
    context = %{tenant: %{tenant_id: 3, tenant_field: :site_id}}

    assert {:error,
            %SelectoUpdato.Error{
              type: :tenant_mismatch,
              details: %{code: :conflicting_trusted_tenant_context}
            }} = Executor.engine_tenant_opts(operation(), engine(2), context: context)
  end

  test "an injected engine tenant carries the declared field and resolves cleanly" do
    assert {:ok, opts} = Executor.engine_tenant_opts(operation(), engine(2), context: %{})
    context = Keyword.fetch!(opts, :context)

    assert context.tenant_id == 2
    assert to_string(context.tenant_field) == "site_id"
    assert {:ok, _context} = Tenant.resolve_trusted_context(operation(), context)
  end

  test "an operation tenant that names no field still resolves beside the engine tenant" do
    operation =
      domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 2})
      |> SelectoUpdato.update(%{hourly_rate_cents: 1850})
      |> SelectoUpdato.filter({:id, 3})

    assert {:ok, opts} = Executor.engine_tenant_opts(operation, engine(2), context: %{})
    context = Keyword.fetch!(opts, :context)

    assert context.tenant_id == 2
    assert {:ok, _context} = Tenant.resolve_trusted_context(operation, context)
  end

  test "a direct context tenant still compares exactly" do
    assert {:ok, _opts} =
             Executor.engine_tenant_opts(operation(), engine(2), context: %{tenant_id: 2})

    assert {:error, %SelectoUpdato.Error{type: :tenant_mismatch}} =
             Executor.engine_tenant_opts(operation(), engine(2), context: %{tenant_id: "2"})
  end
end
