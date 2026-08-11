defmodule Selecto.Write.Graph do
  @moduledoc """
  An atomic, topologically ordered portable write graph.

  The graph contains logical commands and generated-value dependencies only.
  It carries no SQL, driver, connection, Repo, or adapter state. Database
  adapters must reject the graph unless they can preserve its complete atomic,
  ownership, cardinality, and generated-key contract.
  """

  alias Selecto.Write.{Command, Error}
  alias Selecto.Write.Graph.{Binding, Node, Row}

  @type t :: %__MODULE__{
          nodes: [Node.t()],
          atomic?: true,
          root: {String.t(), String.t()},
          metadata: map()
        }

  @enforce_keys [:nodes, :root]
  defstruct nodes: [], atomic?: true, root: nil, metadata: %{}

  @spec new([Node.t()], {String.t(), String.t()}, keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(nodes, root, opts \\ []) when is_list(nodes) and is_list(opts) do
    graph = %__MODULE__{
      nodes: nodes,
      root: root,
      atomic?: Keyword.get(opts, :atomic?, true),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    case validate(graph) do
      :ok -> {:ok, graph}
      {:error, _} = error -> error
    end
  end

  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{nodes: nodes, root: root, atomic?: true, metadata: metadata})
      when is_list(nodes) and nodes != [] and is_map(metadata) do
    with :ok <- validate_unique_node_ids(nodes),
         :ok <- validate_nodes(nodes),
         :ok <- validate_root(nodes, root),
         :ok <- validate_topology(nodes) do
      :ok
    end
  end

  def validate(%__MODULE__{} = graph) do
    {:error,
     Error.new(:invalid_graph, "write graphs must be non-empty, atomic, and have map metadata",
       details: %{atomic?: graph.atomic?, root: graph.root, metadata: graph.metadata}
     )}
  end

  defp validate_unique_node_ids(nodes) do
    ids = Enum.map(nodes, & &1.id)

    if Enum.all?(ids, &valid_id?/1) and length(ids) == MapSet.size(MapSet.new(ids)) do
      :ok
    else
      invalid_graph("graph node ids must be unique non-empty strings", %{node_ids: ids})
    end
  end

  defp validate_nodes(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {node, index}, :ok ->
      case validate_node(node) do
        :ok ->
          {:cont, :ok}

        {:error, %Error{} = error} ->
          {:halt, {:error, %{error | details: Map.put(error.details, :node_index, index)}}}
      end
    end)
  end

  defp validate_node(%Node{} = node) do
    row_ids = Enum.map(node.rows, & &1.id)

    cond do
      not valid_path?(node.path) ->
        invalid_graph("graph node path must be a list of portable path segments", %{node: node.id})

      not valid_relation?(node.relation) ->
        invalid_graph("graph node relation must be a non-empty atom or string", %{node: node.id})

      node.strategy not in [:ordered, :sync] ->
        invalid_graph("graph node has an unsupported strategy", %{
          node: node.id,
          strategy: node.strategy
        })

      not is_list(node.rows) ->
        invalid_graph("graph node rows must be a list", %{node: node.id})

      length(row_ids) != MapSet.size(MapSet.new(row_ids)) or not Enum.all?(row_ids, &valid_id?/1) ->
        invalid_graph("graph row ids must be unique within a node", %{
          node: node.id,
          row_ids: row_ids
        })

      node.strategy == :sync and node.identity_fields == [] ->
        invalid_graph("sync graph nodes require identity fields", %{node: node.id})

      node.strategy == :sync and is_nil(node.sync_predicate) ->
        invalid_graph("sync graph nodes require an ownership predicate", %{node: node.id})

      node.strategy == :sync and
          (not Enum.all?(node.identity_fields, &valid_identifier?/1) or
             length(node.identity_fields) != MapSet.size(MapSet.new(node.identity_fields))) ->
        invalid_graph("sync graph identity fields must be unique portable identifiers", %{
          node: node.id
        })

      not valid_field_types?(node.field_types) ->
        invalid_graph("graph node field types must be portable identifier mappings", %{
          node: node.id
        })

      contains_unsafe_sql?(node.sync_predicate) ->
        invalid_graph("raw SQL is not allowed in graph ownership predicates", %{node: node.id})

      not is_boolean(node.delete_missing?) or not is_map(node.metadata) ->
        invalid_graph("graph node flags and metadata are invalid", %{node: node.id})

      true ->
        validate_rows(node)
    end
  end

  defp validate_node(other),
    do: invalid_graph("graph nodes must use Selecto.Write.Graph.Node", %{actual: other})

  defp validate_rows(node) do
    Enum.reduce_while(node.rows, :ok, fn row, :ok ->
      case validate_row(row, node) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_row(%Row{} = row, node) do
    cond do
      not valid_path?(row.path) ->
        invalid_graph("graph row path is invalid", %{node: node.id, row: row.id})

      row.command.relation != node.relation ->
        invalid_graph("every graph row must target its node relation", %{
          node: node.id,
          row: row.id
        })

      not is_list(row.bindings) or not is_map(row.metadata) ->
        invalid_graph("graph row bindings and metadata are invalid", %{node: node.id, row: row.id})

      contains_generated_reference?(row.command) ->
        invalid_graph("generated values must use explicit graph bindings", %{
          node: node.id,
          row: row.id
        })

      true ->
        with :ok <- Command.validate(row.command),
             :ok <- validate_bindings(row.bindings, row) do
          :ok
        end
    end
  end

  defp validate_row(other, node),
    do:
      invalid_graph("graph rows must use Selecto.Write.Graph.Row", %{node: node.id, actual: other})

  defp validate_bindings(bindings, row) do
    assigned = MapSet.new(row.command.assignments, &normalize_identifier(&1.field))

    binding_fields =
      for %Binding{field: field} <- bindings, do: normalize_identifier(field)

    if length(binding_fields) != MapSet.size(MapSet.new(binding_fields)) do
      invalid_graph("graph binding target fields must be unique", %{row: row.id})
    else
      validate_binding_entries(bindings, row, assigned)
    end
  end

  defp validate_binding_entries(bindings, row, assigned) do
    Enum.reduce_while(bindings, :ok, fn
      %Binding{} = binding, :ok ->
        cond do
          not valid_identifier?(binding.field) or not valid_identifier?(binding.from_field) ->
            {:halt, invalid_graph("graph binding fields are invalid", %{row: row.id})}

          not valid_id?(binding.from_node) or not valid_id?(binding.from_row) ->
            {:halt, invalid_graph("graph binding source is invalid", %{row: row.id})}

          MapSet.member?(assigned, normalize_identifier(binding.field)) ->
            {:halt,
             invalid_graph("caller assignments cannot override generated graph bindings", %{
               row: row.id,
               field: binding.field
             })}

          true ->
            {:cont, :ok}
        end

      other, :ok ->
        {:halt,
         invalid_graph("graph bindings must use Selecto.Write.Graph.Binding", %{actual: other})}
    end)
  end

  defp validate_root(nodes, {node_id, row_id}) when is_binary(node_id) and is_binary(row_id) do
    case Enum.find(nodes, &(&1.id == node_id)) do
      %Node{rows: rows} ->
        if Enum.any?(rows, &(&1.id == row_id)), do: :ok, else: invalid_root(node_id, row_id)

      nil ->
        invalid_root(node_id, row_id)
    end
  end

  defp validate_root(_nodes, root),
    do: invalid_graph("graph root must identify an existing row", %{root: root})

  defp validate_topology(nodes) do
    Enum.reduce_while(nodes, {:ok, %{}}, fn node, {:ok, seen} ->
      node_rows = Map.new(node.rows, &{{node.id, &1.id}, &1})

      case validate_node_sources(node, seen) do
        :ok -> {:cont, {:ok, Map.merge(seen, node_rows)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      error -> error
    end
  end

  defp validate_node_sources(node, seen) do
    binding_sources =
      for row <- node.rows,
          %Binding{} = binding <- row.bindings,
          do: {binding.from_node, binding.from_row, binding.from_field}

    predicate_sources = generated_references(node.sync_predicate)
    sources = binding_sources ++ predicate_sources

    if Enum.all?(sources, &valid_source_reference?(seen, &1)) do
      :ok
    else
      invalid_graph("generated graph bindings must reference an earlier row", %{
        node: node.id,
        sources: sources
      })
    end
  end

  defp valid_source_reference?(seen, {node_id, row_id, field}) do
    case Map.get(seen, {node_id, row_id}) do
      %Row{command: %Command{returning: :all}} ->
        true

      %Row{command: %Command{returning: fields}} when is_list(fields) ->
        Enum.any?(fields, &(normalize_identifier(&1) == normalize_identifier(field)))

      _ ->
        false
    end
  end

  defp generated_references({:generated, node_id, row_id, field}),
    do: [{node_id, row_id, field}]

  defp generated_references(%_{} = struct) do
    struct |> Map.from_struct() |> generated_references()
  end

  defp generated_references(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      generated_references(key) ++ generated_references(value)
    end)
  end

  defp generated_references(list) when is_list(list),
    do: Enum.flat_map(list, &generated_references/1)

  defp generated_references(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.flat_map(&generated_references/1)
  end

  defp generated_references(_value), do: []

  defp contains_generated_reference?(value), do: generated_references(value) != []

  defp invalid_root(node_id, row_id),
    do: invalid_graph("graph root must identify an existing row", %{root: {node_id, row_id}})

  defp invalid_graph(message, details),
    do: {:error, Error.new(:invalid_graph, message, details: details)}

  defp valid_id?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_path?(path), do: is_list(path) and Enum.all?(path, &valid_path_segment?/1)

  defp valid_path_segment?(value),
    do: is_atom(value) or is_binary(value) or (is_integer(value) and value >= 0)

  defp valid_relation?(value), do: valid_identifier?(value)

  defp valid_identifier?(value),
    do: is_atom(value) or (is_binary(value) and String.trim(value) != "")

  defp normalize_identifier(value), do: to_string(value)

  defp valid_field_types?(types) when is_map(types) do
    Enum.all?(types, fn {field, type} ->
      valid_identifier?(field) and valid_identifier?(type)
    end)
  end

  defp valid_field_types?(_types), do: false

  defp contains_unsafe_sql?({:unsafe_sql, _}), do: true
  defp contains_unsafe_sql?({:unsafe_fragment, _}), do: true

  defp contains_unsafe_sql?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} -> contains_unsafe_sql?(key) or contains_unsafe_sql?(value) end)
  end

  defp contains_unsafe_sql?(list) when is_list(list), do: Enum.any?(list, &contains_unsafe_sql?/1)

  defp contains_unsafe_sql?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&contains_unsafe_sql?/1)
  end

  defp contains_unsafe_sql?(_value), do: false
end
