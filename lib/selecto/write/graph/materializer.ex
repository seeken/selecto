defmodule Selecto.Write.Graph.Materializer do
  @moduledoc """
  Dialect-neutral mechanics for portable write graphs.

  This module resolves generated-value bindings and constructs portable cleanup
  commands. It deliberately contains no SQL, driver, connection, transaction,
  or database-version logic; those remain responsibilities of each database
  adapter.
  """

  alias Selecto.Write.{Command, Error, Graph, Result}
  alias Selecto.Write.Graph.{Binding, Node, Row}

  @spec materialize_node(Node.t(), map()) :: {:ok, Node.t()} | {:error, Error.t()}
  def materialize_node(%Node{} = node, results) when is_map(results) do
    with {:ok, sync_predicate} <- resolve_generated(node.sync_predicate, results),
         {:ok, rows} <- materialize_rows(node.rows, results) do
      {:ok, %{node | sync_predicate: sync_predicate, rows: rows}}
    end
  end

  @spec symbolic_results(Node.t()) :: map()
  def symbolic_results(%Node{} = node) do
    Map.new(node.rows, fn row ->
      fields = command_returning_fields(row.command)

      data =
        Map.new(fields, fn field ->
          {to_string(field), {:generated, node.id, row.id, field}}
        end)

      {{node.id, row.id},
       %Result{
         operation: row.command.operation,
         affected_rows: 1,
         rows: [data],
         metadata: %{symbolic_source: {node.id, row.id}}
       }}
    end)
  end

  @spec delete_missing_command(Node.t(), map()) ::
          {:ok, Command.t() | nil} | {:error, Error.t()}
  def delete_missing_command(%Node{delete_missing?: false}, _row_results), do: {:ok, nil}

  def delete_missing_command(%Node{} = node, row_results) when is_map(row_results) do
    identities =
      Enum.reduce_while(node.rows, {:ok, []}, fn row, {:ok, identities} ->
        case identity_from_result(row, node.identity_fields, row_results) do
          {:ok, identity} -> {:cont, {:ok, [identity | identities]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, identities} <- identities do
      identity_exclusion =
        identities
        |> Enum.reverse()
        |> Enum.map(&identity_predicate/1)
        |> case do
          [] -> nil
          [predicate] -> {:not, predicate}
          predicates -> {:not, {:or, predicates}}
        end

      Command.new(%{
        operation: :delete,
        relation: node.relation,
        predicate: conjunction([node.sync_predicate, identity_exclusion]),
        expected_cardinality: :many,
        returning: :none,
        required_capabilities: [:delete],
        metadata: %{graph_cleanup: true, graph_node: node.id}
      })
    end
  end

  @spec root_rows(Graph.t(), map()) :: [map()]
  def root_rows(%Graph{} = graph, results) when is_map(results) do
    result = Map.get(results, graph.root)

    case root_returning(graph) do
      :none -> []
      :all -> result_rows(result)
      fields when is_list(fields) -> filter_result_fields(result, fields)
      _other -> []
    end
  end

  @spec root_returning(Graph.t()) :: :none | :all | [atom() | String.t()]
  def root_returning(%Graph{metadata: metadata}), do: Map.get(metadata, :root_returning, :all)

  defp materialize_rows(rows, results) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, materialized} ->
      case materialize_row(row, results) do
        {:ok, row} -> {:cont, {:ok, materialized ++ [row]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp materialize_row(%Row{} = row, results) do
    Enum.reduce_while(row.bindings, {:ok, row.command}, fn binding, {:ok, command} ->
      with {:ok, value} <- binding_value(binding, results),
           {:ok, command} <- apply_binding(command, binding.field, value) do
        {:cont, {:ok, command}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, command} -> {:ok, %{row | command: command}}
      error -> error
    end
  end

  defp binding_value(%Binding{} = binding, results) do
    case Map.get(results, {binding.from_node, binding.from_row}) do
      %Result{rows: [row | _], metadata: metadata} ->
        case fetch_result_value(row, binding.from_field) do
          {:ok, value} ->
            {:ok, value}

          :error ->
            case metadata do
              %{symbolic_source: {node_id, row_id}} ->
                {:ok, {:generated, node_id, row_id, binding.from_field}}

              _ ->
                missing_binding(binding)
            end
        end

      _ ->
        missing_binding(binding)
    end
  end

  defp missing_binding(binding) do
    {:error,
     Error.new(:generated_value_missing, "generated graph binding value is unavailable",
       details: %{
         source: {binding.from_node, binding.from_row},
         field: binding.from_field
       }
     )}
  end

  defp apply_binding(%Command{operation: operation} = command, field, value)
       when operation in [:insert, :upsert] do
    {:ok,
     %{command | assignments: command.assignments ++ [%{field: field, value: {:literal, value}}]}}
  end

  defp apply_binding(%Command{operation: operation} = command, field, value)
       when operation in [:update, :delete] do
    {:ok,
     %{
       command
       | predicate: conjunction([command.predicate, {:eq, {:field, field}, {:literal, value}}])
     }}
  end

  defp resolve_generated(nil, _results), do: {:ok, nil}

  defp resolve_generated({:generated, node_id, row_id, field}, results) do
    binding_value(
      %Binding{field: field, from_node: node_id, from_row: row_id, from_field: field},
      results
    )
    |> case do
      {:ok, value} -> {:ok, {:literal, value}}
      error -> error
    end
  end

  defp resolve_generated(tuple, results) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> resolve_generated_list(results)
    |> case do
      {:ok, values} -> {:ok, List.to_tuple(values)}
      error -> error
    end
  end

  defp resolve_generated(list, results) when is_list(list),
    do: resolve_generated_list(list, results)

  defp resolve_generated(value, _results), do: {:ok, value}

  defp resolve_generated_list(values, results) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, resolved} ->
      case resolve_generated(value, results) do
        {:ok, value} -> {:cont, {:ok, resolved ++ [value]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp command_returning_fields(%Command{returning: :all}), do: []
  defp command_returning_fields(%Command{returning: :none}), do: []
  defp command_returning_fields(%Command{returning: fields}) when is_list(fields), do: fields

  defp identity_from_result(row, fields, results) do
    with %Result{rows: [data | _]} <- Map.get(results, row.id) do
      identity_from_map(data, fields, row)
    else
      _ -> missing_identity(row, fields)
    end
  end

  defp identity_from_map(data, fields, row) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, values} ->
      case fetch_result_value(data, field) do
        {:ok, value} when not is_nil(value) -> {:cont, {:ok, Map.put(values, field, value)}}
        _ -> {:halt, missing_identity(row, fields)}
      end
    end)
  end

  defp missing_identity(row, fields) do
    {:error,
     Error.new(:generated_value_missing, "sync row did not return its complete identity",
       details: %{row: row.id, fields: fields}
     )}
  end

  defp identity_predicate(identity) do
    identity
    |> Enum.map(fn {field, value} -> {:eq, {:field, field}, {:literal, value}} end)
    |> conjunction()
  end

  defp conjunction(values) do
    case Enum.reject(values, &is_nil/1) do
      [value] -> value
      values -> {:and, values}
    end
  end

  defp result_rows(%Result{rows: rows}), do: rows
  defp result_rows(_result), do: []

  defp filter_result_fields(%Result{rows: rows}, fields) do
    field_ids = MapSet.new(fields, &to_string/1)

    Enum.map(rows, fn row ->
      Map.filter(row, fn {field, _value} -> MapSet.member?(field_ids, to_string(field)) end)
    end)
  end

  defp filter_result_fields(_result, _fields), do: []

  defp fetch_result_value(map, field) when is_map(map) do
    case Enum.find(map, fn {key, _value} -> to_string(key) == to_string(field) end) do
      {_key, value} -> {:ok, value}
      nil -> :error
    end
  end
end
