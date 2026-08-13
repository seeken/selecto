defmodule Selecto.Verification.WriteCapabilitySafety do
  @moduledoc """
  Finite model for versioned write-capability preflight.

  The model enumerates five adapter profiles against six command, batch, and
  graph requirement shapes. It proves only this finite dispatch boundary; it
  does not prove driver, SQL, transaction, or database behavior.
  """

  alias Selecto.Verification.BoundedModel
  alias Selecto.Write.{Batch, Capabilities, Command, Graph}
  alias Selecto.Write.Graph.{Binding, Node, Row}

  @profiles [:full, :no_returning, :flat_only, :missing_version, :wrong_version]
  @shapes [:insert, :insert_returning, :update, :batch, :graph, :generated_graph]

  @spec verify() :: BoundedModel.report()
  def verify do
    BoundedModel.check("selecto.write_capability_preflight.v1", states(), [
      {"dispatch_matches_independent_matrix", &dispatch_matches?/1},
      {"missing_semantics_fail_closed", &missing_semantics_fail_closed?/1},
      {"protocol_mismatch_never_dispatches", &protocol_mismatch_never_dispatches?/1}
    ])
  end

  @doc false
  def states do
    for profile <- @profiles, shape <- @shapes do
      %{
        profile: profile,
        shape: shape,
        capabilities: capabilities(profile),
        write: write(shape),
        expected?: expected?(profile, shape)
      }
    end
  end

  defp dispatch_matches?(state),
    do: success?(Capabilities.require(state.capabilities, state.write)) == state.expected?

  defp missing_semantics_fail_closed?(%{expected?: true}), do: true

  defp missing_semantics_fail_closed?(state) do
    match?(
      {:error, %Selecto.Write.Error{}},
      Capabilities.require(state.capabilities, state.write)
    )
  end

  defp protocol_mismatch_never_dispatches?(%{profile: profile} = state)
       when profile in [:missing_version, :wrong_version],
       do: not success?(Capabilities.require(state.capabilities, state.write))

  defp protocol_mismatch_never_dispatches?(_state), do: true

  defp success?(:ok), do: true
  defp success?(_result), do: false

  defp expected?(:full, _shape), do: true
  defp expected?(:no_returning, shape), do: shape in [:insert, :update, :batch, :graph]
  defp expected?(:flat_only, shape), do: shape in [:insert, :update]
  defp expected?(_invalid_protocol, _shape), do: false

  defp capabilities(:full),
    do: base_capabilities() |> Map.merge(%{returning: true, generated_keys: :returning})

  defp capabilities(:no_returning), do: base_capabilities()

  defp capabilities(:flat_only),
    do: %{protocol_version: 1, insert: true, update: true, returning: false}

  defp capabilities(:missing_version), do: Map.delete(base_capabilities(), :protocol_version)
  defp capabilities(:wrong_version), do: %{base_capabilities() | protocol_version: 99}

  defp base_capabilities,
    do: %{
      protocol_version: 1,
      insert: true,
      update: true,
      delete: true,
      upsert: true,
      transactions: true,
      atomic_batch: true,
      write_graph: true,
      returning: false,
      generated_keys: false
    }

  defp write(:insert), do: command!(:insert)
  defp write(:insert_returning), do: %{command!(:insert) | returning: [:id]}
  defp write(:update), do: command!(:update)

  defp write(:batch) do
    {:ok, batch} = Batch.new([command!(:insert), command!(:update)])
    batch
  end

  defp write(:graph), do: graph(false)
  defp write(:generated_graph), do: graph(true)

  defp graph(generated?) do
    root_command =
      if generated?, do: %{command!(:insert) | returning: [:id]}, else: command!(:insert)

    child_row = %Row{
      id: "child",
      path: [:children, 0],
      command: %{command!(:insert) | relation: :children},
      bindings:
        if(generated?,
          do: [
            %Binding{
              field: :parent_id,
              from_node: "root",
              from_row: "root",
              from_field: :id
            }
          ],
          else: []
        )
    }

    nodes = [
      %Node{
        id: "root",
        path: [],
        relation: :items,
        strategy: :ordered,
        rows: [%Row{id: "root", path: [], command: root_command}]
      },
      %Node{
        id: "children",
        path: [:children],
        relation: :children,
        strategy: :ordered,
        rows: [child_row]
      }
    ]

    {:ok, graph} = Graph.new(nodes, {"root", "root"}, metadata: %{root_returning: :none})
    graph
  end

  defp command!(operation) do
    {:ok, command} =
      Command.new(%{
        operation: operation,
        relation: :items,
        assignments: [%{field: :name, value: {:literal, "safe"}}],
        predicate: if(operation in [:update, :delete], do: {:eq, {:field, :id}, {:literal, 1}}),
        returning: :none
      })

    command
  end
end
