defmodule Selecto.Write.Capabilities do
  @moduledoc """
  Validates write-adapter capability reports and derives the capabilities a
  portable write value requires before it may be dispatched.

  Capability checks are deliberately performed in core Selecto. Updato emits
  portable intent and database adapters report what they can preserve; neither
  side is allowed to infer support from the other package's identity.
  """

  alias Selecto.Write.{Batch, Command, Error, Graph}

  @protocol_version 1

  @type capability :: atom() | {:returning, atom()}
  @type capability_map :: %{
          required(:protocol_version) => pos_integer(),
          optional(atom()) => term()
        }

  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%{protocol_version: @protocol_version}), do: :ok

  def validate(%{protocol_version: version}) do
    {:error,
     Error.new(:write_protocol_mismatch, "write adapter uses an incompatible protocol version",
       details: %{expected: @protocol_version, actual: version}
     )}
  end

  def validate(capabilities) when is_map(capabilities) do
    {:error,
     Error.new(:invalid_write_capabilities, "write adapter did not report a protocol version",
       details: %{expected: @protocol_version, capabilities: capabilities}
     )}
  end

  def validate(capabilities) do
    {:error,
     Error.new(:invalid_write_capabilities, "write adapter capabilities must be a map",
       details: %{actual: capabilities}
     )}
  end

  @spec require(map(), Command.t() | Batch.t() | Graph.t()) ::
          :ok | {:error, Error.t()}
  def require(capabilities, write) do
    with :ok <- validate(capabilities) do
      required = requirements(write)
      missing = Enum.reject(required, &supported?(capabilities, &1))

      case missing do
        [] ->
          :ok

        _ ->
          {:error,
           Error.new(
             :write_capability_missing,
             "configured adapter cannot preserve the requested write semantics",
             details: %{required: required, missing: missing}
           )}
      end
    end
  end

  @spec requirements(Command.t() | Batch.t() | Graph.t()) :: [capability()]
  def requirements(%Command{} = command), do: command_requirements(command, true)

  def requirements(%Batch{commands: commands}) do
    [:transactions, :atomic_batch | Enum.flat_map(commands, &command_requirements(&1, true))]
    |> Enum.uniq()
  end

  def requirements(%Graph{} = graph) do
    row_commands = for node <- graph.nodes, row <- node.rows, do: row.command

    requirements =
      [:transactions, :write_graph] ++
        Enum.flat_map(row_commands, &command_requirements(&1, false)) ++
        graph_generated_key_requirement(graph) ++ graph_returning_requirement(graph)

    Enum.uniq(requirements)
  end

  @spec supported?(map(), capability()) :: boolean()
  def supported?(capabilities, {:returning, operation})
      when is_map(capabilities) and is_atom(operation) do
    case Map.get(capabilities, :returning) do
      operations when is_map(operations) -> truthy?(Map.get(operations, operation))
      operations when is_list(operations) -> operation in operations
      value -> truthy?(value)
    end
  end

  def supported?(capabilities, capability) when is_map(capabilities) and is_atom(capability) do
    truthy?(Map.get(capabilities, capability))
  end

  defp command_requirements(command, include_returning?) do
    ([command.operation | command.required_capabilities] ++ document_requirements(command))
    |> maybe_require_returning(command, include_returning?)
    |> Enum.uniq()
  end

  defp document_requirements(%Command{
         metadata: %{document: %Selecto.Write.DocumentMutation{} = document}
       }),
       do: Selecto.Write.DocumentMutation.capabilities(document)

  defp document_requirements(%Command{metadata: %{document: _document}}),
    do: Selecto.Write.DocumentMutation.capabilities()

  defp document_requirements(_command), do: []

  defp maybe_require_returning(requirements, %Command{returning: :none}, _include?),
    do: requirements

  defp maybe_require_returning(requirements, command, true),
    do: [{:returning, command.operation} | requirements]

  defp maybe_require_returning(requirements, _command, false), do: requirements

  defp graph_generated_key_requirement(graph) do
    generated_values? =
      Enum.any?(graph.nodes, fn node ->
        Enum.any?(node.rows, fn row -> row.bindings != [] end)
      end)

    if generated_values?, do: [:generated_keys], else: []
  end

  defp graph_returning_requirement(%Graph{metadata: metadata} = graph) do
    case Map.get(metadata, :root_returning, :all) do
      :none ->
        []

      _returning ->
        case root_command(graph) do
          %Command{operation: operation} -> [{:returning, operation}]
          nil -> []
        end
    end
  end

  defp root_command(%Graph{root: {node_id, row_id}, nodes: nodes}) do
    with %{rows: rows} <- Enum.find(nodes, &(&1.id == node_id)),
         %{command: command} <- Enum.find(rows, &(&1.id == row_id)) do
      command
    else
      _ -> nil
    end
  end

  defp truthy?(value), do: value not in [nil, false]
end
