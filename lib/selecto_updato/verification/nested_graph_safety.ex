defmodule SelectoUpdato.Verification.NestedGraphSafety do
  @moduledoc """
  Bounded verification of portable nested-write graph invariants.

  The model crosses root operation, tenant context, declared relationship
  policy, and attempted ownership-key override. It proves that invalid states
  fail before adapter dispatch and valid states preserve atomicity, topology,
  tenant scope, generated ownership, sync identity, and adapter neutrality.
  """

  alias Selecto.Verification.BoundedModel
  alias Selecto.Write.Graph
  alias Selecto.Write.Graph.Binding

  @spec verify() :: BoundedModel.report()
  def verify do
    BoundedModel.check("selecto_updato.nested_graph.v1", states(), invariants())
  end

  @doc false
  def states do
    for operation <- [:insert, :update],
        tenant? <- [false, true],
        relationship_policy <- [:absent, :valid, :invalid_child_key],
        ownership_override? <- [false, true] do
      domain = relationship_domain(relationship_policy)

      child =
        %{name: "child"}
        |> maybe_put(operation == :update, :id, 11)
        |> maybe_put(ownership_override?, :parent_id, 99)

      updato =
        domain
        |> SelectoUpdato.new()
        |> build_operation(operation, %{name: "parent", children: [child]})
        |> maybe_tenant(tenant?)

      %{
        operation: operation,
        tenant?: tenant?,
        relationship_policy: relationship_policy,
        ownership_override?: ownership_override?,
        result: SelectoUpdato.PortableCommand.compile(updato)
      }
    end
  end

  defp invariants do
    [
      {"invalid_states_fail_closed", &invalid_states_fail_closed/1},
      {"valid_states_compile_atomic_graphs", &valid_states_compile_atomic_graphs/1},
      {"generated_ownership_is_topological", &generated_ownership_is_topological/1},
      {"tenant_scope_covers_every_row", &tenant_scope_covers_every_row/1},
      {"sync_identity_and_delete_policy_are_preserved", &sync_policy_is_preserved/1},
      {"graph_is_adapter_neutral", &graph_is_adapter_neutral/1}
    ]
  end

  defp invalid_states_fail_closed(state) do
    if valid_state?(state) or match?({:error, %SelectoUpdato.Error{}}, state.result),
      do: :ok,
      else: {:error, %{unexpected_result: state.result}}
  end

  defp valid_states_compile_atomic_graphs(state) do
    if not valid_state?(state) do
      :ok
    else
      case state.result do
        {:ok, %Graph{atomic?: true} = graph, %{tenant_id: "tenant-a"}} ->
          case Graph.validate(graph) do
            :ok -> :ok
            error -> {:error, %{invalid_graph: error}}
          end

        other ->
          {:error, %{expected_atomic_graph: other}}
      end
    end
  end

  defp generated_ownership_is_topological(state) do
    with true <- valid_state?(state),
         {:ok, %Graph{nodes: [_root, child]}, _context} <- state.result,
         [row] <- child.rows,
         [%Binding{} = binding] <- row.bindings do
      assigned? =
        Enum.any?(row.command.assignments, &(to_string(&1.field) == "parent_id"))

      if binding.field == :parent_id and binding.from_node == "root" and not assigned?,
        do: :ok,
        else: {:error, %{binding: binding, caller_assignment?: assigned?}}
    else
      false -> :ok
      other -> {:error, %{unexpected_graph: other}}
    end
  end

  defp tenant_scope_covers_every_row(state) do
    with true <- valid_state?(state),
         {:ok, %Graph{} = graph, _context} <- state.result do
      scoped? =
        Enum.all?(graph.nodes, fn node ->
          Enum.all?(node.rows, fn row ->
            tenant_assignment?(row.command) or tenant_predicate?(row.command.predicate)
          end)
        end)

      if scoped?, do: :ok, else: {:error, %{unscoped_graph: graph}}
    else
      false -> :ok
      other -> {:error, %{unexpected_graph: other}}
    end
  end

  defp sync_policy_is_preserved(%{operation: :update} = state) do
    with true <- valid_state?(state),
         {:ok, %Graph{nodes: [_root, child]}, _context} <- state.result do
      cond do
        child.strategy != :sync ->
          {:error, %{strategy: child.strategy}}

        child.identity_fields != [:id] ->
          {:error, %{identity_fields: child.identity_fields}}

        not child.delete_missing? ->
          {:error, %{delete_missing?: false}}

        hd(child.rows).command.returning != [:id] ->
          {:error, %{returning: hd(child.rows).command.returning}}

        true ->
          :ok
      end
    else
      false -> :ok
      other -> {:error, %{unexpected_graph: other}}
    end
  end

  defp sync_policy_is_preserved(_state), do: :ok

  defp graph_is_adapter_neutral(state) do
    case state.result do
      {:ok, %Graph{} = graph, _context} ->
        encoded = inspect(graph)

        forbidden =
          Enum.filter(
            ["adapter:", "connection:", "repo:", "driver:", "dialect:"],
            &String.contains?(encoded, &1)
          )

        if forbidden == [], do: :ok, else: {:error, %{adapter_terms: forbidden}}

      {:error, _error} ->
        :ok
    end
  end

  defp valid_state?(state) do
    state.tenant? and state.relationship_policy == :valid and not state.ownership_override?
  end

  defp build_operation(operation, :insert, attrs), do: SelectoUpdato.insert(operation, attrs)

  defp build_operation(operation, :update, attrs) do
    operation |> SelectoUpdato.update(attrs) |> SelectoUpdato.filter({:id, 42})
  end

  defp maybe_tenant(operation, true),
    do: SelectoUpdato.with_tenant(operation, %{tenant_id: "tenant-a"})

  defp maybe_tenant(operation, false), do: operation
  defp maybe_put(map, true, key, value), do: Map.put(map, key, value)
  defp maybe_put(map, false, _key, _value), do: map

  defp tenant_assignment?(command) do
    Enum.any?(command.assignments, fn assignment ->
      to_string(assignment.field) == "tenant_id" and
        assignment.value == {:literal, "tenant-a"}
    end)
  end

  defp tenant_predicate?({:and, predicates}), do: Enum.any?(predicates, &tenant_predicate?/1)

  defp tenant_predicate?({:eq, {:field, field}, {:literal, "tenant-a"}}),
    do: to_string(field) == "tenant_id"

  defp tenant_predicate?(_predicate), do: false

  defp remove_relationship(domain), do: put_in(domain, [:writes, :relationships], %{})

  defp relationship_domain(:absent), do: remove_relationship(parent_domain())
  defp relationship_domain(:valid), do: parent_domain()

  defp relationship_domain(:invalid_child_key) do
    put_in(parent_domain(), [:writes, :relationships, :children, :child_key], :missing_parent_id)
  end

  defp parent_domain do
    child = domain("children", [:id, :tenant_id, :parent_id, :name])

    domain("parents", [:id, :tenant_id, :name])
    |> put_in([:writes, :relationships], %{
      children: %{
        writable: true,
        cardinality: :many,
        ownership: :owned,
        allowed_ops: [:insert, :update, :delete],
        domain: child,
        child_key: :parent_id,
        identity_fields: [:id],
        strategy: :sync,
        delete_missing: true
      }
    })
  end

  defp domain(relation, fields) do
    %{
      source: %{
        source_table: relation,
        primary_key: :id,
        fields: fields,
        columns: Map.new(fields, &{&1, %{type: :string}}),
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true, expected_cardinality: {:exactly, 1}},
          update: %{enabled: true, expected_cardinality: {:exactly, 1}, require_filter: true}
        },
        fields: %{
          tenant_id: %{insertable: true, immutable: true},
          name: %{insertable: true, updatable: true, required_on: [:insert]}
        },
        scope: %{tenant: %{required: true, field: :tenant_id}},
        relationships: %{}
      }
    }
  end
end
