defmodule SelectoUpdato.Verification.NestedCompositionSafety do
  @moduledoc """
  Bounded-exhaustive verification for the five general nested mutation
  representations.

  The finite model crosses representation, stable child identity, and a
  caller-supplied tenant override. It proves fail-closed identity and tenant
  handling, representation-preserving omission policy, stable paths, and
  atomic adapter-neutral graph construction. It does not prove arbitrary
  schemas, graph sizes, adapters, databases, callbacks, or concurrency.
  """

  alias Selecto.Domain.CompositionFixtures
  alias Selecto.Verification.BoundedModel
  alias Selecto.Write.Graph

  @modes [:append_only, :delta, :full_set, :replace_one, :link_delta]

  @spec verify() :: BoundedModel.report()
  def verify do
    BoundedModel.check("selecto_updato.nested_composition.v1", states(), [
      {"identity_and_tenant_fail_closed", &identity_and_tenant_fail_closed/1},
      {"valid_representations_compile_atomically", &valid_representations_compile/1},
      {"omission_policy_is_not_reinterpreted", &omission_policy_is_preserved/1},
      {"semantic_paths_are_stable", &semantic_paths_are_stable/1}
    ])
  end

  @doc false
  def states do
    for mode <- @modes,
        identity? <- [false, true],
        tenant_override? <- [false, true] do
      operation = operation(mode, identity?, tenant_override?)

      %{
        mode: mode,
        identity?: identity?,
        tenant_override?: tenant_override?,
        result: SelectoUpdato.PortableCommand.compile(operation)
      }
    end
  end

  defp identity_and_tenant_fail_closed(state) do
    expected_valid? = state.identity? and not state.tenant_override?

    case {expected_valid?, state.result} do
      {true, {:ok, %Graph{}, _context}} -> :ok
      {false, {:error, %SelectoUpdato.Error{}}} -> :ok
      _other -> {:error, %{expected_valid?: expected_valid?, actual: state.result}}
    end
  end

  defp valid_representations_compile(state) do
    if state.identity? and not state.tenant_override? do
      case state.result do
        {:ok, %Graph{atomic?: true} = graph, %{tenant_id: 7}} -> Graph.validate(graph)
        other -> {:error, %{expected_atomic_graph: other}}
      end
    else
      :ok
    end
  end

  defp omission_policy_is_preserved(state) do
    with true <- state.identity? and not state.tenant_override?,
         {:ok, %Graph{} = graph, _context} <- state.result,
         child when not is_nil(child) <- Enum.find(graph.nodes, &(&1.id != "root")) do
      expected_delete_missing? = state.mode == :full_set

      if child.delete_missing? == expected_delete_missing?,
        do: :ok,
        else: {:error, %{expected: expected_delete_missing?, actual: child.delete_missing?}}
    else
      false -> :ok
      other -> {:error, %{unexpected_graph: other}}
    end
  end

  defp semantic_paths_are_stable(state) do
    with true <- state.identity? and not state.tenant_override?,
         {:ok, %Graph{} = graph, _context} <- state.result,
         child when not is_nil(child) <- Enum.find(graph.nodes, &(&1.id != "root")),
         [row] <- child.rows do
      path = Enum.map(row.path, &to_string/1)

      stable? =
        if state.mode == :replace_one do
          path == [child.id]
        else
          length(path) == 2 and String.contains?(List.last(path), "=")
        end

      if stable?,
        do: :ok,
        else: {:error, %{unstable_path: row.path}}
    else
      false -> :ok
      other -> {:error, %{unexpected_graph: other}}
    end
  end

  defp operation(mode, identity?, tenant_override?) do
    {domain, relationship, root_field, payload} = fixture(mode, identity?)
    payload = maybe_tenant_override(payload, mode, tenant_override?)

    domain
    |> SelectoUpdato.new(tenant: %{tenant_id: 7})
    |> SelectoUpdato.filter({:id, 42})
    |> SelectoUpdato.update(%{root_field => "changed", relationship => payload})
  end

  defp fixture(:append_only, identity?) do
    domain =
      CompositionFixtures.order_document()
      |> put_in([:writes, :relationships, "items", :write, :modes], [:append_only])
      |> put_in([:writes, :relationships, "items", :write, :update], false)
      |> put_in([:writes, :relationships, "items", :write, :delete], false)
      |> put_in([:writes, :relationships, "items", :write, :omission], :unchanged)

    item =
      %{product_id: 5, quantity: 2, lock_version: 1}
      |> maybe_put(identity?, :client_id, "new-1")

    {domain, :items, :status, %{mode: :append_only, items: [item]}}
  end

  defp fixture(:delta, identity?) do
    item =
      %{quantity: 3, lock_version: 7}
      |> maybe_put(identity?, :id, 11)

    {CompositionFixtures.order_document(), :items, :status,
     %{mode: :delta, create: [], update: [item], delete: []}}
  end

  defp fixture(:full_set, identity?) do
    item =
      %{product_id: 5, quantity: 3, lock_version: 7}
      |> maybe_put(identity?, :id, 11)

    {CompositionFixtures.order_document(), :items, :status, %{mode: :full_set, items: [item]}}
  end

  defp fixture(:replace_one, identity?) do
    domain =
      CompositionFixtures.order_document()
      |> put_in([:writes, :relationships, "items", :cardinality], :one)
      |> put_in([:writes, :relationships, "items", :write, :modes], [:replace_one])
      |> put_in([:writes, :relationships, "items", :write, :omission], :unchanged)
      |> put_in([:writes, :relationships, "items", :write, :min_items], 0)
      |> put_in([:writes, :relationships, "items", :write, :max_items], 1)
      |> put_in([:writes, :relationships, "items", :write, :max_mutations], 1)

    item =
      %{quantity: 3, lock_version: 7}
      |> maybe_put(identity?, :id, 11)

    {domain, :items, :status, %{mode: :replace_one, update: item}}
  end

  defp fixture(:link_delta, identity?) do
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

    domain = put_in(root, [:writes, :relationships], %{"tags" => tags})

    item = %{} |> maybe_put(identity?, :tag_id, 8)
    {domain, :tags, :status, %{mode: :link_delta, link: [item], unlink: []}}
  end

  defp maybe_tenant_override(payload, _mode, false), do: payload

  defp maybe_tenant_override(payload, mode, true) do
    key = if mode == :link_delta, do: :link, else: representation_key(mode)

    if mode == :replace_one do
      update_in(payload, [key], &Map.put(&1, :tenant_id, 99))
    else
      update_in(payload, [key, Access.at(0)], &Map.put(&1, :tenant_id, 99))
    end
  end

  defp representation_key(:append_only), do: :items
  defp representation_key(:delta), do: :update
  defp representation_key(:full_set), do: :items
  defp representation_key(:replace_one), do: :update

  defp maybe_put(map, true, key, value), do: Map.put(map, key, value)
  defp maybe_put(map, false, _key, _value), do: map
end
