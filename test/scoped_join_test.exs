defmodule Selecto.ScopedJoinTest do
  use ExUnit.Case, async: true

  test "adds the association tenant scope to a direct join" do
    query =
      scoped_domain()
      |> Selecto.configure(:mock_connection)
      |> Selecto.select(["id", "customer.company_name"])

    {sql, []} = Selecto.to_sql(query)

    assert sql =~
             "customer.id = selecto_root.customer_id and selecto_root.tenant_id = customer.tenant_id"
  end

  test "adds the association tenant scope to a correlated collection subselect" do
    query =
      scoped_domain()
      |> Selecto.configure(:mock_connection)
      |> Selecto.select(["id"])
      |> Selecto.subselect([
        %{
          fields: ["id", "company_name"],
          target_schema: :customers,
          format: :json_agg,
          alias: "customers",
          join_path: [:customer]
        }
      ])

    {sql, []} = Selecto.to_sql(query)

    assert sql =~
             ~s(sub_customers."id" = selecto_root."customer_id" AND sub_customers."tenant_id" = selecto_root."tenant_id")
  end

  test "rejects an association with only one scope key even when validation is disabled" do
    domain =
      update_in(
        scoped_domain(),
        [:source, :associations, :customer],
        &Map.delete(&1, :target_scope_key)
      )

    assert_raise ArgumentError, ~r/requires both :source_scope_key and :target_scope_key/, fn ->
      Selecto.configure(domain, :mock_connection, validate: false)
    end

    assert {:error, errors} = Selecto.DomainValidator.validate_domain(domain)
    assert {:association_scope_incomplete, {:source, :customer}} in errors
  end

  test "rejects an association scope key that is not a declared field" do
    domain =
      put_in(
        scoped_domain(),
        [:source, :associations, :customer, :target_scope_key],
        :missing_tenant
      )

    assert_raise ArgumentError, ~r/target scope field :missing_tenant is not declared/, fn ->
      Selecto.configure(domain, :mock_connection, validate: false)
    end

    assert {:error, errors} = Selecto.DomainValidator.validate_domain(domain)

    assert {:association_scope_field_missing, {:source, :customer, :target, :missing_tenant}} in errors
  end

  defp scoped_domain do
    %{
      name: "Orders",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :tenant_id, :customer_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          customer_id: %{type: :integer}
        },
        associations: %{
          customer: %{
            queryable: :customers,
            field: :customer,
            owner_key: :customer_id,
            related_key: :id,
            source_scope_key: :tenant_id,
            target_scope_key: :tenant_id
          }
        }
      },
      schemas: %{
        customers: %{
          source_table: "customers",
          primary_key: :id,
          fields: [:id, :tenant_id, :company_name],
          redact_fields: [],
          columns: %{
            id: %{type: :integer},
            tenant_id: %{type: :integer},
            company_name: %{type: :string}
          },
          associations: %{}
        }
      },
      joins: %{customer: %{type: :left}},
      filters: %{}
    }
  end
end
