defmodule SelectoUpdato.NestedGraphTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{Command, Graph}
  alias Selecto.Write.Graph.{Binding, Node, Row}

  test "compiles a tenant-governed nested insert into a topological portable graph" do
    operation =
      order_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{
        reference: "SO-100",
        items: [
          %{
            sku: "WIDGET",
            quantity: 2,
            allocations: [%{bin: "A-1", quantity: 2}]
          }
        ]
      })

    assert {:ok, %Graph{} = graph, %{tenant_id: 7}} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert Enum.map(graph.nodes, & &1.id) == ["root", "items", "items/0/allocations"]
    assert graph.root == {"root", "root"}
    assert graph.atomic?

    assert %Node{strategy: :ordered, rows: [%Row{command: root}]} = hd(graph.nodes)
    assert root.returning == [:id]
    assert literal_assignment(root, "tenant_id") == 7

    assert %Node{strategy: :ordered, rows: [item]} = Enum.at(graph.nodes, 1)
    assert item.path == [:items, 0]
    assert item.command.returning == [:id]
    assert literal_assignment(item.command, "tenant_id") == 7

    assert [%Binding{field: :order_id, from_node: "root", from_field: :id}] = item.bindings

    assert %Node{strategy: :ordered, rows: [allocation]} = Enum.at(graph.nodes, 2)
    assert allocation.path == [:items, 0, :allocations, 0]

    assert [%Binding{field: :item_id, from_node: "items", from_row: "0", from_field: :id}] =
             allocation.bindings
  end

  test "does not duplicate generated keys already requested by the caller" do
    operation =
      order_domain()
      |> put_in([:writes, :operations, :insert, :returning], :all)
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{
        reference: "SO-RETURNING",
        items: [%{sku: "WIDGET", quantity: 2}]
      })
      |> SelectoUpdato.returning([:id, :reference])

    assert {:ok, %Graph{nodes: [%Node{rows: [%Row{command: root}]} | _]}, _context} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert root.returning == ["id", "reference"]
    assert :ok = Command.validate(root)
  end

  test "projects nested relationship policy without embedding the complete child domain" do
    assert {:ok, contract, _diagnostics} = SelectoUpdato.domain_contract(order_domain())

    assert [relationship] = contract.relationships
    assert relationship.id == "items"
    assert relationship.child_key == "order_id"
    assert relationship.parent_key == "id"
    assert relationship.identity_fields == ["id"]
    assert relationship.strategy == :sync
    assert relationship.delete_missing
    assert relationship.child_domain.relation == "order_items"
    refute Map.has_key?(relationship.raw, :domain)
  end

  test "compiles nested update as owned-set sync without exposing an adapter switch" do
    operation =
      order_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        reference: "SO-100-R",
        items: [
          %{id: 11, sku: "WIDGET", quantity: 3},
          %{sku: "NEW", quantity: 1}
        ]
      })

    assert {:ok, %Graph{} = graph, _context} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert %Node{} = items = Enum.find(graph.nodes, &(&1.id == "items"))
    assert items.strategy == :sync
    assert items.identity_fields == [:id]
    assert items.delete_missing?

    assert items.sync_predicate ==
             {:and,
              [
                {:eq, {:field, :order_id}, {:generated, "root", "root", :id}},
                {:eq, {:field, :tenant_id}, {:literal, 7}}
              ]}

    assert [
             %Row{command: %Command{operation: :update}} = existing,
             %Row{command: %Command{operation: :insert}} = new
           ] = items.rows

    assert existing.metadata.identity == %{id: 11}
    assert new.metadata.identity == %{}

    assert Enum.any?(
             existing.command.predicate |> predicates(),
             &match?({:eq, {:field, "id"}, {:literal, 11}}, &1)
           )

    refute Enum.any?(existing.command.assignments, &(&1.field == "id"))
  end

  test "rejects caller-supplied ownership keys and malformed nested entries" do
    override =
      order_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{
        reference: "SO-100",
        items: [%{order_id: 99, sku: "WIDGET", quantity: 2}]
      })

    assert {:error, %{type: :invalid_graph, details: %{field: :order_id}}} =
             SelectoUpdato.PortableCommand.compile(override)

    malformed =
      order_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{reference: "SO-100", items: ["not-a-row"]})

    assert {:error, %{type: :invalid_graph}} =
             SelectoUpdato.PortableCommand.compile(malformed)
  end

  test "rejects relationship keys and identities that do not exist in their domains" do
    missing_child_key =
      put_in(order_domain(), [:writes, :relationships, :items, :child_key], :missing_order_id)

    operation =
      missing_child_key
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{
        reference: "SO-BAD-CHILD-KEY",
        items: [%{sku: "WIDGET", quantity: 2}]
      })

    assert {:error, %{type: :invalid_operation, details: %{errors: errors}}} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert Enum.any?(errors, fn {path, message} ->
             path == [:writes, :relationships, :items, :child_key] and
               message =~ "child domain"
           end)

    missing_parent_key =
      put_in(order_domain(), [:writes, :relationships, :items, :parent_key], :missing_parent_id)

    operation =
      missing_parent_key
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{
        reference: "SO-BAD-PARENT-KEY",
        items: [%{sku: "WIDGET", quantity: 2}]
      })

    assert {:error, %{type: :invalid_operation, details: %{errors: errors}}} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert Enum.any?(errors, fn {path, message} ->
             path == [:writes, :relationships, :items, :parent_key] and
               message =~ "parent domain"
           end)

    missing_identity =
      put_in(order_domain(), [:writes, :relationships, :items, :identity_fields], [:missing_id])

    operation =
      missing_identity
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{
        reference: "SO-BAD-IDENTITY",
        items: [%{sku: "WIDGET", quantity: 2}]
      })

    assert {:error, %{type: :invalid_operation, details: %{errors: errors}}} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert Enum.any?(errors, fn {path, message} ->
             path == [:writes, :relationships, :items, :identity_fields] and
               message =~ "child domain"
           end)
  end

  test "validates colocated relationship policy after normalization" do
    domain =
      order_domain()
      |> then(fn domain ->
        relationship = get_in(domain, [:writes, :relationships, :items])

        domain
        |> put_in([:source, :associations, :items], %{
          queryable: :items,
          field: :items,
          cardinality: :many,
          owner_key: :id,
          related_key: :order_id,
          write:
            relationship
            |> Map.drop([:cardinality, :parent_key, :child_key])
            |> Map.put(:child_key, :missing_order_id)
        })
        |> update_in([:writes], &Map.delete(&1, :relationships))
      end)

    operation =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{
        reference: "SO-BAD-COLOCATED-KEY",
        items: [%{sku: "WIDGET", quantity: 2}]
      })

    assert {:error, %{type: :invalid_operation, details: %{errors: errors}}} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert Enum.any?(errors, fn {path, message} ->
             path == [:writes, :relationships, :items, :child_key] and
               message =~ "child domain"
           end)
  end

  test "a site-column child of a two-column root stays within the root's pinned site" do
    # Lesson 47a addendum: the engine value binds the root tenant_id; a child
    # whose tenant field is the scope column is never bound to it.
    # Lesson 47b: only trusted predicates pin sites; a caller filter does not.
    insert = fn required, filters, child_site ->
      item =
        if is_nil(child_site),
          do: %{sku: "WIDGET", quantity: 1},
          else: %{sku: "WIDGET", quantity: 1, site_id: child_site}

      two_column_order_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: 7, required_filters: required})
      |> SelectoUpdato.filters(filters)
      |> SelectoUpdato.insert(%{reference: "SO-1", site_id: 70, items: [item]})
      |> SelectoUpdato.Tenant.apply_execution_scope()
      |> SelectoUpdato.PortableCommand.compile()
    end

    pin = [{:site_id, 70}]
    assert {:error, %{type: :missing_tenant_scope}} = insert.([], [], 70)
    assert {:error, %{type: :missing_tenant_scope}} = insert.([], pin, 70)
    assert {:error, %{type: :tenant_mismatch}} = insert.(pin, [], 7)

    for child_site <- [70, nil] do
      assert {:ok, %Graph{} = graph, _context} = insert.(pin, [], child_site)
      assert %Node{rows: [%Row{command: root}]} = hd(graph.nodes)
      assert literal_assignment(root, "tenant_id") == 7
      assert literal_assignment(root, "site_id") == 70
      assert %Node{rows: [item]} = Enum.at(graph.nodes, 1)
      assert literal_assignment(item.command, "site_id") == 70
    end
  end

  test "graph children storing root tenant columns are checked against the root sets" do
    # Lesson 47b: whatever a child declares, a column naming the root scope
    # column must lie in the root's trusted site pin, and a column naming the
    # root tenant_field is bound to the trusted tenant.
    with_columns = fn item ->
      item
      |> put_in([:source, :fields], [:id, :tenant_id, :site_id, :order_id, :sku, :quantity])
      |> put_in([:source, :columns, :tenant_id], %{type: :string})
      |> update_in([:writes], &Map.delete(&1, :scope))
    end

    variants = [
      {fn item -> item |> with_columns.() |> put_in([:source, :tenant_field], :tenant_id) end,
       true},
      {fn item ->
         item |> with_columns.() |> update_in([:source], &Map.delete(&1, :tenant_field))
       end, true},
      {fn item ->
         item
         |> update_in([:source], &Map.delete(&1, :tenant_field))
         |> update_in([:writes], &Map.delete(&1, :scope))
       end, false}
    ]

    for {child, tenant_column?} <- variants do
      domain =
        update_in(two_column_order_domain(), [:writes, :relationships, :items, :domain], child)

      insert = fn required, item ->
        domain
        |> SelectoUpdato.new()
        |> SelectoUpdato.with_tenant(%{tenant_id: 7, required_filters: required})
        |> SelectoUpdato.insert(%{reference: "SO-1", site_id: 70, items: [item]})
        |> SelectoUpdato.Tenant.apply_execution_scope()
        |> SelectoUpdato.PortableCommand.compile()
      end

      pin = [{:site_id, 70}]
      item = %{sku: "W", quantity: 1}

      assert {:error, %{type: :tenant_mismatch}} = insert.(pin, Map.put(item, :site_id, 7))
      assert {:error, %{type: :missing_tenant_scope}} = insert.([], Map.put(item, :site_id, 7))

      assert {:ok, %Graph{} = graph, _context} = insert.(pin, Map.put(item, :site_id, 70))
      assert %Node{rows: [row]} = Enum.at(graph.nodes, 1)
      assert literal_assignment(row.command, "site_id") == 70

      if tenant_column? do
        assert literal_assignment(row.command, "tenant_id") == 7

        assert {:error, %{type: :tenant_mismatch}} =
                 insert.(pin, Map.merge(item, %{site_id: 70, tenant_id: "8"}))
      end
    end
  end

  test "a child keeping its own tenancy also binds the root tenant column" do
    # Round 4: a child declaring tenant_field org_id that also stores the
    # root's tenant_id and site_id keeps its org binding and gains the root
    # column checks, as on a one-column root.
    item =
      domain("order_items", [:id, :org_id, :tenant_id, :site_id, :order_id, :sku, :quantity], %{
        sku: %{insertable: true},
        quantity: %{insertable: true},
        org_id: %{insertable: true},
        site_id: %{insertable: true}
      })
      |> put_in([:source, :tenant_field], :org_id)

    domain = put_in(two_column_order_domain(), [:writes, :relationships, :items, :domain], item)

    insert = fn child ->
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(%{tenant_id: 7, required_filters: [{:site_id, 70}]})
      |> SelectoUpdato.insert(%{reference: "SO-1", site_id: 70, items: [child]})
      |> SelectoUpdato.Tenant.apply_execution_scope()
      |> SelectoUpdato.PortableCommand.compile()
    end

    for child <- [
          %{sku: "W", quantity: 1, org_id: "8"},
          %{sku: "W", quantity: 1, org_id: 7, tenant_id: 8},
          %{sku: "W", quantity: 1, org_id: 7, site_id: 7}
        ] do
      assert {:error, %{type: :tenant_mismatch}} = insert.(child)
    end

    assert {:ok, %Graph{} = graph, _context} = insert.(%{sku: "W", quantity: 1})
    assert %Node{rows: [row]} = Enum.at(graph.nodes, 1)
    assert literal_assignment(row.command, "org_id") == 7
    assert literal_assignment(row.command, "tenant_id") == 7
    assert literal_assignment(row.command, "site_id") == 70
  end

  test "children of a root tenanted only by writes.scope.tenant are bound too" do
    # Round 5 (lessons 24/29k): order_domain() declares no source.tenant_field;
    # its tenancy is writes.scope.tenant on tenant_id.
    child = fn fields, write_fields ->
      domain(
        "order_items",
        fields,
        Map.merge(%{sku: %{insertable: true}, quantity: %{insertable: true}}, write_fields)
      )
      |> update_in([:writes], &Map.delete(&1, :scope))
    end

    children = [
      child.([:id, :tenant_id, :order_id, :sku, :quantity], %{}),
      child.([:id, :org_id, :tenant_id, :order_id, :sku, :quantity], %{
        org_id: %{insertable: true}
      })
      |> put_in([:source, :tenant_field], :org_id)
    ]

    for item <- children, via <- [:operation, :context] do
      domain = put_in(order_domain(), [:writes, :relationships, :items, :domain], item)

      insert = fn extra ->
        operation =
          domain
          |> SelectoUpdato.new()
          |> then(
            &if(via == :operation, do: SelectoUpdato.with_tenant(&1, %{tenant_id: 7}), else: &1)
          )
          |> SelectoUpdato.insert(%{
            reference: "SO-1",
            items: [Map.merge(%{sku: "W", quantity: 1}, extra)]
          })

        opts = if via == :context, do: [context: %{tenant_id: 7}], else: []

        operation
        |> SelectoUpdato.Tenant.apply_execution_scope(opts)
        |> SelectoUpdato.PortableCommand.compile(opts)
      end

      for tenant <- ["8", 8] do
        assert {:error, %{type: :tenant_mismatch}} = insert.(%{tenant_id: tenant})
      end

      assert {:ok, %Graph{} = graph, _context} = insert.(%{})
      assert %Node{rows: [row]} = Enum.at(graph.nodes, 1)
      assert literal_assignment(row.command, "tenant_id") == 7
    end
  end

  test "requires tenant context throughout the nested graph" do
    operation =
      order_domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{
        reference: "SO-100",
        items: [%{sku: "WIDGET", quantity: 2}]
      })

    assert {:error, %{type: :missing_tenant_scope}} =
             SelectoUpdato.PortableCommand.compile(operation)
  end

  test "empty nested sync requires the tenant scope of a scoped child domain" do
    unscoped_parent = update_in(order_domain()[:writes], &Map.delete(&1, :scope))

    operation =
      unscoped_parent
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{reference: "SO-EMPTY-SYNC", items: []})

    assert {:error, %{type: :missing_tenant_scope}} =
             SelectoUpdato.PortableCommand.compile(operation)
  end

  test "nested relationship permissions constrain child inserts and delete-missing" do
    insert_denied_domain =
      put_in(order_domain(), [:writes, :relationships, :items, :allowed_ops], [:update, :delete])

    insert_operation =
      insert_denied_domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        reference: "SO-INSERT-DENIED",
        items: [%{sku: "NEW", quantity: 1}]
      })

    assert {:error, %{type: :write_operation_not_enabled, details: %{operation: :insert}}} =
             SelectoUpdato.PortableCommand.compile(insert_operation)

    delete_denied_domain =
      put_in(order_domain(), [:writes, :relationships, :items, :allowed_ops], [:update])

    delete_operation =
      delete_denied_domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{reference: "SO-DELETE-DENIED", items: []})

    assert {:error, %{type: :write_operation_not_enabled, details: %{operation: :delete}}} =
             SelectoUpdato.PortableCommand.compile(delete_operation)
  end

  test "empty owned sync includes required child predicates in cleanup scope" do
    domain =
      put_in(order_domain(), [:writes, :relationships, :items, :domain, :required_filters], [
        {"sku", "visible"}
      ])

    operation =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{reference: "scoped", items: []})

    assert {:ok, graph, _} = SelectoUpdato.PortableCommand.compile(operation)
    items = Enum.find(graph.nodes, &(&1.id == "items"))
    assert items.rows == []

    assert items.sync_predicate ==
             {:and,
              [
                {:eq, {:field, :order_id}, {:generated, "root", "root", :id}},
                {:and,
                 [
                   {:eq, {:field, :tenant_id}, {:literal, 7}},
                   {:eq, {:field, "sku"}, {:literal, "visible"}}
                 ]}
              ]}
  end

  test "delete_missing is opt-in for nested sync" do
    safe_default_domain =
      order_domain()
      |> put_in([:writes, :relationships, :items, :allowed_ops], [:update])
      |> update_in([:writes, :relationships, :items], &Map.delete(&1, :delete_missing))

    operation =
      safe_default_domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{reference: "SO-NO-DELETE", items: []})

    assert {:ok, %Graph{} = graph, _context} = SelectoUpdato.PortableCommand.compile(operation)
    refute Enum.find(graph.nodes, &(&1.id == "items")).delete_missing?
  end

  test "represents an explicitly empty optional insert relationship without a fake row" do
    operation =
      order_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(%{reference: "SO-EMPTY", items: []})

    assert {:ok, %Graph{nodes: [_root, items]} = graph, _context} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert items.strategy == :ordered
    assert items.rows == []
    assert :ok = Graph.validate(graph)
  end

  test "fails early rather than inventing a no-op update anchor" do
    operation =
      order_domain()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{items: [%{id: 11, quantity: 3}]})

    assert {:error, %{type: :invalid_graph, message: message}} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert message =~ "root update requires"
  end

  test "rejects nested writes deeper than the compiler safety bound" do
    {deep_domain, deep_payload} = deeply_nested_insert(33)

    operation =
      deep_domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.insert(deep_payload)

    assert {:error,
            %{
              type: :invalid_graph,
              details: %{depth: 33, max_depth: 32}
            }} = SelectoUpdato.PortableCommand.compile(operation)
  end

  defp literal_assignment(command, field) do
    Enum.find_value(command.assignments, fn assignment ->
      if to_string(assignment.field) == field do
        {:literal, value} = assignment.value
        value
      end
    end)
  end

  defp predicates({:and, values}), do: values
  defp predicates(value), do: [value]

  defp deeply_nested_insert(depth) do
    fields = [:id, :tenant_id, :parent_id, :name]
    writable = %{name: %{insertable: true}}
    leaf = domain("level_#{depth}", fields, writable)

    Enum.reduce((depth - 1)..0//-1, {leaf, %{name: "leaf"}}, fn level,
                                                                {child_domain, child_payload} ->
      parent =
        domain("level_#{level}", fields, writable)
        |> put_in([:writes, :relationships], %{
          child: %{
            writable: true,
            cardinality: :one,
            ownership: :owned,
            allowed_ops: [:insert],
            domain: child_domain,
            child_key: :parent_id,
            parent_key: :id,
            strategy: :sync,
            delete_missing: false
          }
        })

      {parent, %{name: "level-#{level}", child: child_payload}}
    end)
  end

  defp order_domain do
    item_domain = item_domain()

    domain("orders", [:id, :tenant_id, :reference], %{
      reference: %{insertable: true, updatable: true, required_on: [:insert]}
    })
    |> put_in([:writes, :relationships], %{
      items: %{
        writable: true,
        cardinality: :many,
        ownership: :owned,
        allowed_ops: [:insert, :update, :delete],
        domain: item_domain,
        child_key: :order_id,
        parent_key: :id,
        strategy: :sync,
        identity_fields: [:id],
        delete_missing: true
      }
    })
  end

  defp item_domain do
    allocation_domain =
      domain("item_allocations", [:id, :tenant_id, :item_id, :bin, :quantity], %{
        bin: %{insertable: true, updatable: true, required_on: [:insert]},
        quantity: %{insertable: true, updatable: true, required_on: [:insert]}
      })

    domain("order_items", [:id, :tenant_id, :order_id, :sku, :quantity], %{
      sku: %{insertable: true, updatable: true, required_on: [:insert]},
      quantity: %{insertable: true, updatable: true, required_on: [:insert]}
    })
    |> put_in([:writes, :relationships], %{
      allocations: %{
        writable: true,
        cardinality: :many,
        ownership: :owned,
        allowed_ops: [:insert, :update, :delete],
        domain: allocation_domain,
        child_key: :item_id,
        parent_key: :id,
        strategy: :sync,
        identity_fields: [:id],
        delete_missing: true
      }
    })
  end

  defp two_column_order_domain do
    item =
      domain("order_items", [:id, :site_id, :order_id, :sku, :quantity], %{
        sku: %{insertable: true, updatable: true, required_on: [:insert]},
        quantity: %{insertable: true, updatable: true, required_on: [:insert]},
        site_id: %{insertable: true, immutable: true}
      })
      |> update_in([:writes, :fields], &Map.delete(&1, :tenant_id))
      |> put_in([:source, :tenant_field], :site_id)
      |> put_in([:writes, :scope], %{tenant: %{required: true, field: :site_id}})

    domain("orders", [:id, :tenant_id, :site_id, :reference], %{
      reference: %{insertable: true, updatable: true, required_on: [:insert]},
      site_id: %{insertable: true, immutable: true}
    })
    |> put_in([:source, :tenant_field], :tenant_id)
    |> put_in([:writes, :scope], %{tenant: %{required: true, field: :site_id}})
    |> put_in([:writes, :relationships], %{
      items: %{
        writable: true,
        cardinality: :many,
        ownership: :owned,
        allowed_ops: [:insert, :update, :delete],
        domain: item,
        child_key: :order_id,
        parent_key: :id,
        strategy: :sync,
        identity_fields: [:id],
        delete_missing: true
      }
    })
  end

  defp domain(relation, fields, write_fields) do
    columns = Map.new(fields, &{&1, %{type: :string}})

    %{
      name: relation,
      source: %{
        source_table: relation,
        primary_key: :id,
        fields: fields,
        columns: columns,
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true, expected_cardinality: {:exactly, 1}},
          update: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}}
        },
        fields:
          Map.merge(
            %{
              tenant_id: %{insertable: true, immutable: true}
            },
            write_fields
          ),
        scope: %{tenant: %{required: true, field: :tenant_id}},
        relationships: %{}
      }
    }
  end
end
