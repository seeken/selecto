defmodule SelectoUpdato.AssociationReferenceGuardTest do
  @moduledoc """
  TW-05 for references that a domain declares only as a direct to-one
  association: on a tenant-scoped write the owner key may only name a parent
  row of the trusted tenant, exactly as a declared foreign key does.
  """

  use ExUnit.Case, async: true

  alias Selecto.Write.{Command, Graph}
  alias SelectoUpdato.{Error, PortableCommand}

  # The domain types site_id as an integer, so MySQL-family adapters keep the
  # plain tenant comparison (`tenant_exact: false`).
  @customer_guard %{
    field: "customer_id",
    relation: "customers",
    target_field: "id",
    tenant_field: "site_id",
    tenant_value: 10,
    tenant_exact: false
  }

  describe "an association owner key is guarded like a declared foreign key" do
    test "an insert, update and upsert carry the trusted tenant for the referenced customer" do
      for variant <- [:association, :scope_keys] do
        domain = orders_domain(customer: variant)

        assert [guard] = guards(insert(domain, %{customer_id: 2}))
        assert guard == expected_customer_guard(variant)

        assert [^guard] = guards(update(domain, 1, %{customer_id: 2}))
        assert [^guard] = guards(upsert(domain, %{id: 3, code: "B", customer_id: 2}))
      end
    end

    test "tenant columns travel in the metadata and a text tenant keeps the exact guard" do
      # MySQL-family adapters compare these columns by their stored bytes; the
      # domain types site_id as text here, so the guard carries no opt-out.
      domain =
        Enum.reduce([[:source], [:schemas, :customer], [:schemas, :parent]], orders_domain(), fn
          path, acc -> put_in(acc, path ++ [:columns, :site_id], %{type: :string})
        end)

      operation =
        domain
        |> SelectoUpdato.new(tenant: %{tenant_id: "s1"})
        |> SelectoUpdato.insert(%{id: 3, code: "B", title: "new", customer_id: 2})

      assert {:ok, %Command{metadata: metadata}, _context} = PortableCommand.compile(operation)
      assert metadata.tenant_fields == ["site_id"]

      assert [%{tenant_field: "site_id", tenant_value: "s1"} = guard] =
               metadata.foreign_key_guards

      refute Map.has_key?(guard, :tenant_exact)
    end

    test "fields a host predicate compares at any depth join the tenant fields" do
      # A host scope on a column the domain does not declare as tenant_field
      # (code, title) decides tenant identity at any depth of the predicate
      # tree; MySQL-family adapters compare it by its stored bytes. The
      # caller's own write filters are not host scope.
      operation =
        orders_domain()
        |> Map.put(:required_filters, [
          {:or, [{"code", "B"}, {:not, {"title", "u"}}]}
        ])
        |> SelectoUpdato.new(tenant: %{tenant_id: 10})
        |> SelectoUpdato.filters([{"code", "B"}, {"customer_id", 2}])
        |> SelectoUpdato.update(%{title: "t"})

      assert {:ok, %Command{metadata: metadata}, _context} = PortableCommand.compile(operation)
      assert "code" in metadata.tenant_fields
      assert "title" in metadata.tenant_fields
      assert "site_id" in metadata.tenant_fields
      refute "customer_id" in metadata.tenant_fields
    end

    test "a null reference needs no parent" do
      assert [] == guards(update(orders_domain(), 1, %{customer_id: nil}))
      assert [] == guards(insert(orders_domain(), %{title: "no reference"}))
    end

    test "a self-reference uses the root tenant field" do
      assert [
               %{
                 field: "parent_id",
                 relation: "orders",
                 target_field: "id",
                 tenant_field: "site_id",
                 tenant_value: 10
               }
             ] = guards(insert(orders_domain(), %{parent_id: 1}))
    end

    test "a nested child's association is guarded but its bound parent key is not" do
      operation =
        orders_domain()
        |> SelectoUpdato.new(tenant: %{tenant_id: 10})
        |> SelectoUpdato.insert(%{id: 3, code: "G", notes: [%{id: 1, body: "n", customer_id: 2}]})

      assert {:ok, %Graph{} = graph, _context} = PortableCommand.compile(operation)
      [note] = Enum.find(graph.nodes, &(&1.id == "notes")).rows

      assert note.command.metadata.foreign_key_guards == [@customer_guard]
      refute Enum.any?(note.command.assignments, &(&1.field == "order_id"))
    end
  end

  describe "tenancy the domain does not record" do
    test "an undeclared target fails closed on a tenant-scoped write" do
      domain = orders_domain(customer: :undeclared)

      for operation <- [
            insert(domain, %{customer_id: 1}),
            update(domain, 1, %{customer_id: 1}),
            upsert(domain, %{id: 3, code: "B", customer_id: 1})
          ] do
        assert {:error,
                %Error{
                  type: :invalid_domain,
                  details: %{code: :foreign_key_tenant_scope_undeclared, relation: "customers"}
                }} = PortableCommand.compile(operation)
      end

      assert {:ok, %Command{}, _context} =
               PortableCommand.compile(insert(domain, %{title: "no reference"}))
    end

    test "an undeclared target is not refused outside a tenant-scoped write" do
      domain =
        orders_domain(customer: :undeclared)
        |> Map.update!(:writes, &Map.delete(&1, :scope))
        |> update_in([:source], &Map.delete(&1, :tenant_field))

      operation =
        domain
        |> SelectoUpdato.new()
        |> SelectoUpdato.insert(%{id: 3, code: "B", site_id: 10, customer_id: 1})

      assert {:ok, %Command{metadata: metadata}, _context} = PortableCommand.compile(operation)
      refute Map.has_key?(metadata, :foreign_key_guards)
    end
  end

  describe "references that are not guarded" do
    test "a shared declared foreign key stays tenant-unscoped and wins over its association" do
      assert [guard] = guards(insert(orders_domain(), %{country_id: 1}))
      assert guard == %{field: "country_id", relation: "countries", target_field: "id"}
    end

    test "a declared foreign key takes precedence over an association on the same field" do
      domain =
        orders_domain(customer: :undeclared)
        |> put_in([:writes, :constraints, :foreign_keys, :customer_id], %{
          source: :input,
          references: %{relation: "customers", field: :id, tenant_field: :site_id}
        })

      assert [@customer_guard] = guards(insert(domain, %{customer_id: 2}))
    end

    test "a reverse has-one, a through, a to-many and a values association are not guarded" do
      operation =
        insert(orders_domain(), %{
          region_id: 4,
          status_id: "open",
          batch_id: 9
        })

      assert [] == guards(operation)
      assert [] == guards(update(orders_domain(), 1, %{id: 1, title: "renamed"}))
    end
  end

  defp guards(operation) do
    case PortableCommand.compile(operation) do
      {:ok, %Command{metadata: metadata}, _context} -> Map.get(metadata, :foreign_key_guards, [])
      other -> flunk("expected a command, got #{inspect(other)}")
    end
  end

  defp expected_customer_guard(:association), do: @customer_guard
  defp expected_customer_guard(:scope_keys), do: %{@customer_guard | tenant_field: "scope_site"}

  defp insert(domain, attrs) do
    domain
    |> SelectoUpdato.new(tenant: %{tenant_id: 10})
    |> SelectoUpdato.insert(Map.merge(%{id: 3, code: "B", title: "new"}, attrs))
  end

  defp update(domain, id, changes) do
    domain
    |> SelectoUpdato.new(tenant: %{tenant_id: 10})
    |> SelectoUpdato.filter({:id, id})
    |> SelectoUpdato.update(changes)
  end

  defp upsert(domain, attrs) do
    domain
    |> SelectoUpdato.new(tenant: %{tenant_id: 10})
    |> SelectoUpdato.upsert(Map.merge(%{title: "up"}, attrs))
  end

  @doc false
  def orders_domain(opts \\ []) do
    customer = Keyword.get(opts, :customer, :association)

    customer_schema =
      relation("customers", id: :integer, site_id: :integer, scope_site: :integer, name: :string)
      |> then(fn schema ->
        if customer == :association, do: Map.put(schema, :tenant_field, :site_id), else: schema
      end)

    customer_association =
      %{queryable: :customer, field: :customer, owner_key: :customer_id, related_key: :id}
      |> then(fn association ->
        if customer == :scope_keys,
          do:
            Map.merge(association, %{source_scope_key: :site_id, target_scope_key: :scope_site}),
          else: association
      end)

    %{
      name: "Orders",
      source:
        relation("orders",
          id: :integer,
          site_id: :integer,
          code: :string,
          title: :string,
          customer_id: :integer,
          country_id: :integer,
          parent_id: :integer,
          region_id: :integer,
          status_id: :string,
          batch_id: :integer
        )
        |> Map.put(:tenant_field, :site_id)
        |> Map.put(:associations, %{
          customer: customer_association,
          country: %{
            queryable: :country,
            field: :country,
            owner_key: :country_id,
            related_key: :id
          },
          parent: %{queryable: :parent, field: :parent, owner_key: :parent_id, related_key: :id},
          profile: %{queryable: :profile, field: :profile, owner_key: :id, related_key: :order_id},
          region: %{
            queryable: :region,
            field: :region,
            owner_key: :region_id,
            related_key: :id,
            through: [:customer, :region]
          },
          status: %{queryable: :status, field: :status, owner_key: :status_id, related_key: :id},
          batches: %{
            queryable: :batch,
            field: :batches,
            owner_key: :batch_id,
            related_key: :order_id,
            cardinality: :many
          }
        }),
      schemas: %{
        customer: customer_schema,
        country: relation("countries", id: :integer, name: :string),
        parent:
          relation("orders", id: :integer, site_id: :integer, code: :string)
          |> Map.put(:tenant_field, :site_id),
        profile: relation("order_profiles", id: :integer, order_id: :integer, site_id: :integer),
        region: relation("regions", id: :integer, name: :string),
        status:
          relation(nil, id: :string, name: :string)
          |> Map.delete(:source_table)
          |> Map.put(:values, [%{id: "open", name: "Open"}, %{id: "closed", name: "Closed"}]),
        batch: relation("batches", id: :integer, order_id: :integer, site_id: :integer)
      },
      joins: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true},
          upsert: %{enabled: true, conflict_targets: [[:site_id, :code]]}
        },
        fields:
          Map.new(
            [
              :id,
              :code,
              :title,
              :customer_id,
              :country_id,
              :parent_id,
              :region_id,
              :status_id,
              :batch_id,
              :site_id
            ],
            &{&1, %{insertable: true, updatable: true}}
          ),
        scope: %{tenant: %{required: true, field: :site_id, satisfied_by: [:trusted_context]}},
        constraints: %{
          foreign_keys: %{
            country_id: %{
              source: :input,
              references: %{relation: "countries", field: :id, tenant_field: false}
            }
          }
        },
        relationships: %{
          notes: %{
            writable: true,
            cardinality: :many,
            ownership: :owned,
            allowed_ops: [:insert],
            domain: notes_domain(),
            child_key: :order_id,
            parent_key: :id
          }
        }
      }
    }
  end

  defp notes_domain do
    %{
      name: "Notes",
      source:
        relation("notes",
          id: :integer,
          site_id: :integer,
          order_id: :integer,
          customer_id: :integer,
          body: :string
        )
        |> Map.put(:tenant_field, :site_id)
        |> Map.put(:associations, %{
          customer: %{
            queryable: :customer,
            field: :customer,
            owner_key: :customer_id,
            related_key: :id
          },
          order: %{queryable: :order, field: :order, owner_key: :order_id, related_key: :id}
        }),
      schemas: %{
        customer:
          relation("customers", id: :integer, site_id: :integer, name: :string)
          |> Map.put(:tenant_field, :site_id),
        order:
          relation("orders", id: :integer, site_id: :integer) |> Map.put(:tenant_field, :site_id)
      },
      joins: %{},
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: Map.new([:id, :body, :customer_id], &{&1, %{insertable: true}}),
        scope: %{tenant: %{required: true, field: :site_id, satisfied_by: [:trusted_context]}}
      }
    }
  end

  defp relation(table, columns) do
    %{
      source_table: table,
      primary_key: :id,
      fields: Keyword.keys(columns),
      columns: Map.new(columns, fn {field, type} -> {field, %{type: type}} end),
      associations: %{}
    }
  end
end
