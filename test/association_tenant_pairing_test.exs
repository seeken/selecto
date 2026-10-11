defmodule Selecto.AssociationTenantPairingTest do
  # Lesson 41: authored scope keys never replace tenant pairing. Lesson 42: a
  # trusted tenant on a shared root is a typed refusal.
  use ExUnit.Case, async: true

  alias SelectoDBSQLite.Adapter

  @tenant %{tenant_id: 7, tenant_field: "tenant_id"}

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(db) end)

    for statement <- [
          "CREATE TABLE people (id INTEGER PRIMARY KEY, tenant_id INTEGER, region_id INTEGER, account_id INTEGER, site_id INTEGER)",
          "CREATE TABLE accounts (id INTEGER, tenant_id INTEGER, region_id INTEGER, name TEXT, person_id INTEGER, site_id INTEGER)",
          "CREATE TABLE memberships (person_id INTEGER, account_id INTEGER, region_id INTEGER)",
          "INSERT INTO people VALUES (1, 7, 5, 50, 3)",
          "INSERT INTO accounts VALUES (50, 7, 5, 'own', 1, 3), (50, 8, 5, 'tenant-8 secret', 1, 3)",
          "INSERT INTO memberships VALUES (1, 50, 5)",
          "CREATE TABLE products (id INTEGER PRIMARY KEY, order_id INTEGER, name TEXT)",
          "CREATE TABLE orders (id INTEGER, tenant_id INTEGER, product_id INTEGER, total INTEGER)",
          "INSERT INTO products VALUES (1, 201, 'widget')",
          "INSERT INTO orders VALUES (101, 7, 1, 10), (201, 8, 1, 9999)"
        ],
        do: :ok = Exqlite.Sqlite3.execute(db, statement)

    %{db: db}
  end

  describe "lesson 41: tenant pairing with authored scope keys" do
    test "a direct association with authored non-tenant keys pairs the tenants", %{db: db} do
      association = %{
        queryable: :account,
        owner_key: :account_id,
        related_key: :id,
        cardinality: :one,
        source_scope_key: :region_id,
        target_scope_key: :region_id
      }

      query = db |> scoped(people_domain(association)) |> Selecto.select(["id", "account.name"])
      {sql, _params} = Selecto.to_sql(query)

      assert sql =~ "selecto_root.region_id = account.region_id"
      assert sql =~ "selecto_root.tenant_id = account.tenant_id"
      assert rows(query) == [[1, "own"]]

      oracle = Selecto.filter(query, [{"account.name", "tenant-8 secret"}])
      assert rows(oracle) == []
    end

    test "a through association with authored region keys pairs the tenants", %{db: db} do
      through = %{
        table: "memberships",
        owner_key: :person_id,
        related_key: :account_id,
        source_scope_key: :region_id,
        through_scope_key: :region_id,
        target_scope_key: :region_id
      }

      query =
        db |> scoped(people_domain(through_association(through))) |> select_account_name()

      {sql, _params} = Selecto.to_sql(query)
      assert sql =~ ~s(account."tenant_id" = selecto_root."tenant_id")
      assert rows(query) == [[1, "own"]]
    end

    test "a through association without authored keys pairs the tenants", %{db: db} do
      through = %{table: "memberships", owner_key: :person_id, related_key: :account_id}

      query =
        db |> scoped(people_domain(through_association(through))) |> select_account_name()

      assert rows(query) == [[1, "own"]]
    end

    test "a collection over authored non-tenant keys pairs the tenants", %{db: db} do
      association = %{
        queryable: :account,
        owner_key: :id,
        related_key: :person_id,
        cardinality: :many,
        source_scope_key: :region_id,
        target_scope_key: :region_id
      }

      query =
        db
        |> scoped(Map.put(people_domain(association), :joins, %{}))
        |> Selecto.select(["id"])
        |> Selecto.subselect([
          %{
            fields: ["name"],
            target_schema: :account,
            format: :count,
            alias: "accounts",
            join_path: [:account]
          }
        ])

      {sql, _params} = Selecto.to_sql(query)
      assert sql =~ ~s(sub_account."tenant_id" = selecto_root."tenant_id")
      assert rows(query) == [[1, 1]]
    end

    test "a tenant field that is not a declared field cannot be paired" do
      domain =
        people_domain(%{
          queryable: :account,
          owner_key: :account_id,
          related_key: :id,
          cardinality: :one,
          source_scope_key: :region_id,
          target_scope_key: :region_id
        })
        |> update_in([:schemas, :account, :fields], &List.delete(&1, :tenant_id))

      assert_raise ArgumentError, ~r/invalid_domain: .*target tenant field :tenant_id/, fn ->
        Selecto.configure(domain, :mock_connection, validate: false)
      end
    end

    test "a two-column root pairs tenant columns by name" do
      association = %{
        queryable: :account,
        owner_key: :account_id,
        related_key: :id,
        cardinality: :one,
        source_scope_key: :region_id,
        target_scope_key: :region_id
      }

      domain =
        association
        |> people_domain()
        |> Map.put(:writes, %{scope: %{tenant: %{field: :site_id, required: true}}})
        |> put_in([:schemas, :account, :tenant_field], :site_id)

      {sql, _params} =
        domain
        |> Selecto.configure(:mock_connection, validate: false)
        |> Selecto.select(["account.name"])
        |> Selecto.to_sql()

      assert sql =~ "selecto_root.site_id = account.site_id"
      refute sql =~ "selecto_root.tenant_id = account.site_id"

      unmatched = put_in(domain, [:schemas, :account, :tenant_field], :region_id)

      assert_raise ArgumentError,
                   ~r/invalid_domain: .*matches none of the root tenant columns/,
                   fn ->
                     Selecto.configure(unmatched, :mock_connection, validate: false)
                   end
    end

    test "an advanced join builder that cannot apply the tenant pair is refused" do
      domain =
        people_domain(%{queryable: :account, owner_key: :account_id, related_key: :id})
        |> Map.put(:joins, %{account: %{type: :star_dimension, display_field: :name}})

      assert_raise ArgumentError, ~r/invalid_domain: join :account .* tenant pair/, fn ->
        domain
        |> Selecto.configure(:mock_connection, validate: false)
        |> Selecto.select(["account.name"])
        |> Selecto.to_sql()
      end
    end
  end

  describe "lesson 42: trusted tenant on a shared root" do
    test "an engine read is a typed missing_tenant_scope refusal", %{db: db} do
      base = Selecto.configure(products_domain(), db, adapter: Adapter)
      scoped = Selecto.with_tenant(base, @tenant)

      assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
               Selecto.Tenant.tenant_boundary(scoped)

      for query <- [scoped, Selecto.apply_tenant_scope(scoped)] do
        assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
                 query |> Selecto.select(["id", "orders.total"]) |> Selecto.execute()
      end

      assert {:ok, :not_required} = Selecto.Tenant.tenant_boundary(base)
    end

    test "a retarget from a shared root under a trusted tenant is refused", %{db: db} do
      scoped = products_domain() |> Selecto.configure(db, adapter: Adapter) |> with_tenant()

      for target <- [:orders, "lines.orders"] do
        error = assert_raise Selecto.Retarget.Error, fn -> Selecto.retarget(scoped, target) end
        assert error.code == :missing_tenant_scope
      end
    end
  end

  defp scoped(db, domain) do
    domain
    |> Selecto.configure(db, adapter: Adapter)
    |> with_tenant()
    |> Selecto.Tenant.apply_tenant_scope()
  end

  defp with_tenant(selecto), do: Selecto.with_tenant(selecto, @tenant)

  defp select_account_name(query),
    do: query |> Selecto.select(["id", "account.name"]) |> Selecto.order_by(["account.name"])

  defp rows(query) do
    assert {:ok, {rows, _columns, _aliases}} = Selecto.execute(query)
    rows
  end

  defp through_association(through) do
    %{queryable: :account, owner_key: :id, related_key: :id, cardinality: :many, through: through}
  end

  defp people_domain(association) do
    %{
      name: "L41",
      source:
        relation("people", [:id, :tenant_id, :region_id, :account_id, :site_id], :tenant_id, %{
          account: Map.put(association, :field, :account)
        }),
      schemas: %{
        account:
          relation(
            "accounts",
            [:id, :tenant_id, :region_id, :name, :person_id, :site_id],
            :tenant_id,
            %{}
          )
      },
      joins: %{account: %{type: :left}}
    }
  end

  # products (shared) -> orders (tenant), and products -> lines (shared) ->
  # orders for a multi-hop retarget.
  defp products_domain do
    orders = %{
      queryable: :orders,
      field: :orders,
      owner_key: :id,
      related_key: :product_id,
      cardinality: :many
    }

    %{
      name: "L42",
      source:
        relation("products", [:id, :order_id, :name], nil, %{
          orders: orders,
          lines: %{
            queryable: :lines,
            field: :lines,
            owner_key: :id,
            related_key: :id,
            cardinality: :many
          }
        }),
      schemas: %{
        orders: relation("orders", [:id, :tenant_id, :product_id, :total], :tenant_id, %{}),
        lines: relation("products", [:id, :order_id, :name], nil, %{orders: orders})
      },
      joins: %{orders: %{type: :left}, lines: %{type: :left, joins: %{orders: %{type: :left}}}}
    }
  end

  defp relation(table, fields, tenant_field, associations) do
    relation = %{
      source_table: table,
      primary_key: :id,
      fields: fields,
      redact_fields: [],
      columns: Map.new(fields, &{&1, %{type: if(&1 == :name, do: :string, else: :integer)}}),
      associations: associations
    }

    if tenant_field, do: Map.put(relation, :tenant_field, tenant_field), else: relation
  end
end
