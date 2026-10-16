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

    # The caller's own filter on a non-tenant column keeps the plain form.
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

  describe "host-installed predicates on a domain without tenant_field" do
    defp host_domain(required \\ nil) do
      domain = %{
        name: "HS",
        source:
          relation("hs", [id: :integer, org_key: :string, name: :string], %{}, nil)
          |> Map.delete(:tenant_field),
        schemas: %{},
        joins: %{}
      }

      if required, do: Map.put(domain, :required_filters, required), else: domain
    end

    defp host_sql(domain, adapter, fun) do
      domain
      |> Selecto.configure(Selecto.Runtime.Context.new(adapter, :compile_only), validate: false)
      |> fun.()
      |> Selecto.select(["id"])
      |> Selecto.to_sql()
      |> elem(0)
    end

    test "every host mechanism compares the scope column by its bytes at any depth" do
      exact =
        "(selecto_root.org_key = ? AND CAST(CONVERT(selecto_root.org_key USING utf8mb4) AS BINARY) = CAST(? AS BINARY))"

      shapes = [
        {"org_key", "t1"},
        {:or, [{"org_key", "t1"}, {"org_key", "zz"}]},
        {:and, [{"id", {:gte, 0}}, {:or, [{"org_key", "t1"}, {"org_key", "zz"}]}]},
        {:or, [{"org_key", "t1"}, {"id", {:lt, 0}}]},
        {:not, {"org_key", {"!=", "t1"}}},
        {:not, {"org_key", {:not_in, ["t1"]}}}
      ]

      for shape <- shapes,
          {domain, fun} <- [
            {host_domain([shape]), & &1},
            {host_domain(), &Selecto.Tenant.require_tenant_filter(&1, shape)},
            {host_domain(), &Selecto.with_tenant(&1, %{required_filters: [shape]})}
          ] do
        sql = host_sql(domain, ExactAdapter, fun)

        assert sql =~ exact or
                 sql =~ "(selecto_root.org_key IN (?) AND CAST(CONVERT(selecto_root.org_key",
               inspect(shape)

        refute host_sql(domain, SelectoDBSQLite.Adapter, fun) =~ "BINARY"
      end

      # The caller's own filter is not host scope.
      refute host_sql(host_domain(), ExactAdapter, &Selecto.filter(&1, [{"org_key", "t1"}])) =~
               "BINARY"
    end

    test "a host predicate on a non-text column keeps the plain comparison" do
      domain =
        put_in(host_domain([{"at", {"!=", "2024-01-01 10:00:00"}}]), [:source, :columns, :at], %{
          type: :naive_datetime
        })
        |> update_in([:source, :fields], &(&1 ++ [:at]))

      refute host_sql(domain, ExactAdapter, & &1) =~ "BINARY"
    end

    test "filters the query holds when its read boundary is accepted are host scope" do
      exact =
        "(selecto_root.org_key = ? AND CAST(CONVERT(selecto_root.org_key USING utf8mb4) AS BINARY) = CAST(? AS BINARY))"

      bounded = fn selecto ->
        {:ok, selecto} =
          selecto
          |> Selecto.filter([{"org_key", "t1"}])
          |> Selecto.Tenant.require_read_boundary()

        # A request filter applied after the boundary stays the caller's.
        Selecto.filter(selecto, [{"name", "a"}])
      end

      sql = host_sql(host_domain(), ExactAdapter, bounded)
      assert sql =~ exact
      assert sql =~ "selecto_root.name = ?"
      refute sql =~ "CONVERT(selecto_root.name"

      refute host_sql(host_domain(), SelectoDBSQLite.Adapter, bounded) =~ "BINARY"
    end

    test "a canned page's dataset filters are host scope in its result, total and facets" do
      exact = "CAST(CONVERT(selecto_root.org_key USING utf8mb4) AS BINARY)"

      for adapter <- [ExactAdapter, SelectoDBSQLite.Adapter] do
        base =
          Selecto.configure(host_domain(), Selecto.Runtime.Context.new(adapter, :compile_only),
            validate: false
          )

        page =
          Selecto.CannedPage.new!(Selecto.filter(base, [{"org_key", "t1"}]),
            id: "hs",
            views: [%{id: "detail", kind: :detail, query: Selecto.select(base, ["id", "name"])}],
            controls: [%{id: "name", kind: :facet, field: "name"}]
          )

        {:ok, plan} = Selecto.CannedPage.plan(page, base, %{})

        for query <- [plan.query, plan.total_query, plan.facets["name"].options] do
          {sql, _params} = Selecto.to_sql(query)
          assert sql =~ exact == (adapter == ExactAdapter), sql
        end
      end
    end

    test "a trusted context's required filters apply without a tenant_id" do
      sql =
        host_sql(
          host_domain(),
          SelectoDBSQLite.Adapter,
          &Selecto.with_tenant(&1, %{required_filters: [{"org_key", "t1"}]})
        )

      assert sql =~ "org_key"
    end
  end

  test "a through target scope key the target does not declare is refused at configure" do
    domain = %{
      name: "Th",
      source:
        relation(
          "items",
          [id: :integer, tenant_key: :string],
          %{
            th: %{
              queryable: :acc,
              field: :th,
              owner_key: :id,
              related_key: :id,
              cardinality: :many,
              through: %{
                table: "bridge",
                owner_key: :item_id,
                related_key: :acc_id,
                source_scope_key: :tenant_key,
                through_scope_key: :org_key,
                target_scope_key: :org_key
              }
            }
          },
          :tenant_key
        ),
      schemas: %{acc: relation("acc", [id: :integer, label: :string], %{}, nil)},
      joins: %{th: %{type: :left, name: "th"}}
    }

    assert_raise ArgumentError, ~r/target scope field :org_key is not declared/, fn ->
      Selecto.configure(
        domain,
        Selecto.Runtime.Context.new(SelectoDBSQLite.Adapter, :compile_only),
        validate: false
      )
    end
  end

  test "a trusted context whose required filters exclude its tenant is a typed mismatch" do
    domain = %{
      name: "S",
      source: relation("s", [id: :integer, tenant_id: :integer], %{}, :tenant_id),
      schemas: %{},
      joins: %{}
    }

    selecto =
      Selecto.configure(
        domain,
        Selecto.Runtime.Context.new(SelectoDBSQLite.Adapter, :compile_only),
        validate: false
      )

    error =
      assert_raise Selecto.PolicyViolation, fn ->
        Selecto.with_tenant(selecto, %{tenant_id: 1, required_filters: [{"tenant_id", 2}]})
      end

    assert error.type == :tenant_scope_mismatch
  end

  describe "column pairs decide from both sides" do
    defp pair_domain(n_type, s_type, required) do
      %{
        name: "PR",
        source:
          relation("pr", [id: :integer, n: n_type, s: s_type, name: :string], %{}, nil)
          |> Map.delete(:tenant_field),
        schemas: %{},
        joins: %{},
        required_filters: required
      }
    end

    defp pair_sql(domain, adapter) do
      domain
      |> Selecto.configure(Selecto.Runtime.Context.new(adapter, :compile_only), validate: false)
      |> Selecto.select(["id"])
      |> Selecto.to_sql()
      |> elem(0)
    end

    test "a host column-vs-column comparison is exact when either side may be text" do
      for {n_type, s_type} <- [{:integer, :string}, {:integer, nil}, {nil, :string}, {nil, nil}],
          filter <- [
            {"n", {:=, {:ref, "s"}}},
            {"s", {:=, {:ref, "n"}}},
            {:not, {"n", {:!=, {:ref, "s"}}}}
          ] do
        sql = pair_sql(pair_domain(n_type, s_type, [filter]), ExactAdapter)
        assert sql =~ "BINARY", inspect({n_type, s_type, filter})

        refute pair_sql(pair_domain(n_type, s_type, [filter]), SelectoDBSQLite.Adapter) =~
                 "BINARY"
      end

      # Both sides declared non-text keep the plain comparison.
      refute pair_sql(pair_domain(:integer, :integer, [{"n", {:=, {:ref, "s"}}}]), ExactAdapter) =~
               "BINARY"
    end

    test "a join key pair with a tenant column decides from both declared types" do
      # An INT tenant column keyed to a VARCHAR column: numerically '07' = 7.
      domain = %{
        name: "Orders",
        source:
          relation(
            "orders",
            [id: :integer, tenant_id: :integer, name: :string],
            %{
              owner: %{
                queryable: :owners,
                field: :owner,
                owner_key: :tenant_id,
                related_key: :code,
                cardinality: :one
              }
            },
            :tenant_id
          ),
        schemas: %{
          owners: relation("owners", [id: :integer, code: :string], %{}, nil)
        },
        joins: %{owner: %{type: :left, name: "owner"}}
      }

      sql = fn adapter ->
        domain
        |> Selecto.configure(Selecto.Runtime.Context.new(adapter, :compile_only),
          validate: false
        )
        |> Selecto.with_tenant(1)
        |> Selecto.select(["id", "owner.code"])
        |> Selecto.to_sql()
        |> elem(0)
      end

      assert sql.(ExactAdapter) =~ "CAST(CONVERT(owner.code USING utf8mb4) AS BINARY)"
      refute sql.(SelectoDBSQLite.Adapter) =~ "BINARY"
    end
  end

  test "type names classify three ways after normalising" do
    alias Selecto.Builder.ExactCompare

    for text <- [
          :string,
          "TEXT",
          "varchar(255)",
          "char(16)",
          "character varying(40)",
          "char varying",
          "national varchar",
          "national character varying",
          "NVARCHAR",
          "citext",
          "longtext",
          "varchar(16) character set utf8mb4 collate utf8mb4_bin",
          {:parameterized, {Ecto.Enum, %{}}}
        ],
        do: assert(ExactCompare.type_mode(text) == true, inspect(text))

    for plain <- [:integer, :decimal, "DECIMAL(10,2)", :naive_datetime, :time_usec, :map, :binary],
        do: assert(ExactCompare.type_mode(plain) == false, inspect(plain))

    # Names that merely contain "char" or "text", custom types, uuid and
    # undeclared columns are guarded (server-decided).
    for guarded <- [nil, "charge_amount", "context_ts", "texture", :uuid, :"Elixir.MyApp.Key"],
        do: assert(ExactCompare.type_mode(guarded) == :server, inspect(guarded))
  end
end
