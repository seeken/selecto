defmodule Selecto.CoDomainTenantBoundaryTest do
  use ExUnit.Case, async: true

  defmodule LookupAdapter do
    @moduledoc false
    # The PostgreSQL test adapter with governed lookup and a recording
    # executor, so lookups run without a database.
    @base SelectoDBPostgreSQL.Adapter

    def capability(:text_search) do
      Map.put(@base.capability(:text_search), :governed_lookup?, true)
    end

    def capability(feature), do: @base.capability(feature)

    def execute({pid, rows}, sql, params, _opts) do
      send(pid, {:executed, IO.iodata_to_binary(sql), params})
      {:ok, %{rows: rows, columns: ["id", "name"]}}
    end

    def connect(connection), do: {:ok, connection}

    for {name, arity} <- @base.__info__(:functions),
        name not in [:capability, :execute, :connect] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: @base.unquote(name)(unquote_splicing(args))
    end
  end

  defp target_domain(required_filters) do
    %{
      name: "Clients",
      source: %{
        source_table: "clients",
        primary_key: :id,
        tenant_field: :tenant_id,
        fields: [:id, :name, :tenant_id],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          tenant_id: %{type: :integer}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      required_filters: required_filters,
      query_library: %{projections: %{identity: %{fields: [:id, :name]}}}
    }
  end

  defp source_domain do
    target_domain([])
    |> Map.delete(:required_filters)
    |> Map.put(:co_domains, %{
      clients: %{
        domain: :client,
        projection: :identity,
        search: %{fields: [:name], mode: :plain},
        result: %{value_field: :id, label_field: :name}
      }
    })
  end

  defp target(required_filters, rows \\ [[1, "Ada"]]) do
    Selecto.configure(target_domain(required_filters), {self(), rows},
      adapter: LookupAdapter,
      validate: false
    )
  end

  defp lookup(target, opts \\ []),
    do: Selecto.CoDomain.lookup(source_domain(), target, :clients, "Ad", opts)

  test "a co-domain lookup with a non-tenant host scope fails with missing_tenant_scope" do
    for {required, scope} <- [
          {[], nil},
          {[], {"id", {:gte, 1}}},
          {[{"id", 4}], nil},
          {[{:or, [{"tenant_id", 7}, {"id", 4}]}], nil},
          {[], {:not, {"tenant_id", 8}}},
          {[], {:or, [{"tenant_id", 7}, {"id", 4}]}}
        ] do
      opts = if scope, do: [scope: scope], else: []

      assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
               lookup(target(required), opts)

      assert_raise RuntimeError, ~r/^missing_tenant_scope/, fn ->
        Selecto.CoDomain.plan(source_domain(), target(required), :clients, "Ad", opts)
      end

      refute_received {:executed, _, _}
    end

    # A tokenless lookup never executes, but still requires the boundary.
    assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
             Selecto.CoDomain.lookup(source_domain(), target([]), :clients, "---")
  end

  test "a tenant conjunct in the required filters or the host scope bounds the lookup" do
    for {required, scope} <- [
          {[{"tenant_id", 7}], nil},
          {[{:and, [{"tenant_id", {:in, [7]}}, {"id", {:gte, 1}}]}], nil},
          {[{"id", {:gte, 1}}], {"tenant_id", 7}},
          {[], [{"id", {:gte, 1}}, {"tenant_id", {:in, [7, 8]}}]}
        ] do
      opts = if scope, do: [scope: scope], else: []

      assert {:ok, %{results: [%{value: "1", label: "Ada"}]}} = lookup(target(required), opts)
      assert_received {:executed, sql, params}
      assert sql =~ "tenant_id"
      assert 7 in List.flatten(params)
    end
  end

  test "a trusted tenant bounds the lookup and is ANDed into it" do
    attached = Selecto.with_tenant(target([]), %{tenant_id: 7, tenant_field: "tenant_id"})

    assert {:ok, %{results: [_]}} = lookup(attached)
    assert_received {:executed, sql, params}
    assert sql =~ "tenant_id"
    assert 7 in List.flatten(params)
  end
end
