defmodule Selecto.ConfigureSchemaV2Test do
  use ExUnit.Case, async: true

  alias Selecto.Domain
  alias Selecto.Domain.SchemaV2

  defmodule Registry do
    @behaviour Selecto.Domain.Registry

    @impl true
    def fetch("orders", _context),
      do: {:ok, Selecto.ConfigureSchemaV2Test.document(), %{fingerprint: "host-label"}}

    def fetch(_id, _context), do: {:error, :not_found}
  end

  # A schema 2 document as a host loads it from JSON: string keys throughout.
  def document(table_prefix \\ "s2") do
    %{
      "schema_version" => 2,
      "name" => "Orders",
      "tenant" => %{"field" => "org_id", "pins" => [["region", "eu"]]},
      "source" => %{
        "source_table" => "#{table_prefix}_orders",
        "primary_key" => "id",
        "columns" => %{
          "id" => %{"type" => "integer"},
          "org_id" => %{"type" => "integer"},
          "region" => %{"type" => "string"},
          "customer_id" => %{"type" => "integer"},
          "total" => %{"type" => "integer", "description" => "Order total in cents"}
        },
        "field_order" => ["id", "org_id", "region", "customer_id", "total"],
        "associations" => %{
          "customer" => %{
            "queryable" => "customers",
            "field" => "customer",
            "owner_key" => "customer_id",
            "related_key" => "id",
            "cardinality" => "one"
          }
        }
      },
      "schemas" => %{
        "customers" => %{
          "source_table" => "#{table_prefix}_customers",
          "primary_key" => "id",
          "tenant_field" => "org_id",
          "columns" => %{
            "id" => %{"type" => "integer"},
            "org_id" => %{"type" => "integer"},
            "name" => %{"type" => "string", "description" => "Customer display name"}
          },
          "associations" => %{}
        }
      },
      "joins" => %{"customer" => %{"type" => "left", "name" => "Customer"}},
      "writes" => %{
        "operations" => %{"insert" => %{"enabled" => true}},
        "fields" => %{"total" => %{"insertable" => true}}
      }
    }
  end

  # The atom-keyed `schema_version: 2` Elixir domains used for their own
  # projection sections before specification 3.0.
  defp legacy_domain do
    %{
      schema_version: 2,
      name: "Invoices",
      source: %{
        source_table: "invoices",
        primary_key: :id,
        fields: [:id, :status],
        redact_fields: [],
        columns: %{id: %{type: :integer}, status: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      capabilities: %{"invoice.view" => %{operations: [:select, :detail]}},
      actions: %{
        approve_invoice: %{type: :transition, transition: :approve, required_fields: [:id]}
      }
    }
  end

  describe "SchemaV2.document?/1" do
    test "is only a string-keyed schema_version of the number 2" do
      assert SchemaV2.document?(document())
      assert SchemaV2.document?(%{"schema_version" => 2})
      refute SchemaV2.document?(legacy_domain())
      refute SchemaV2.document?(%{schema_version: 2})
      refute SchemaV2.document?(%{"schema_version" => "2"})
      refute SchemaV2.document?(%{"schema_version" => 1})
      refute SchemaV2.document?(nil)
    end
  end

  describe "SchemaV2.to_runtime/1" do
    test "maps the document to the atom-keyed version 1 form" do
      runtime = SchemaV2.to_runtime(document())

      assert runtime.schema_version == 1
      assert runtime.domain_fingerprint == SchemaV2.fingerprint(document())
      refute Map.has_key?(runtime, :tenant)
      refute Map.has_key?(runtime, "tenant")

      assert runtime.source.tenant_field == :org_id
      assert runtime.source.primary_key == :id
      assert runtime.source.fields == [:id, :org_id, :region, :customer_id, :total]

      assert runtime.source.columns.total == %{
               type: :integer,
               description: "Order total in cents"
             }

      assert runtime.source.associations.customer == %{
               queryable: :customers,
               field: :customer,
               owner_key: :customer_id,
               related_key: :id,
               cardinality: :one
             }

      assert runtime.schemas.customers.tenant_field == :org_id
      assert runtime.schemas.customers.fields == [:id, :name, :org_id]
      assert runtime.schemas.customers.redact_fields == []
      assert runtime.joins == %{customer: %{type: :left, name: "Customer"}}

      assert runtime.writes.scope == %{tenant: %{required: true, field: :org_id}}
      assert runtime.writes.operations == %{insert: %{enabled: true}}
      assert runtime.required_filters == [{"region", "eu"}]
    end

    test "keeps write_field and satisfied_by in writes.scope.tenant" do
      document =
        document()
        |> put_in(["source", "columns", "site_id"], %{"type" => "integer"})
        |> put_in(["source", "field_order"], [
          "id",
          "org_id",
          "site_id",
          "region",
          "customer_id",
          "total"
        ])
        |> Map.put("tenant", %{
          "field" => "org_id",
          "write_field" => "site_id",
          "satisfied_by" => ["trusted_context"]
        })

      assert SchemaV2.validate(document) == []
      runtime = SchemaV2.to_runtime(document)

      assert runtime.source.tenant_field == :org_id

      assert runtime.writes.scope.tenant == %{
               required: true,
               field: :site_id,
               satisfied_by: ["trusted_context"]
             }

      refute Map.has_key?(runtime, :required_filters)
    end
  end

  describe "Selecto.configure/3" do
    test "configures a schema 2 document as its runtime form" do
      selecto = Selecto.configure(document(), :compile_only)

      assert selecto.domain == SchemaV2.to_runtime(document())
      assert Domain.domain_fingerprint(selecto.domain) == SchemaV2.fingerprint(document())
      assert selecto.set.required_filters == [{"region", "eu"}]

      assert {:ok, contract} = Selecto.Domain.WriteContract.compile(selecto.domain)
      assert contract.scope.tenant.field == :org_id
      assert contract.scope.tenant.required

      assert Domain.field_description(selecto.domain, "total") == "Order total in cents"
      assert Domain.field_description(selecto.domain, "customer.name") == "Customer display name"
    end

    test "queries a schema 2 document through its tenant, pins and joins" do
      {sql, _aliases, params} =
        document()
        |> Selecto.configure(:compile_only)
        |> Selecto.with_tenant(7)
        |> Selecto.select(["id", "customer.name"])
        |> Selecto.gen_sql([])

      sql = String.downcase(sql)
      assert sql =~ "from s2_orders"
      assert sql =~ "left join s2_customers"
      assert sql =~ "org_id"
      assert sql =~ "region"
      assert 7 in params
      assert "eu" in params
    end

    test "refuses a schema 2 document that breaks a schema 2 rule, even unvalidated" do
      broken = put_in(document(), ["tenant", "field"], "missing")

      for opts <- [[], [validate: false]] do
        error =
          assert_raise Selecto.DomainValidator.ValidationError, fn ->
            Selecto.configure(broken, :compile_only, opts)
          end

        assert error.message =~ "invalid_tenant_field"
        assert error.message =~ ~s(["tenant", "field"])
      end
    end

    test "refuses a schema 2 document that still declares writes.scope.tenant" do
      broken =
        put_in(document(), ["writes", "scope"], %{
          "tenant" => %{"required" => true, "field" => "org_id"}
        })

      assert_raise Selecto.DomainValidator.ValidationError, ~r/writes_scope_tenant_removed/, fn ->
        Selecto.configure(broken, :compile_only)
      end
    end

    test "reads a legacy atom-keyed schema_version 2 domain as authored" do
      selecto = Selecto.configure(legacy_domain(), :compile_only)

      assert selecto.domain == legacy_domain()
      assert selecto.domain.schema_version == 2
      refute Map.has_key?(selecto.domain, :domain_fingerprint)
      assert selecto.domain.capabilities["invoice.view"].operations == [:select, :detail]

      {sql, _aliases, _params} =
        selecto |> Selecto.select(["id", "status"]) |> Selecto.gen_sql([])

      assert String.downcase(sql) =~ "from invoices"

      assert {:ok, normalized, _diagnostics} = Domain.normalize(legacy_domain())
      assert normalized.schema_version == 2
    end
  end

  describe "Selecto.configure_registered/3" do
    test "resolves a registered schema 2 document to its runtime form" do
      selecto = Selecto.configure_registered("orders", :compile_only, registry: Registry)

      assert selecto.domain == SchemaV2.to_runtime(document())
      assert selecto.domain_ref.fingerprint == SchemaV2.fingerprint(document())
      assert selecto.domain.writes.scope.tenant == %{required: true, field: :org_id}
    end
  end

  describe "against PostgreSQL" do
    @describetag :requires_db

    test "a configured schema 2 document reads only its tenant's pinned rows" do
      {:ok, conn} = Postgrex.start_link(connection_options())
      schema = "selecto_schema_v2_#{System.unique_integer([:positive])}"
      Postgrex.query!(conn, "CREATE SCHEMA #{schema}", [])

      try do
        {:ok, scoped} =
          Postgrex.start_link(Keyword.put(connection_options(), :parameters, search_path: schema))

        try do
          for statement <- [
                "CREATE TABLE s2_customers (id INT PRIMARY KEY, org_id INT NOT NULL, name TEXT)",
                "CREATE TABLE s2_orders (id INT PRIMARY KEY, org_id INT NOT NULL, region TEXT, customer_id INT, total INT)",
                "INSERT INTO s2_customers VALUES (10, 1, 'Ada'), (20, 2, 'Other org')",
                "INSERT INTO s2_orders VALUES (1, 1, 'eu', 10, 100), (2, 1, 'us', 10, 200), (3, 2, 'eu', 20, 300), (4, 1, 'eu', NULL, 400)"
              ],
              do: Postgrex.query!(scoped, statement, [])

          base = Selecto.configure(document(), scoped, adapter: SelectoDBPostgreSQL.Adapter)

          {:ok, {rows, _columns, _aliases}} =
            base
            |> Selecto.with_tenant(1)
            |> Selecto.select(["id", "total", "customer.name"])
            |> Selecto.order_by(Selecto.Expr.asc("id"))
            |> Selecto.execute()

          # Tenant 1, pinned to region eu: order 2 is in us, order 3 is tenant 2's.
          assert rows == [[1, 100, "Ada"], [4, 400, nil]]

          {:ok, {other, _columns, _aliases}} =
            base
            |> Selecto.with_tenant(2)
            |> Selecto.select(["id", "customer.name"])
            |> Selecto.execute()

          assert other == [[3, "Other org"]]
        after
          GenServer.stop(scoped)
        end
      after
        Postgrex.query!(conn, "DROP SCHEMA #{schema} CASCADE", [])
        GenServer.stop(conn)
      end
    end
  end

  defp connection_options do
    [
      hostname: System.get_env("SELECTO_POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("SELECTO_POSTGRES_PORT", "5432")),
      username: System.get_env("SELECTO_POSTGRES_USER", "postgres"),
      password: System.get_env("SELECTO_POSTGRES_PASSWORD", "password"),
      database: System.get_env("SELECTO_POSTGRES_DATABASE", "selecto_test")
    ]
  end
end
