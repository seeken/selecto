defmodule SelectoUpdato.TrustedScopeBindingTest do
  # w3exrev15: a trusted context's required filters bind every graph child
  # that has the field (pre-image and post-image), a child that cannot be
  # bound refuses the graph, and no compile option exempts a command from
  # them. A required filter pinning the declared tenant column bounds the
  # post-image; a nil pin is IS NULL; a tenant upsert carries a post-image.
  use ExUnit.Case, async: true

  alias Selecto.Write.{Command, Graph}
  alias Selecto.Write.Graph.{Node, Row}
  alias SelectoUpdato.{PortableCommand, Tenant}

  @pin [{"site", "S1"}]

  defp item(fields \\ [:id, :tenant_id, :order_id, :sku, :site]) do
    %{
      name: "g_items",
      source: %{
        source_table: "g_items",
        primary_key: :id,
        tenant_field: :tenant_id,
        fields: fields,
        columns:
          Map.new(fields, &{&1, %{type: if(&1 in [:id, :order_id], do: :integer, else: :string)}}),
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
          %{
            tenant_id: %{insertable: true, immutable: true},
            sku: %{insertable: true, updatable: true},
            order_id: %{insertable: true}
          }
          |> then(
            &if(:site in fields,
              do: Map.put(&1, :site, %{insertable: true, updatable: true}),
              else: &1
            )
          ),
        scope: %{tenant: %{required: true, field: :tenant_id}},
        relationships: %{}
      }
    }
  end

  defp order(item) do
    %{
      name: "g_orders",
      source: %{
        source_table: "g_orders",
        primary_key: :id,
        tenant_field: :tenant_id,
        fields: [:id, :tenant_id, :reference, :site],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :string},
          reference: %{type: :string},
          site: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true, expected_cardinality: {:exactly, 1}},
          update: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}}
        },
        fields: %{
          tenant_id: %{insertable: true, immutable: true},
          reference: %{insertable: true, updatable: true},
          site: %{insertable: true, updatable: true}
        },
        scope: %{tenant: %{required: true, field: :tenant_id}},
        relationships: %{
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
        }
      }
    }
  end

  defp context(pin \\ @pin), do: %{tenant_id: "T7", required_filters: pin}

  defp run(domain, build, ctx \\ context()) do
    domain
    |> SelectoUpdato.new(tenant: ctx)
    |> build.()
    |> Tenant.apply_execution_scope(context: ctx)
    |> PortableCommand.compile(context: ctx)
  end

  defp conjuncts(nil), do: []
  defp conjuncts({:and, predicates}), do: Enum.flat_map(predicates, &conjuncts/1)
  defp conjuncts(predicate), do: [predicate]

  defp assignment(%Command{assignments: assignments}, field) do
    Enum.find_value(assignments, fn
      %{field: f, value: {:literal, value}} -> if to_string(f) == field, do: value
      _ -> nil
    end)
  end

  defp child_rows(%Graph{nodes: nodes}),
    do: nodes |> Enum.find(&(&1.id == "items")) |> then(fn %Node{rows: rows} -> rows end)

  @site {:eq, {:field, "site"}, {:literal, "S1"}}

  test "a graph child with the field is bound to the trusted pin, pre-image and post-image" do
    insert = fn child ->
      run(
        order(item()),
        &SelectoUpdato.insert(&1, %{reference: "SO", site: "S1", items: [child]})
      )
    end

    # The insert guard (re-read after the statement) carries the pin, so a
    # child stored outside it rolls the graph back.
    for child <- [%{sku: "W", site: "S2"}, %{sku: "W", site: "S1"}] do
      assert {:ok, %Graph{} = graph, _} = insert.(child)
      assert [%Row{command: command}] = child_rows(graph)
      assert assignment(command, "site") == child.site
      assert @site in conjuncts(command.metadata.post_image.predicate)
    end

    # A child that omits the field is not given one; its guard still holds.
    assert {:ok, %Graph{} = graph, _} = insert.(%{sku: "W"})
    assert [%Row{command: child}] = child_rows(graph)
    assert assignment(child, "site") == nil
    assert @site in conjuncts(child.metadata.post_image.predicate)

    assert {:ok, %Graph{} = graph, _} =
             run(
               order(item()),
               &(&1
                 |> SelectoUpdato.filters([{"id", 50}])
                 |> SelectoUpdato.update(%{
                   reference: "SO2",
                   items: [%{id: 60, sku: "W2", site: "S9"}]
                 }))
             )

    assert [%Row{command: %Command{operation: :update} = child}] = child_rows(graph)
    assert @site in conjuncts(child.predicate)
    assert @site in conjuncts(child.metadata.post_image.predicate)
  end

  test "the root's tenant context alone binds the children" do
    compile = fn domain, attrs ->
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.with_tenant(context())
      |> SelectoUpdato.insert(attrs)
      |> Tenant.apply_execution_scope()
      |> PortableCommand.compile()
    end

    assert {:ok, %Graph{} = graph, _} =
             compile.(order(item()), %{reference: "SO", site: "S1", items: [%{sku: "W"}]})

    assert [%Row{command: child}] = child_rows(graph)
    assert @site in conjuncts(child.metadata.post_image.predicate)

    assert {:error, %{details: %{code: :trusted_scope_unbound_child}}} =
             compile.(order(item([:id, :tenant_id, :order_id, :sku])), %{
               reference: "SO",
               site: "S1",
               items: [%{sku: "W"}]
             })
  end

  test "a sync node under a bound scope marks its cleanup for the delete contract" do
    # w3exrev17 HIGH 1.
    sync =
      &(&1
        |> SelectoUpdato.filters([{"id", 50}])
        |> SelectoUpdato.update(%{reference: "SO2", items: [%{id: 60, sku: "W2"}]}))

    for ctx <- [context(), %{tenant_id: "T7"}] do
      assert {:ok, %Graph{} = graph, _} = run(order(item()), sync, ctx)

      assert %Node{delete_missing?: true, metadata: metadata} =
               Enum.find(graph.nodes, &(&1.id == "items"))

      assert metadata.bound_scope == true, inspect(ctx)
    end
  end

  test "a graph child that cannot be bound to the trusted pin refuses the graph" do
    domain = order(item([:id, :tenant_id, :order_id, :sku]))

    assert {:error, %{details: %{code: :trusted_scope_unbound_child, fields: ["site"]}}} =
             run(
               domain,
               &SelectoUpdato.insert(&1, %{reference: "SO", site: "S1", items: [%{sku: "W"}]})
             )

    # Without a pin the same graph compiles.
    assert {:ok, %Graph{}, _} =
             run(
               domain,
               &SelectoUpdato.insert(&1, %{reference: "SO", items: [%{sku: "W"}]}),
               %{tenant_id: "T7"}
             )
  end

  test "no compile option exempts a command from unapplied trusted filters" do
    domain = %{
      name: "rq",
      source: %{
        source_table: "rq",
        primary_key: :id,
        fields: [:id, :site, :name],
        columns: %{id: %{type: :integer}, site: %{type: :string}, name: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: %{id: %{insertable: true}, site: %{insertable: true}, name: %{insertable: true}}
      }
    }

    operation =
      domain |> SelectoUpdato.new() |> SelectoUpdato.insert(%{id: 1, site: "S2", name: "n"})

    for opts <- [[], [record_state_ownership: %{}], [record_state_ownership: %{node: "items"}]] do
      assert {:error, %{details: %{code: :trusted_required_filters_unapplied}}} =
               PortableCommand.compile(operation, [required_filters: @pin] ++ opts)
    end
  end

  defp flat(opts) do
    %{
      name: "TW",
      source:
        %{
          source_table: "tw",
          primary_key: :id,
          fields: [:id, :org_key, :site, :status, :name],
          columns: %{
            id: %{type: :integer},
            org_key: %{type: :string},
            site: %{type: :string},
            status: %{type: :string},
            name: %{type: :string}
          },
          associations: %{}
        }
        |> then(&if(opts[:tenant_field], do: Map.put(&1, :tenant_field, :org_key), else: &1)),
      schemas: %{},
      joins: %{},
      required_filters: Keyword.get(opts, :required, []),
      writes:
        %{
          operations: %{
            insert: %{enabled: true},
            update: %{enabled: true},
            upsert: %{enabled: true, conflict_targets: [[:org_key, :id]]}
          },
          fields:
            Map.new(
              [:id, :org_key, :site, :status, :name],
              &{&1, %{insertable: true, updatable: &1 != :id}}
            )
        }
        |> then(
          &if(opts[:scope_field],
            do: Map.put(&1, :scope, %{tenant: %{required: true, field: :org_key}}),
            else: &1
          )
        )
    }
  end

  @catalog %{
    "tw" =>
      Map.new(~w(org_key site status name), &{&1, %{type: "text"}})
      |> Map.put("id", %{type: "integer"})
  }

  defp compile_flat(operation, opts \\ []) do
    operation
    |> Tenant.apply_execution_scope(opts)
    |> PortableCommand.compile(Keyword.put(opts, :column_metadata, @catalog))
  end

  defp post_image({:ok, %Command{metadata: metadata}, _}), do: Map.get(metadata, :post_image)

  test "a required filter pinning the declared tenant column bounds the post-image" do
    org = {:eq, {:field, "org_key"}, {:literal, "T1"}}
    update = &(&1 |> SelectoUpdato.filter({:id, 1}) |> SelectoUpdato.update(%{name: "u"}))

    image =
      flat(required: [{"org_key", "T1"}], tenant_field: true)
      |> SelectoUpdato.new()
      |> update.()
      |> compile_flat()
      |> post_image()

    assert org in conjuncts(image && image.predicate)

    # A plain required filter stays pre-image only.
    assert flat(required: [{"status", "open"}], tenant_field: true)
           |> SelectoUpdato.new()
           |> update.()
           |> compile_flat()
           |> post_image() == nil

    # Pinning a column that is not the tenant column does not count.
    assert flat(required: [{"site", "S1"}], tenant_field: true)
           |> SelectoUpdato.new()
           |> update.()
           |> compile_flat()
           |> post_image() == nil
  end

  test "any required filter reading the tenant column, in any shape, bounds the post-image" do
    # w3exrev16 items 10/10a: fail-closed, any depth, any operator.
    t = "org_key"
    update = &(&1 |> SelectoUpdato.filter({:id, 1}) |> SelectoUpdato.update(%{name: "u"}))

    tenant_pins = [
      {t, "T1"},
      {:or, [{t, "T1"}]},
      {:not, {t, {"!=", "T1"}}},
      {:and, [{t, {:gte, "T1"}}, {t, {:lte, "T1"}}]},
      {t, {:in, ["T1"]}},
      {:and, [{:and, [{t, "T1"}]}]},
      {:or, [{t, "T1"}, {"status", "zz"}]},
      {:or, [{:and, [{t, "T1"}, {"status", {"!=", "zz"}}]}]},
      {:not, {:or, [{t, {"!=", "T1"}}, {"status", "zz"}]}},
      {:and, [{t, "T1"}, {"status", "open"}]}
    ]

    for pin <- tenant_pins do
      image =
        flat(required: [pin], tenant_field: true)
        |> SelectoUpdato.new()
        |> update.()
        |> compile_flat()
        |> post_image()

      assert image, inspect(pin)
      assert inspect(image.predicate) =~ ~s({:field, "org_key"}), inspect(pin)
    end

    # The two halves of a range given as separate filters both join.
    image =
      flat(required: [{t, {:gte, "T1"}}, {t, {:lte, "T1"}}], tenant_field: true)
      |> SelectoUpdato.new()
      |> update.()
      |> compile_flat()
      |> post_image()

    assert length(conjuncts(image.predicate)) == 2

    # Filters that never read the tenant column stay pre-image only.
    for pin <- [
          {"status", "open"},
          {:or, [{"status", "open"}, {"site", "S1"}]},
          {:not, {"site", "S9"}}
        ] do
      assert flat(required: [pin], tenant_field: true)
             |> SelectoUpdato.new()
             |> update.()
             |> compile_flat()
             |> post_image() == nil,
             inspect(pin)
    end
  end

  test "a delete under a bound scope is marked for the adapter's trigger check" do
    # w3exp5 item 17.
    with_delete = fn domain ->
      put_in(domain, [:writes, :operations, :delete], %{
        enabled: true,
        bulk: true,
        expected_cardinality: :many
      })
    end

    delete = &(&1 |> SelectoUpdato.filter({:name, "a"}) |> SelectoUpdato.delete())

    bound = fn domain, opts ->
      assert {:ok, %Command{operation: :delete, metadata: metadata}, _} =
               domain |> with_delete.() |> SelectoUpdato.new() |> delete.() |> compile_flat(opts)

      Map.get(metadata, :bound_scope)
    end

    assert bound.(flat([]), required_filters: [{"site", "S1"}]) == true
    assert bound.(flat(required: [{"org_key", "T1"}], tenant_field: true), []) == true
    # Any query enforcement (a plain required filter included) counts: the
    # trigger acts on rows the delete's guard excludes.
    assert bound.(flat(required: [{"status", "open"}]), []) == true
    assert bound.(flat([]), []) == nil
  end

  test "a nil trusted pin is IS NULL in the pre-image and the post-image" do
    is_null = {:is_null, {:field, "site"}}

    assert {:ok, %Command{predicate: predicate, metadata: %{post_image: image}}, _} =
             flat([])
             |> SelectoUpdato.new()
             |> SelectoUpdato.filter({:id, 1})
             |> SelectoUpdato.update(%{name: "u"})
             |> compile_flat(required_filters: [{"site", nil}])

    assert is_null in conjuncts(predicate)
    assert is_null in conjuncts(image.predicate)
    refute Enum.any?(conjuncts(image.predicate), &match?({:eq, {:field, "site"}, _}, &1))
  end

  test "an upsert under the engine tenant carries a post-image" do
    assert {:ok, %Command{operation: :upsert, metadata: %{post_image: image}}, _} =
             flat(tenant_field: true, scope_field: true)
             |> SelectoUpdato.new(tenant: %{tenant_id: "T1"})
             |> SelectoUpdato.upsert(%{id: 3, org_key: "T1", name: "n"})
             |> SelectoUpdato.conflict_target([:org_key, :id])
             |> compile_flat(context: %{tenant_id: "T1"})

    assert image.key == ["id"]
    assert {:eq, {:field, "org_key"}, {:literal, "T1"}} in conjuncts(image.predicate)
  end
end
