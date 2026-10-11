defmodule Selecto.AssociationTenantPairingTest do
  # Lesson 41: authored scope keys never replace tenant pairing, two-column
  # domains pair by name at every hop, and a shared hop carries the root's
  # admitted tenants. Lesson 42: a trusted tenant on a shared root is a typed
  # refusal. Lesson 43: a trusted tenant binds the root of every read.
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
          "INSERT INTO orders VALUES (101, 7, 1, 10), (201, 8, 1, 9999)",
          "INSERT INTO people VALUES (2, 8, 5, 50, 3)",
          "CREATE TABLE regions (id INTEGER PRIMARY KEY, name TEXT)",
          "INSERT INTO regions VALUES (5, 'north')",
          "CREATE TABLE site_orders (id INTEGER, tenant_id INTEGER, site_id INTEGER, person_id INTEGER, total INTEGER)",
          "INSERT INTO site_orders VALUES (100, 7, 3, 1, 10), (101, 8, 3, 1, 99)",
          "CREATE TABLE site_lines (id INTEGER PRIMARY KEY, site_id INTEGER, order_id INTEGER, name TEXT)",
          "INSERT INTO site_lines VALUES (1000, 3, 100, 'own-site line'), (1001, 4, 100, 'other-site line'), (1002, 7, 100, 'site-7 line')",
          "CREATE TABLE stock (id INTEGER PRIMARY KEY, tenant_id INTEGER, name TEXT)",
          "INSERT INTO stock VALUES (1, 7, 'widget')",
          "CREATE TABLE region_lines (id INTEGER PRIMARY KEY, site_id INTEGER, region_id INTEGER, code TEXT)",
          "INSERT INTO region_lines VALUES (1, 3, 5, 'own-site'), (2, 4, 5, 'other-site')"
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
                   ~r/invalid_domain: .*cannot be paired by name/,
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

  describe "lesson 41b: shared hops and every-hop pairing" do
    test "a tenant relation reached across a shared hop carries the scoped root's tenants",
         %{db: db} do
      base = Selecto.configure(regional_domain(), db, adapter: Adapter)

      scoped =
        base
        |> with_tenant()
        |> Selecto.select(["id", "accounts.name"])
        |> Selecto.order_by(["accounts.name"])

      {sql, _params} = Selecto.to_sql(scoped)
      assert sql =~ ~s(accounts."tenant_id" = selecto_root."tenant_id")
      assert rows(scoped) == [[1, "own"]]

      # An unscoped trusted read keeps the authored visibility.
      unscoped =
        base
        |> Selecto.select(["id", "accounts.name"])
        |> Selecto.order_by(["id", "accounts.name"])

      assert rows(unscoped) == [
               [1, "own"],
               [1, "tenant-8 secret"],
               [2, "own"],
               [2, "tenant-8 secret"]
             ]

      collection =
        base
        |> with_tenant()
        |> Selecto.select(["id"])
        |> Selecto.subselect([
          %{
            fields: ["name"],
            target_schema: :accounts,
            format: :count,
            alias: "accounts",
            join_path: [:region, :accounts]
          }
        ])

      {sql, _params} = Selecto.to_sql(collection)
      assert sql =~ ~s(sub_accounts."tenant_id" = selecto_root."tenant_id")
      assert rows(collection) == [[1, 1]]
    end

    test "a retarget to a shared relation carries the admitted tenants onto later joins",
         %{db: db} do
      retargeted =
        regional_domain()
        |> Selecto.configure(db, adapter: Adapter)
        |> with_tenant()
        |> Selecto.retarget(:region)
        |> Selecto.select(["id", "accounts.name"])

      {sql, params} = Selecto.to_sql(retargeted)
      assert sql =~ ~s(accounts."tenant_id" IN ()
      assert 7 in params
      assert rows(retargeted) == [[5, "own"]]
    end

    test "a two-column domain pairs by name at every hop and returns the caller's own site rows",
         %{db: db} do
      query =
        site_domain()
        |> Selecto.configure(db, adapter: Adapter, validate: false)
        |> with_tenant()
        |> Selecto.select(["id", "orders.total", "lines.name"])
        |> Selecto.order_by(["lines.name"])

      {sql, _params} = Selecto.to_sql(query)
      assert sql =~ "orders.site_id = lines.site_id"
      refute sql =~ "orders.tenant_id = lines.site_id"
      assert rows(query) == [[1, 10, "own-site line"]]

      retargeted =
        site_domain()
        |> Selecto.configure(db, adapter: Adapter, validate: false)
        |> with_tenant()
        |> Selecto.retarget("orders.lines")
        |> Selecto.select(["id", "name"])

      assert rows(retargeted) == [[1000, "own-site line"]]

      missing_site =
        update_in(site_domain(), [:schemas, :orders, :fields], &List.delete(&1, :site_id))

      assert_raise ArgumentError, ~r/invalid_domain: association :lines .*by name/, fn ->
        Selecto.configure(missing_site, db, adapter: Adapter, validate: false)
      end
    end
  end

  describe "lesson 43: a trusted tenant binds the root of every read" do
    test "an unapplied engine tenant still limits SDK reads", %{db: db} do
      base = Selecto.configure(regional_domain(), db, adapter: Adapter)
      query = base |> with_tenant() |> Selecto.select(["id"])

      assert rows(query) == [[1]]
      assert rows(Selecto.select(base, ["id"]) |> Selecto.order_by(["id"])) == [[1], [2]]

      mismatched = Selecto.Tenant.require_tenant_filter(query, "tenant_id", 8)

      assert {:error, %Selecto.Error{details: %{code: :tenant_scope_mismatch}}} =
               Selecto.execute(mismatched)
    end
  end

  describe "review follow-ups" do
    test "a shared root that merely has a tenant_id column is refused under an engine tenant",
         %{db: db} do
      base = stock_domain() |> Selecto.configure(db, adapter: Adapter) |> with_tenant()

      assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
               Selecto.Tenant.tenant_boundary(base)

      for query <- [base, Selecto.apply_tenant_scope(base)] do
        assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
                 query |> Selecto.select(["id", "orders.total"]) |> Selecto.execute()
      end

      error = assert_raise Selecto.Retarget.Error, fn -> Selecto.retarget(base, :orders) end
      assert error.code == :missing_tenant_scope
    end

    test "a tenant context naming another column than the declared tenant_field is refused",
         %{db: db} do
      query =
        site_domain()
        |> Selecto.configure(db, adapter: Adapter, validate: false)
        |> Selecto.with_tenant(%{tenant_id: 3, tenant_field: "site_id"})
        |> Selecto.select(["id"])

      assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
               Selecto.execute(query)
    end

    test "every positive tenant conjunct form scopes the root and carries across shared hops",
         %{db: db} do
      for required <- [
            {"tenant_id", {:eq, 7}},
            {"tenant_id", {:=, 7}},
            {"tenant_id", {"=", 7}},
            {:and, [{"tenant_id", {:eq, 7}}]}
          ] do
        base =
          regional_domain()
          |> Selecto.configure(db, adapter: Adapter)
          |> Selecto.Tenant.require_tenant_filter(required)

        assert rows(Selecto.select(base, ["id", "accounts.name"])) == [[1, "own"]]

        retargeted = base |> Selecto.retarget(:region) |> Selecto.select(["id", "accounts.name"])
        assert rows(retargeted) == [[5, "own"]]
      end
    end

    test "a two-column root scoped only by its site column pairs shared hops by name",
         %{db: db} do
      base =
        site_regional_domain()
        |> Selecto.configure(db, adapter: Adapter, validate: false)
        |> Selecto.Tenant.require_tenant_filter("site_id", 3)

      # Both site-3 people (tenants 7 and 8) are admitted by the site scope;
      # the other site's line is not.
      assert rows(base |> Selecto.select(["id", "lines.code"]) |> Selecto.order_by(["id"])) ==
               [[1, "own-site"], [2, "own-site"]]

      retargeted = base |> Selecto.retarget(:region) |> Selecto.select(["id", "lines.code"])
      assert rows(retargeted) == [[5, "own-site"]]

      # An engine tenant binds tenant_id; site rows come back by name (41c).
      engine =
        site_regional_domain()
        |> Selecto.configure(db, adapter: Adapter, validate: false)
        |> with_tenant()

      assert rows(Selecto.select(engine, ["id", "lines.code"])) == [[1, "own-site"]]

      retargeted = engine |> Selecto.retarget(:region) |> Selecto.select(["id", "lines.code"])
      assert rows(retargeted) == [[5, "own-site"]]
    end

    test "a join_through many-to-many pairs the tenants in joins and collections", %{db: db} do
      base = m2m_domain() |> Selecto.configure(db, adapter: Adapter) |> with_tenant()

      query = base |> Selecto.select(["id", "account.name"]) |> Selecto.order_by(["account.name"])
      assert rows(query) == [[1, "own"]]

      collection =
        base
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

      {sql, _params} = Selecto.to_sql(collection)
      assert sql =~ ~s(EXISTS (SELECT 1 FROM "memberships")
      assert rows(collection) == [[1, 1]]
    end

    test "an engine tenant intersects required and host tenant conjuncts", %{db: db} do
      base = regional_domain() |> Selecto.configure(db, adapter: Adapter) |> with_tenant()

      intersected = Selecto.Tenant.require_tenant_filter(base, {"tenant_id", {:in, [7, 8]}})
      assert rows(Selecto.select(intersected, ["id"])) == [[1]]

      assert {:error, %Selecto.Error{details: %{code: :tenant_scope_mismatch}}} =
               base
               |> Selecto.Tenant.require_tenant_filter("tenant_id", 8)
               |> Selecto.select(["id"])
               |> Selecto.execute()

      # An ordinary filter on another tenant is ANDed with the binding.
      assert rows(base |> Selecto.filter({"tenant_id", 8}) |> Selecto.select(["id"])) == []

      assert {"tenant_id", 7} in Selecto.query_filters(base)
    end
  end

  describe "re-review follow-ups" do
    test "a host-applied tenant filter scopes shared hops like a required one (N1)", %{db: db} do
      for host <- [{"tenant_id", 7}, {"tenant_id", {:in, [7, 9]}}] do
        base =
          regional_domain() |> Selecto.configure(db, adapter: Adapter) |> Selecto.filter(host)

        assert rows(Selecto.select(base, ["id", "accounts.name"])) == [[1, "own"]]

        retargeted = base |> Selecto.retarget(:region) |> Selecto.select(["id", "accounts.name"])
        assert rows(retargeted) == [[5, "own"]]
      end
    end

    test "a tenant predicate without a positive conjunct cannot cross a shared hop (N4)",
         %{db: db} do
      for required <- [
            {:or, [{"tenant_id", 7}, {"tenant_id", 8}]},
            {:not, {"tenant_id", 9}},
            {"tenant_id", {:<, 9}}
          ] do
        query =
          regional_domain()
          |> Selecto.configure(db, adapter: Adapter)
          |> Selecto.Tenant.require_tenant_filter(required)
          |> Selecto.select(["id", "accounts.name"])

        error = assert_raise Selecto.PolicyViolation, fn -> Selecto.execute(query) end
        assert error.type == :missing_tenant_scope
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

  # people (tenant) -> region (shared) -> accounts (tenant).
  defp regional_domain do
    %{
      name: "L41b",
      source:
        relation("people", [:id, :tenant_id, :region_id, :account_id, :site_id], :tenant_id, %{
          region: %{
            queryable: :regions,
            field: :region,
            owner_key: :region_id,
            related_key: :id,
            cardinality: :one
          }
        }),
      schemas: %{
        regions:
          relation("regions", [:id, :name], nil, %{
            accounts: %{
              queryable: :accounts,
              field: :accounts,
              owner_key: :id,
              related_key: :region_id,
              cardinality: :many
            }
          }),
        accounts:
          relation(
            "accounts",
            [:id, :tenant_id, :region_id, :name, :person_id, :site_id],
            :tenant_id,
            %{}
          )
      },
      joins: %{region: %{type: :left, joins: %{accounts: %{type: :left}}}}
    }
  end

  # A two-column root: tenant_id reads, site_id writes. people -> orders
  # (tenant_id) -> lines (site_id).
  defp site_domain do
    %{
      name: "L41c",
      source:
        relation("people", [:id, :tenant_id, :region_id, :account_id, :site_id], :tenant_id, %{
          orders: %{
            queryable: :orders,
            field: :orders,
            owner_key: :id,
            related_key: :person_id,
            cardinality: :many
          }
        }),
      schemas: %{
        orders:
          relation("site_orders", [:id, :tenant_id, :site_id, :person_id, :total], :tenant_id, %{
            lines: %{
              queryable: :lines,
              field: :lines,
              owner_key: :id,
              related_key: :order_id,
              cardinality: :many
            }
          }),
        lines: relation("site_lines", [:id, :site_id, :order_id, :name], :site_id, %{})
      },
      joins: %{orders: %{type: :left, joins: %{lines: %{type: :left}}}},
      writes: %{scope: %{tenant: %{field: :site_id, required: true}}}
    }
  end

  # stock (shared, with a tenant_id column it does not declare) -> orders.
  defp stock_domain do
    %{
      name: "L42B",
      source:
        relation("stock", [:id, :tenant_id, :name], nil, %{
          orders: %{
            queryable: :orders,
            field: :orders,
            owner_key: :id,
            related_key: :product_id,
            cardinality: :many
          }
        }),
      schemas: %{
        orders: relation("orders", [:id, :tenant_id, :product_id, :total], :tenant_id, %{})
      },
      joins: %{orders: %{type: :left}}
    }
  end

  # A two-column root: people (tenant_id, writes site_id) -> region (shared)
  # -> lines (site_id).
  defp site_regional_domain do
    %{
      name: "L41E",
      source:
        relation("people", [:id, :tenant_id, :region_id, :account_id, :site_id], :tenant_id, %{
          region: %{
            queryable: :regions,
            field: :region,
            owner_key: :region_id,
            related_key: :id,
            cardinality: :one
          }
        }),
      schemas: %{
        regions:
          relation("regions", [:id, :name], nil, %{
            lines: %{
              queryable: :lines,
              field: :lines,
              owner_key: :id,
              related_key: :region_id,
              cardinality: :many
            }
          }),
        lines: relation("region_lines", [:id, :site_id, :region_id, :code], :site_id, %{})
      },
      joins: %{region: %{type: :left, joins: %{lines: %{type: :left}}}},
      writes: %{scope: %{tenant: %{field: :site_id, required: true}}}
    }
  end

  # people -> accounts through the memberships join table (Ecto style).
  defp m2m_domain do
    %{
      name: "M2M",
      source:
        relation("people", [:id, :tenant_id, :region_id, :account_id, :site_id], :tenant_id, %{
          account: %{
            queryable: :account,
            field: :account,
            owner_key: :id,
            related_key: :id,
            cardinality: :many,
            join_through: "memberships",
            join_keys: [person_id: :id, account_id: :id]
          }
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
