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

  test "a rollup without an empty-input total gains it as a UNION ALL branch" do
    query =
      domain(:string)
      |> Selecto.configure(Selecto.Runtime.Context.new(ExactAdapter, :compile_only),
        validate: false
      )
      |> Selecto.select(["name", {:count, "*"}, {:grouping, ["name"]}])
      |> Selecto.group_by([{:rollup, ["name"]}])
      |> Selecto.order_by([{"name", :desc}])
      |> Selecto.limit(2)

    {sql, params} = Selecto.to_sql(query)
    sql = String.replace(sql, ~r/\s+/, " ")

    assert sql =~ "UNION ALL SELECT"

    assert sql =~
             "select NULL AS selecto_projection_1, count(*) AS selecto_projection_2, 1 AS selecto_projection_3, count(*) AS selecto_projection_4"

    assert sql =~ "WHERE `selecto_projection_4` = 0) AS `selecto_rollup`"

    assert sql =~
             "ORDER BY (`selecto_projection_1` IS NULL) DESC, `selecto_projection_1` DESC LIMIT ?"

    assert params == [2]
  end

  test "through scope pairs compare exactly when either column may hold text" do
    through_domain = fn target_type ->
      %{
        name: "Thru",
        source: %{
          relation(
            "orders",
            [id: :integer, tenant_id: :integer, name: :string],
            %{
              targets: %{
                queryable: :target,
                field: :targets,
                owner_key: :id,
                related_key: :id,
                cardinality: :many,
                through: %{
                  table: "bridges",
                  owner_key: :order_id,
                  related_key: :target_id,
                  source_scope_key: :tenant_id,
                  through_scope_key: :scope_code,
                  target_scope_key: :org_code
                }
              }
            },
            :tenant_id
          )
          | fields: [:id, :tenant_id, :name]
        },
        schemas: %{
          target:
            relation("targets", [id: :integer, org_code: target_type, name: :string], %{}, nil),
          bridge:
            relation(
              "bridges",
              [id: :integer, order_id: :integer, target_id: :integer, scope_code: :integer],
              %{},
              nil
            )
        },
        joins: %{targets: %{type: :left, name: "targets"}}
      }
    end

    compile = fn target_type ->
      through_domain.(target_type)
      |> Selecto.configure(Selecto.Runtime.Context.new(ExactAdapter, :compile_only),
        validate: false
      )
      |> Selecto.with_tenant(7)
      |> Selecto.select(["id", "targets.name"])
      |> Selecto.to_sql()
      |> elem(0)
      |> String.replace(~r/\s+/, " ")
    end

    # A VARCHAR target scope beside the INT root tenant: numeric compare
    # would admit '07' and '7e0', so the pair compares bytes.
    text = compile.(:string)

    assert text =~
             "(targets.`org_code` = selecto_root.`tenant_id` AND " <>
               "CAST(CONVERT(targets.`org_code` USING utf8mb4) AS BINARY) = " <>
               "CAST(CONVERT(selecto_root.`tenant_id` USING utf8mb4) AS BINARY))"

    # Integer-declared on both sides stays plain.
    refute compile.(:integer) =~ "BINARY"
  end
end
