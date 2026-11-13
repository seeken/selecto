defmodule SelectoUpdato.GraphBoundPropagationTest do
  # w3exrev18 item 33: bound status flows from the root (engine tenant, QE)
  # to every descendant node and delete row at every depth.
  use ExUnit.Case, async: true

  alias Selecto.Write.Graph
  alias SelectoUpdato.{PortableCommand, Tenant}

  defp mk(table, tenant?, fks, rels, ops) do
    fields = [:id] ++ if(tenant?, do: [:tenant_id], else: []) ++ fks ++ [:note]

    source =
      %{
        source_table: table,
        primary_key: :id,
        fields: fields,
        columns:
          Map.new(fields, &{&1, %{type: if(&1 == :id or &1 in fks, do: :integer, else: :string)}}),
        associations: %{}
      }
      |> then(&if(tenant?, do: Map.put(&1, :tenant_field, :tenant_id), else: &1))

    fields_spec =
      fks
      |> Map.new(&{&1, %{insertable: true}})
      |> Map.put(:note, %{insertable: true, updatable: true})
      |> then(
        &if(tenant?, do: Map.put(&1, :tenant_id, %{insertable: true, immutable: true}), else: &1)
      )

    writes =
      %{operations: ops, fields: fields_spec, relationships: rels}
      |> then(
        &if(tenant?,
          do: Map.put(&1, :scope, %{tenant: %{required: true, field: :tenant_id}}),
          else: &1
        )
      )

    %{name: table, source: source, schemas: %{}, joins: %{}, writes: writes}
  end

  @child_ops %{
    insert: %{enabled: true, expected_cardinality: {:exactly, 1}},
    update: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}},
    delete: %{enabled: true}
  }
  @root_ops %{update: %{enabled: true, require_filter: true, expected_cardinality: {:exactly, 1}}}

  defp rel(domain, key, extra),
    do:
      Map.merge(
        %{
          writable: true,
          cardinality: :many,
          ownership: :owned,
          allowed_ops: [:insert, :update, :delete],
          domain: domain,
          child_key: key,
          parent_key: :id,
          strategy: :sync,
          identity_fields: [:id],
          delete_missing: true
        },
        extra
      )

  defp bound?(%Graph{nodes: [_root | children]}) do
    Enum.all?(children, &(&1.metadata[:bound_scope] == true)) and
      Enum.all?(Enum.flat_map(children, & &1.rows), &(&1.command.metadata[:bound_scope] == true))
  end

  test "a tenant root's delta delete on a child without a tenant field is bound" do
    gi = mk("gi", false, [:order_id], %{}, @child_ops)

    delta = %{
      delete_missing: false,
      write: %{modes: [:delta], create: true, update: true, delete: true}
    }

    go = mk("go", true, [], %{items: rel(gi, :order_id, delta)}, @root_ops)
    ctx = %{tenant_id: "T7"}

    assert {:ok, %Graph{} = graph, _} =
             go
             |> SelectoUpdato.new(tenant: ctx)
             |> SelectoUpdato.filters([{"id", 50}])
             |> SelectoUpdato.update(%{note: "SO2", items: %{mode: :delta, delete: [%{id: 61}]}})
             |> Tenant.apply_execution_scope(context: ctx)
             |> PortableCommand.compile(context: ctx)

    assert Enum.any?(Enum.flat_map(graph.nodes, & &1.rows), &(&1.command.operation == :delete))
    assert bound?(graph)
  end

  test "a QE root binds a grandchild's cleanup node" do
    gg = mk("gg", false, [:item_id], %{}, @child_ops)
    gi = mk("gi", false, [:order_id], %{parts: rel(gg, :item_id, %{})}, @child_ops)
    go = mk("go", false, [], %{items: rel(gi, :order_id, %{delete_missing: false})}, @root_ops)

    host = %Selecto{
      domain: go,
      set: %{
        selected: [],
        filtered: [{"note", "SO"}],
        required_filters: [],
        post_retarget_filters: [],
        order_by: [],
        group_by: []
      }
    }

    assert {:ok, %Graph{} = graph, _} =
             go
             |> SelectoUpdato.new()
             |> SelectoUpdato.filters([{"id", 50}])
             |> SelectoUpdato.update(%{
               note: "SO",
               items: [%{id: 60, note: "k", parts: [%{id: 70, note: "k"}]}]
             })
             |> SelectoUpdato.enforce_query(host)
             |> PortableCommand.compile()

    assert Enum.find(graph.nodes, &String.ends_with?(&1.id, "parts")).delete_missing?
    assert bound?(graph)
  end
end
