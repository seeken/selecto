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

  test "transaction connection rebinding retains authorization and query state" do
    scoped =
      tenant_required_domain()
      |> selecto()
      |> Selecto.with_tenant(%{tenant_id: "acme", required: true})
      |> Selecto.apply_tenant_scope()
      |> Selecto.filter({"name", "Ada"})
      |> Selecto.limit(1)

    rebound = Selecto.with_runtime_connection(scoped, :transaction_handle)
    assert rebound.runtime.connection == :transaction_handle
    assert rebound.connection == :transaction_handle
    assert rebound.runtime.adapter == scoped.runtime.adapter
    assert rebound.domain == scoped.domain
    assert rebound.policy == scoped.policy
    assert rebound.tenant == scoped.tenant
    assert rebound.set == scoped.set
    assert scoped.connection != :transaction_handle
  end

  test "unpaginate keeps authorized filtered membership for a separate exact count" do
    page =
      tenant_required_domain()
      |> selecto()
      |> Selecto.with_tenant(%{tenant_id: "acme", required: true})
      |> Selecto.apply_tenant_scope()
      |> Selecto.filter({"name", "Ada"})
      |> Selecto.select(["id"])
      |> Selecto.order_by([{"id", :asc}])
      |> Selecto.limit(1)
      |> Selecto.offset(2)

    full_filtered = Selecto.unpaginate(page)

    assert page.set.limit == 1
    assert page.set.offset == 2
    refute Map.has_key?(full_filtered.set, :limit)
    refute Map.has_key?(full_filtered.set, :offset)
    assert full_filtered.set.selected == page.set.selected
    assert full_filtered.set.order_by == page.set.order_by
    assert Selecto.required_filters(full_filtered) == Selecto.required_filters(page)
    assert Selecto.query_filters(full_filtered) == Selecto.query_filters(page)
    assert :ok == Selecto.validate_tenant_scope(full_filtered)

    {sql, _aliases, params} = Selecto.gen_sql(full_filtered, [])
    refute sql =~ ~r/\b(?:LIMIT|OFFSET)\b/i
    assert length(params) >= 2

    count_input = Selecto.root_count_query(page, "id")
    assert count_input.set.selected == ["id"]
    assert count_input.set.order_by == []
    assert count_input.set.subselected == []
    assert Selecto.required_filters(count_input) == Selecto.required_filters(page)
    assert Selecto.query_filters(count_input) == Selecto.query_filters(page)
    assert :ok == Selecto.validate_tenant_scope(count_input)

    {count_sql, _aliases, count_params} = Selecto.gen_sql(count_input, [])
    refute count_sql =~ ~r/\b(?:ORDER BY|LIMIT|OFFSET)\b/i
    assert count_params == params

    assert_raise ArgumentError, "root count requires an ungrouped detail query", fn ->
      page |> Selecto.group_by(["name"]) |> Selecto.root_count_query("id")
    end
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

  defp tenant_field_domain(required_filters, writes \\ nil) do
    domain =
      domain()
      |> put_in([:source, :tenant_field], :tenant_id)
      |> Map.put(:required_filters, required_filters)

    if writes, do: Map.put(domain, :writes, writes), else: domain
  end

  defp scoped_writes,
    do: %{scope: %{tenant: %{required: true, field: :tenant_id}}}

  describe "tenant boundary (specification 2.19.0)" do
    test "tenant_conjunct? admits only positive equality or nonempty IN at top level or beneath AND" do
      admitted = [
        [{"tenant_id", "acme"}],
        [{:tenant_id, 7}],
        [{"tenant_id", {:eq, "acme"}}],
        [{"tenant_id", {:=, "acme"}}],
        [{"tenant_id", {"=", "acme"}}],
        [{"tenant_id", {:in, ["acme", "beta"]}}],
        [{"tenant_id", ["acme"]}],
        [{"active", true}, {"tenant_id", "acme"}],
        [{:and, [{"active", true}, {:and, [{"tenant_id", {:in, ["acme"]}}]}]}]
      ]

      for filters <- admitted do
        assert Selecto.Tenant.tenant_conjunct?(filters, "tenant_id"), inspect(filters)
        assert Selecto.Tenant.tenant_conjunct?(filters, :tenant_id), inspect(filters)
      end

      refused = [
        [],
        [{"id", 4}],
        [{"active", true}],
        [{:or, [{"tenant_id", "acme"}, {"id", 4}]}],
        [{:not, {"tenant_id", "beta"}}],
        [{:and, [{:or, [{"tenant_id", "acme"}]}]}],
        [{"tenant_id", nil}],
        [{"tenant_id", {:eq, nil}}],
        [{"tenant_id", :not_null}],
        [{"tenant_id", {:in, []}}],
        [{"tenant_id", []}],
        [{"tenant_id", {:in, ["acme", nil]}}],
        [{"tenant_id", {:ref, "id"}}],
        [{"tenant_id", {:eq, {:ref, "id"}}}],
        [{"tenant_id", {:not_in, ["beta"]}}],
        [{"tenant_id", {:!=, "beta"}}],
        [{"tenant_id", {:gt, "a"}}],
        [{"tenant_id", {:like, "a%"}}],
        [{"other.tenant_id", "acme"}],
        [{:and, []}]
      ]

      for filters <- refused do
        refute Selecto.Tenant.tenant_conjunct?(filters, "tenant_id"), inspect(filters)
      end
    end

    test "domains without tenant_field need no boundary" do
      assert Selecto.Tenant.domain_tenant_field(domain()) == nil
      assert {:ok, :not_required} = Selecto.Tenant.tenant_boundary(selecto(domain()))

      assert {:ok, :not_required} =
               Selecto.Tenant.tenant_boundary(selecto(domain()), access: :write)
    end

    test "a tenant conjunct in the trusted host scope bounds reads and writes" do
      for required <- [
            [{"tenant_id", "acme"}],
            [{:and, [{"tenant_id", {:in, ["acme"]}}, {"id", {:in, [1, 2]}}]}]
          ],
          access <- [:read, :write] do
        query = selecto(tenant_field_domain(required))
        assert Selecto.Tenant.domain_tenant_field(query) == "tenant_id"
        assert {:ok, :host_scope} = Selecto.Tenant.tenant_boundary(query, access: access)
      end

      host_filtered =
        tenant_field_domain([]) |> selecto() |> Selecto.filter({"tenant_id", "acme"})

      assert {:ok, :host_scope} = Selecto.Tenant.tenant_boundary(host_filtered, access: :write)

      assert {:ok, :host_scope} =
               Selecto.Tenant.tenant_boundary(selecto(tenant_field_domain([])),
                 scope: {"tenant_id", "acme"}
               )
    end

    test "non-tenant, OR, NOT and absent host scopes fail with missing_tenant_scope" do
      for required <- [
            [{"id", 4}],
            [{"active", true}],
            [{:or, [{"tenant_id", "acme"}, {"id", 4}]}],
            [{:not, {"tenant_id", "beta"}}],
            []
          ],
          access <- [:read, :write] do
        query = selecto(tenant_field_domain(required))

        assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
                 Selecto.Tenant.tenant_boundary(query, access: access)

        assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
                 Selecto.Tenant.require_read_boundary(query, scope: [{"id", 4}])
      end
    end

    test "a trusted tenant bounds reads, and writes only under writes.scope.tenant" do
      attached =
        tenant_field_domain([])
        |> selecto()
        |> Selecto.with_tenant(%{tenant_id: "acme", tenant_field: "tenant_id"})

      assert {:ok, {:tenant, "acme"}} = Selecto.Tenant.tenant_boundary(attached)

      assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
               Selecto.Tenant.tenant_boundary(attached, access: :write)

      scoped =
        tenant_field_domain([], scoped_writes())
        |> selecto()
        |> Selecto.with_tenant(%{tenant_id: "acme", tenant_field: "tenant_id"})

      assert {:ok, {:tenant, "acme"}} = Selecto.Tenant.tenant_boundary(scoped, access: :write)

      # A tenant attached for another field is not this domain's boundary.
      other =
        tenant_field_domain([], scoped_writes())
        |> selecto()
        |> Selecto.with_tenant(%{tenant_id: "acme", tenant_field: "account_id"})

      assert {:error, _} = Selecto.Tenant.tenant_boundary(other)
      assert {:error, _} = Selecto.Tenant.tenant_boundary(other, access: :write)
    end

    test "require_read_boundary ANDs a trusted tenant into the read" do
      attached =
        tenant_field_domain([])
        |> selecto()
        |> Selecto.with_tenant(%{tenant_id: "acme", tenant_field: "tenant_id"})
        |> Selecto.select(["id"])

      assert {:ok, bounded} = Selecto.Tenant.require_read_boundary(attached)
      assert {"tenant_id", "acme"} in Selecto.required_filters(bounded)
      {_sql, params} = Selecto.to_sql(bounded)
      assert "acme" in params

      conjunct = tenant_field_domain([{"tenant_id", "acme"}]) |> selecto()
      assert {:ok, ^conjunct} = Selecto.Tenant.require_read_boundary(conjunct)
    end

    test "direct reads stay permissive" do
      query =
        tenant_field_domain([])
        |> selecto()
        |> Selecto.select(["id"])
        |> Map.put(:adapter, Adapter)
        |> Map.put(:connection, :ok)

      assert {:ok, {[[1]], ["id"], _aliases}} = Selecto.execute(query, analyze_complexity: false)
    end
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
