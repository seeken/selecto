defmodule SelectoUpdato.NestedCompositionTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.CompositionFixtures
  alias Selecto.Write.Graph
  alias Selecto.Write.Graph.Node

  test "delta compiles create, update, and delete rows with stable identity paths" do
    operation =
      CompositionFixtures.order_document()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        status: "submitted",
        items: %{
          mode: :delta,
          create: [
            %{client_id: "new-1", product_id: 5, quantity: 2, lock_version: 1}
          ],
          update: [%{id: 11, lock_version: 7, quantity: 3}],
          delete: [%{id: 12, lock_version: 2}]
        }
      })

    assert {:ok, %Graph{} = graph, %{tenant_id: 7}} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert %Node{strategy: :ordered, metadata: %{mutation_mode: :delta}} =
             items = Enum.find(graph.nodes, &(&1.id == "items"))

    assert Enum.map(items.rows, & &1.command.operation) == [:insert, :update, :delete]

    assert Enum.map(items.rows, & &1.path) == [
             [:items, "client_id=new-1"],
             [:items, "id=11"],
             [:items, "id=12"]
           ]

    [created, updated, deleted] = items.rows
    assert created.metadata.client_identity == "new-1"
    assert created.metadata.semantic_operation == :create
    refute assignment?(created.command, "client_id")

    assert updated.metadata.identity == %{"id" => 11}
    assert predicate?(updated.command, "id", 11)
    assert predicate?(updated.command, "lock_version", 7)
    refute assignment?(updated.command, "lock_version")

    assert predicate?(deleted.command, "id", 12)
    assert predicate?(deleted.command, "lock_version", 2)
    assert Enum.all?(items.rows, &parent_binding?(&1, "order_id"))
  end

  test "full-set remains distinct from delta and carries explicit delete-missing semantics" do
    operation =
      CompositionFixtures.order_document()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        status: "submitted",
        items: %{
          mode: :full_set,
          items: [
            %{id: 11, lock_version: 7, quantity: 3},
            %{client_id: "new-1", product_id: 5, quantity: 2, lock_version: 1}
          ]
        }
      })

    assert {:ok, %Graph{} = graph, _context} =
             SelectoUpdato.PortableCommand.compile(operation)

    items = Enum.find(graph.nodes, &(&1.id == "items"))
    assert items.strategy == :sync
    assert items.delete_missing?
    assert items.metadata.mutation_mode == :full_set
    assert Enum.map(items.rows, & &1.command.operation) == [:update, :insert]
  end

  test "Order full-set enforces cross-child uniqueness and the declared aggregate limit" do
    duplicate_product =
      order_update(%{
        mode: :full_set,
        items: [
          %{client_id: "new-1", product_id: 5, quantity: 2, lock_version: 1},
          %{client_id: "new-2", product_id: 5, quantity: 3, lock_version: 1}
        ]
      })

    assert {:error,
            %SelectoUpdato.Error{
              message: "nested relationship contains duplicate cross-child values",
              details: %{path: [:items, "client_id=new-2"], fields: ["product_id"]}
            }} = SelectoUpdato.PortableCommand.compile(duplicate_product)

    aggregate_overflow =
      order_update(%{
        mode: :full_set,
        items: [
          %{client_id: "new-1", product_id: 5, quantity: 60, lock_version: 1},
          %{client_id: "new-2", product_id: 6, quantity: 50, lock_version: 1}
        ]
      })

    assert {:error,
            %SelectoUpdato.Error{
              message: "nested aggregate exceeds its declared maximum",
              details: %{path: [:items], field: "quantity", maximum: 100, actual: 110}
            }} = SelectoUpdato.PortableCommand.compile(aggregate_overflow)
  end

  test "multi-field nested uniqueness uses the canonical tuple paths" do
    domain =
      CompositionFixtures.order_document()
      |> put_in(
        [:writes, :relationships, "items", :validation, :unique_fields],
        ["product_id", "quantity"]
      )

    allowed =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        status: "submitted",
        items: %{
          mode: :full_set,
          items: [
            %{client_id: "new-1", product_id: 5, quantity: 2, lock_version: 1},
            %{client_id: "new-2", product_id: 5, quantity: 3, lock_version: 1}
          ]
        }
      })

    assert {:ok, %Graph{}, _context} = SelectoUpdato.PortableCommand.compile(allowed)

    duplicate_changes = put_in(allowed.changes, [:items, :items, Access.at(1), :quantity], 2)
    duplicate = %{allowed | changes: duplicate_changes}

    assert {:error,
            %SelectoUpdato.Error{
              message: "nested relationship contains duplicate cross-child values",
              details: %{
                path: [:items, "client_id=new-2"],
                fields: ["product_id", "quantity"],
                values: [5, 2]
              }
            }} = SelectoUpdato.PortableCommand.compile(duplicate)
  end

  test "Order child field validation keeps the stable nested identity path" do
    operation =
      order_update(%{
        mode: :full_set,
        items: [%{client_id: "new-1", product_id: 5, quantity: 0, lock_version: 1}]
      })

    assert {:error, %SelectoUpdato.Error{} = error} =
             SelectoUpdato.PortableCommand.compile(operation)

    assert error.details.path == [:items, "client_id=new-1", "quantity"]
    assert inspect(error) =~ "quantity"
    assert inspect(error) =~ "client_id=new-1"
  end

  test "unknown nested validation concepts fail closed at compilation" do
    domain =
      CompositionFixtures.order_document()
      |> put_in(
        [:writes, :relationships, "items", :validation, :future_remote_rule],
        %{provider: "later"}
      )

    operation =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        status: "submitted",
        items: %{
          mode: :full_set,
          items: [%{client_id: "new-1", product_id: 5, quantity: 1, lock_version: 1}]
        }
      })

    assert {:error,
            %SelectoUpdato.Error{
              message: "nested relationship validation policy is unsupported",
              details: %{path: [:items], unsupported_keys: ["future_remote_rule"]}
            }} = SelectoUpdato.PortableCommand.compile(operation)
  end

  test "append-only requires temporary identity and cannot be confused with update/delete" do
    domain = CompositionFixtures.vehicle_inspection()

    missing_identity =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 10})
      |> SelectoUpdato.update(%{
        vin_snapshot: "VIN-1",
        photos: [%{photo_url: "https://example.test/photo.jpg"}]
      })

    assert {:error,
            %{
              type: :invalid_graph,
              details: %{client_identity_field: "client_id"}
            }} = SelectoUpdato.PortableCommand.compile(missing_identity)

    accepted =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 10})
      |> SelectoUpdato.update(%{
        vin_snapshot: "VIN-1",
        photos: [
          %{client_id: "photo-1", photo_url: "https://example.test/photo.jpg"}
        ]
      })

    assert {:ok, %Graph{} = graph, _context} = SelectoUpdato.PortableCommand.compile(accepted)
    photos = Enum.find(graph.nodes, &(&1.id == "photos"))
    assert photos.metadata.mutation_mode == :append_only
    assert [%{command: %{operation: :insert}, path: [:photos, "client_id=photo-1"]}] = photos.rows
  end

  test "replace-one allows exactly one explicit child intent" do
    domain = replace_one_domain()

    operation =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        status: "submitted",
        item: %{mode: :replace_one, update: %{id: 11, lock_version: 7, quantity: 4}}
      })

    assert {:ok, %Graph{} = graph, _context} = SelectoUpdato.PortableCommand.compile(operation)
    item = Enum.find(graph.nodes, &(&1.id == "item"))
    assert item.strategy == :ordered
    assert [%{command: %{operation: :update}, path: [:item]}] = item.rows

    ambiguous =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        status: "submitted",
        item: %{
          mode: :replace_one,
          create: %{client_id: "new", product_id: 5, quantity: 1},
          delete: %{id: 11, lock_version: 7}
        }
      })

    assert {:error, %{type: :invalid_graph, message: message}} =
             SelectoUpdato.PortableCommand.compile(ambiguous)

    assert message =~ "exactly one"
  end

  test "link-delta mutates only join rows and preserves the shared target lifecycle" do
    domain = link_delta_domain()

    operation =
      domain
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        status: "submitted",
        tags: %{
          mode: :link_delta,
          link: [%{tag_id: 8}],
          unlink: [%{tag_id: 9}]
        }
      })

    assert {:ok, %Graph{} = graph, _context} = SelectoUpdato.PortableCommand.compile(operation)
    tags = Enum.find(graph.nodes, &(&1.id == "tags"))

    assert tags.metadata.ownership == :join_association
    assert tags.metadata.mutation_mode == :link_delta
    assert Enum.map(tags.rows, & &1.metadata.semantic_operation) == [:link, :unlink]
    assert Enum.map(tags.rows, & &1.command.operation) == [:insert, :delete]
    assert Enum.all?(tags.rows, &(&1.command.relation == "order_tags"))
  end

  test "unknown and undeclared mutation modes fail instead of being reinterpreted" do
    operation =
      CompositionFixtures.order_document()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        status: "submitted",
        items: %{mode: :append_only, items: [%{client_id: "new", quantity: 1}]}
      })

    assert {:error,
            %{
              type: :invalid_graph,
              details: %{representation: :append_only, declared_modes: [:delta, :full_set]}
            }} = SelectoUpdato.PortableCommand.compile(operation)

    unknown =
      CompositionFixtures.order_document()
      |> SelectoUpdato.new(tenant: %{tenant_id: 7})
      |> SelectoUpdato.filter({:id, 42})
      |> SelectoUpdato.update(%{
        status: "submitted",
        items: %{mode: :surprise, create: [%{client_id: "new", quantity: 1}]}
      })

    assert {:error,
            %{
              type: :invalid_graph,
              details: %{representation: :surprise}
            }} = SelectoUpdato.PortableCommand.compile(unknown)
  end

  defp replace_one_domain do
    domain = CompositionFixtures.order_document()
    spec = get_in(domain, [:writes, :relationships, "items"])

    spec =
      spec
      |> Map.put(:cardinality, :one)
      |> put_in([:write, :modes], [:replace_one])
      |> put_in([:write, :omission], :unchanged)
      |> put_in([:write, :max_items], 1)
      |> put_in([:write, :max_mutations], 1)

    domain
    |> update_in([:writes, :relationships], fn _relationships -> %{"item" => spec} end)
  end

  defp link_delta_domain do
    root = CompositionFixtures.order_document()
    child = get_in(root, [:writes, :relationships, "items", :domain])

    join_domain =
      child
      |> put_in([:name], "order_tags")
      |> put_in([:source, :source_table], "order_tags")
      |> put_in([:source, :fields], ["order_id", "tag_id", "tenant_id"])
      |> put_in([:source, :columns], %{
        "order_id" => %{type: :integer},
        "tag_id" => %{type: :integer},
        "tenant_id" => %{type: :integer}
      })
      |> put_in([:source, :primary_key], "tag_id")
      |> put_in([:writes, :fields], %{"tag_id" => %{insertable: true}})
      |> put_in([:writes, :operations], %{
        insert: %{enabled: true, expected_cardinality: {:exactly, 1}},
        delete: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}}
      })
      |> update_in([:writes], &Map.delete(&1, :relationships))

    tags = %{
      ownership: :join_association,
      cardinality: :many,
      target: "tags",
      child_key: "order_id",
      identity_fields: ["tag_id"],
      domain: join_domain,
      read: %{allowed: true, default_depth: 1, max_depth: 1, max_rows: 100},
      write: %{
        modes: [:link_delta],
        link: true,
        unlink: true,
        omission: :unchanged,
        max_mutations: 20
      },
      tenant_scope: %{mode: :membership},
      capabilities: %{link: "order.tag.link", unlink: "order.tag.unlink"},
      conflict: %{},
      idempotency: %{request_key: true},
      offline: %{eligible: false}
    }

    put_in(root, [:writes, :relationships], %{"tags" => tags})
  end

  defp order_update(items) do
    CompositionFixtures.order_document()
    |> SelectoUpdato.new(tenant: %{tenant_id: 7})
    |> SelectoUpdato.filter({:id, 42})
    |> SelectoUpdato.update(%{status: "submitted", items: items})
  end

  defp assignment?(command, field) do
    Enum.any?(command.assignments, &(to_string(&1.field) == field))
  end

  defp predicate?(command, field, value) do
    command.predicate
    |> flatten_predicates()
    |> Enum.any?(fn
      {:eq, {:field, candidate}, {:literal, ^value}} -> to_string(candidate) == field
      _predicate -> false
    end)
  end

  defp flatten_predicates({:and, predicates}),
    do: Enum.flat_map(predicates, &flatten_predicates/1)

  defp flatten_predicates(predicate), do: [predicate]

  defp parent_binding?(row, field) do
    Enum.any?(row.bindings, &(to_string(&1.field) == field and &1.from_node == "root"))
  end
end
