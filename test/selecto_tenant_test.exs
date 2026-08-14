defmodule Selecto.TenantTest do
  use ExUnit.Case, async: true

  defmodule Adapter do
    def placeholder(_index), do: "?"
    def execute(:ok, _query, _params, _opts), do: {:ok, %{rows: [[1]], columns: ["id"]}}
  end

  defp domain do
    %{
      name: "Accounts",
      source: %{
        source_table: "accounts",
        primary_key: :id,
        fields: [:id, :name, :active, :tenant_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          active: %{type: :boolean},
          tenant_id: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      required_filters: [{"active", true}]
    }
  end

  defp selecto(domain_map),
    do: Selecto.configure(domain_map, [hostname: "localhost"], validate: false)

  defp tenant_required_domain do
    Map.put(domain(), :tenant_required, true)
  end

  test "with_tenant stores normalized context" do
    query =
      domain()
      |> selecto()
      |> Selecto.with_tenant(tenant_id: "acme", prefix: "tenant_acme")

    assert Selecto.tenant(query) == %{
             tenant_id: "acme",
             tenant_mode: nil,
             tenant_field: "tenant_id",
             prefix: "tenant_acme",
             namespace: "tenant",
             required: nil,
             required_filters: []
           }
  end

  test "apply_tenant_scope adds tenant filter as required filter" do
    query =
      domain()
      |> selecto()
      |> Selecto.with_tenant(%{tenant_id: "acme"})
      |> Selecto.apply_tenant_scope()

    assert Selecto.required_filters(query) == [{"active", true}, {"tenant_id", "acme"}]
  end

  test "apply_tenant_scope supports an explicit tenant id without prior context" do
    query =
      tenant_required_domain()
      |> selecto()
      |> Selecto.apply_tenant_scope(tenant_id: "acme")

    assert Selecto.tenant(query).tenant_id == "acme"
    assert {"tenant_id", "acme"} in Selecto.required_filters(query)
    assert :ok = Selecto.validate_tenant_scope(query)
  end

  test "compatible partial tenant overrides preserve required scope metadata" do
    query =
      tenant_required_domain()
      |> selecto()
      |> Selecto.with_tenant(%{
        tenant_id: "acme",
        prefix: "tenant_acme",
        required: true,
        required_filters: [{"active", true}]
      })
      |> Selecto.apply_tenant_scope(tenant: %{tenant_id: "acme"})

    assert %{tenant_id: "acme", prefix: "tenant_acme", required: true} = Selecto.tenant(query)
    assert {"active", true} in Selecto.required_filters(query)
    assert {"tenant_id", "acme"} in Selecto.required_filters(query)
  end

  test "query_filters includes runtime required tenant filters" do
    query =
      domain()
      |> selecto()
      |> Selecto.require_tenant_filter("tenant_id", "acme")

    assert Selecto.query_filters(query) == [{"active", true}, {"tenant_id", "acme"}]
  end

  test "tenant prefix is merged into execute options when missing" do
    query =
      domain()
      |> selecto()
      |> Selecto.with_tenant(%{tenant_id: "acme", prefix: "tenant_acme"})

    assert Selecto.Tenant.merge_execution_opts(query, timeout: 1000) ==
             [prefix: "tenant_acme", timeout: 1000]

    assert Selecto.Tenant.merge_execution_opts(query, prefix: "tenant_acme") ==
             [prefix: "tenant_acme"]

    assert_raise ArgumentError, ~r/execution prefix conflicts/, fn ->
      Selecto.Tenant.merge_execution_opts(query, prefix: "tenant_other")
    end
  end

  test "tenant required filters appear in generated sql" do
    {sql, params} =
      domain()
      |> selecto()
      |> Selecto.select(["name"])
      |> Selecto.with_tenant(%{tenant_id: "acme"})
      |> Selecto.apply_tenant_scope()
      |> Selecto.to_sql()

    assert sql =~ ~r/where/i
    assert sql =~ "active"
    assert sql =~ "tenant_id"
    assert true in params
    assert "acme" in params
  end

  test "to_sql enforces required tenant scope unless explicitly disabled" do
    query =
      tenant_required_domain()
      |> selecto()
      |> Selecto.select(["name"])

    assert_raise RuntimeError, ~r/Tenant scope is required but missing/, fn ->
      Selecto.to_sql(query)
    end

    assert {_sql, _params} = Selecto.to_sql(query, validate_tenant: false)
  end

  test "validate_tenant_scope returns error when tenant is required but missing" do
    query =
      tenant_required_domain()
      |> selecto()

    assert {:error, %Selecto.Error{type: :validation_error}} =
             Selecto.validate_tenant_scope(query)
  end

  test "tenant context id does not satisfy required scope until it becomes a filter" do
    query =
      tenant_required_domain()
      |> selecto()
      |> Selecto.with_tenant(%{tenant_id: "acme", required: true})

    assert {:error, %Selecto.Error{type: :validation_error}} =
             Selecto.validate_tenant_scope(query)

    assert :ok =
             query
             |> Selecto.apply_tenant_scope()
             |> Selecto.validate_tenant_scope()
  end

  test "tenant validation rejects mismatched and ambiguous required row scope" do
    base =
      tenant_required_domain()
      |> selecto()
      |> Selecto.with_tenant(%{tenant_id: "acme", required: true})

    mismatched = Selecto.require_tenant_filter(base, "tenant_id", "other")

    assert {:error,
            %Selecto.Error{
              details: %{code: :tenant_scope_mismatch, expected_tenant_id: "acme"}
            }} = Selecto.validate_tenant_scope(mismatched)

    ambiguous =
      base
      |> Selecto.require_tenant_filter("tenant_id", "acme")
      |> Selecto.require_tenant_filter("tenant_id", "other")

    assert {:error, %Selecto.Error{details: %{code: :tenant_scope_ambiguous}}} =
             Selecto.validate_tenant_scope(ambiguous)
  end

  test "compound prefix and row scope requires an applied matching row identity" do
    compound =
      tenant_required_domain()
      |> selecto()
      |> Selecto.with_tenant(%{
        prefix: "tenant_acme",
        tenant_id: "acme",
        required: true
      })

    assert {:error, %Selecto.Error{details: %{code: :tenant_scope_missing}}} =
             Selecto.validate_tenant_scope(compound)

    assert :ok =
             compound
             |> Selecto.apply_tenant_scope()
             |> Selecto.validate_tenant_scope()

    assert {:error, %Selecto.Error{details: %{code: :tenant_scope_mismatch}}} =
             compound
             |> Selecto.require_tenant_filter("tenant_id", "other")
             |> Selecto.validate_tenant_scope()
  end

  test "tenant context aliases and scope overrides fail closed on conflicts" do
    query = domain() |> selecto()

    assert_raise ArgumentError, ~r/conflicting tenant context aliases/, fn ->
      Selecto.with_tenant(query, %{"tenant_id" => "other", tenant_id: "acme"})
    end

    assert_raise ArgumentError, ~r/conflicting tenant context keys :tenant_id and :id/, fn ->
      Selecto.with_tenant(query, %{tenant_id: "acme", id: "other"})
    end

    attached = Selecto.with_tenant(query, %{tenant_id: "acme", tenant_field: "tenant_id"})

    assert_raise ArgumentError, ~r/tenant_id override conflicts/, fn ->
      Selecto.apply_tenant_scope(attached, tenant_id: "other")
    end

    assert_raise ArgumentError, ~r/tenant_field override conflicts/, fn ->
      Selecto.apply_tenant_scope(attached, tenant_field: "account_id")
    end

    assert_raise ArgumentError, ~r/tenant override conflicts/, fn ->
      Selecto.apply_tenant_scope(attached, tenant: %{tenant_id: "other"})
    end
  end

  test "query_filters raises when tenant is required and missing" do
    query =
      tenant_required_domain()
      |> selecto()

    assert_raise RuntimeError, ~r/Tenant scope is required but missing/, fn ->
      Selecto.query_filters(query)
    end
  end

  test "query_filters works when tenant required scope is present" do
    query =
      tenant_required_domain()
      |> selecto()
      |> Selecto.with_tenant(%{tenant_id: "acme", required: true})
      |> Selecto.apply_tenant_scope()

    assert {"tenant_id", "acme"} in Selecto.query_filters(query)
  end

  test "execute fails early when tenant required scope is missing" do
    query =
      tenant_required_domain()
      |> selecto()
      |> Selecto.select(["id"])
      |> Map.put(:adapter, Adapter)
      |> Map.put(:connection, :ok)

    assert {:error, %Selecto.Error{type: :validation_error}} =
             Selecto.execute(query, analyze_complexity: false)
  end

  test "execute succeeds when tenant required scope is present" do
    query =
      tenant_required_domain()
      |> selecto()
      |> Selecto.select(["id"])
      |> Selecto.with_tenant(%{tenant_id: "acme", required: true})
      |> Selecto.apply_tenant_scope()
      |> Map.put(:adapter, Adapter)
      |> Map.put(:connection, :ok)

    assert {:ok, {[[1]], ["id"], aliases}} =
             Selecto.execute(query, analyze_complexity: false)

    assert length(aliases) == 1
  end
end
