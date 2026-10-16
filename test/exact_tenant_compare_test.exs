defmodule Selecto.ExactTenantCompareTest do
  # Adapters declaring :exact_tenant_compare (MySQL, MariaDB) compare tenant
  # and site columns by their utf8mb4 bytes; every other adapter compiles the
  # plain comparison, byte-identical to before.
  use ExUnit.Case, async: true

  defmodule ExactAdapter do
    @moduledoc false
    def name, do: :exact_test
    def supports?(feature), do: feature in [:exact_tenant_compare, :rollup_without_empty_total]
    def quote_identifier(identifier), do: "`#{String.replace(identifier, "`", "``")}`"
    def placeholder(_index), do: "?"
    def rollup_sql(grouped_clauses), do: [grouped_clauses, " WITH ROLLUP"]
  end

  defp relation(table, columns, associations, tenant_field) do
    %{
      source_table: table,
      primary_key: :id,
      fields: Keyword.keys(columns),
      redact_fields: [],
      columns: Map.new(columns, fn {name, type} -> {name, %{type: type}} end),
      associations: associations,
      tenant_field: tenant_field
    }
  end

  defp domain(tenant_type) do
    %{
      name: "Orders",
      source:
        relation(
          "orders",
          [id: :integer, tenant_id: tenant_type, customer_id: :integer, name: :string],
          %{
            customer: %{
              queryable: :customers,
              field: :customer,
              owner_key: :customer_id,
              related_key: :id,
              cardinality: :one
            }
          },
          :tenant_id
        ),
      schemas: %{
        customers:
          relation(
            "customers",
            [id: :integer, tenant_id: tenant_type, name: :string],
            %{},
            :tenant_id
          )
      },
      joins: %{customer: %{type: :left, name: "customer"}}
    }
  end

  defp sql(adapter, tenant_type, tenant) do
    domain(tenant_type)
    |> Selecto.configure(Selecto.Runtime.Context.new(adapter, :compile_only), validate: false)
    |> Selecto.with_tenant(tenant)
    |> Selecto.select(["id", "customer.name"])
    |> Selecto.filter([{"tenant_id", {:in, [tenant, tenant]}}, {"name", "x"}])
    |> Selecto.to_sql()
  end

  test "text tenant columns compare by utf8mb4 bytes on an exact-compare adapter" do
    {sql, params} = sql(ExactAdapter, :string, "t1")
    sql = String.replace(sql, ~r/\s+/, " ")

    assert sql =~
             "(selecto_root.tenant_id = customer.tenant_id AND " <>
               "CAST(CONVERT(selecto_root.tenant_id USING utf8mb4) AS BINARY) = " <>
               "CAST(CONVERT(customer.tenant_id USING utf8mb4) AS BINARY))"

    assert sql =~
             "(selecto_root.tenant_id = ? AND " <>
               "CAST(CONVERT(selecto_root.tenant_id USING utf8mb4) AS BINARY) = CAST(? AS BINARY))"

    assert sql =~
             "(selecto_root.tenant_id IN (?, ?) AND " <>
               "CAST(CONVERT(selecto_root.tenant_id USING utf8mb4) AS BINARY) IN " <>
               "(CAST(? AS BINARY), CAST(? AS BINARY)))"

    # A non-tenant column keeps the plain comparison.
    assert sql =~ "selecto_root.name = ?"
    assert params == ["t1", "t1", "t1", "t1", "t1", "t1", "x"]
  end

  test "integer tenant columns and other adapters compile exactly as before" do
    {integer_sql, _params} = sql(ExactAdapter, :integer, 7)
    refute integer_sql =~ "BINARY"

    {sqlite_sql, sqlite_params} = sql(SelectoDBSQLite.Adapter, :string, "t1")
    refute sqlite_sql =~ "BINARY"
    assert sqlite_params == ["t1", "t1", "t1", "x"]
  end
end
