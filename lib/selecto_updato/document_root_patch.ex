defmodule SelectoUpdato.DocumentRootPatch do
  @moduledoc false
  alias Selecto.Document.{Path, ShapeRelease}
  alias Selecto.Write.DocumentMutation
  alias SelectoUpdato.Error

  @types ~w(string integer boolean object_id)

  def resolve(spec, plan, operation, release, root) do
    mutations = value(spec, :mutations)

    with true <- is_list(mutations) and length(mutations) in 1..8,
         :ok <- returning(plan.returning, release, root) do
      Enum.reduce_while(mutations, {:ok, []}, fn authored, {:ok, acc} ->
        case resolve_field(authored, plan, operation, release, root) do
          {:ok, mutation} -> {:cont, {:ok, acc ++ [mutation]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      {:error, _} = error -> error
      _ -> invalid(:unsupported_document_mutations)
    end
  end

  defp resolve_field(authored, plan, operation, release, root) do
    op = value(authored, :op)
    keys = if op in [:set, "set"], do: ~w(op field value_from), else: ~w(op field)

    with true <- exact_keys?(authored, keys),
         {:ok, id} <- identifier(value(authored, :field)),
         {:ok, field} <- ShapeRelease.field(release, root, id),
         true <- field["type"] in @types,
         true <- allowed?(operation, id, plan.action),
         false <- protected?(release, field["path"]),
         {:ok, mutation} <- resolve_value(op, authored, plan.inputs, field) do
      {:ok, mutation}
    else
      _ -> invalid(:forbidden_document_patch)
    end
  end

  defp resolve_value(op, authored, inputs, field) when op in [:set, "set"] do
    with {:ok, input_id} <- identifier(value(authored, :value_from)),
         {:ok, submitted} <- Map.fetch(inputs, input_id),
         true <- DocumentMutation.scalar_value?(submitted),
         true <- typed?(field, submitted) do
      {:ok, %{op: :set, path: field["path"], value: submitted}}
    else
      _ -> invalid(:invalid_document_patch_value)
    end
  end

  defp resolve_value(op, _authored, _inputs, field) when op in [:unset, "unset"] do
    if field["missing"] == "preserve" and field["required"] != true,
      do: {:ok, %{op: :unset, path: field["path"]}},
      else: invalid(:required_document_patch_field)
  end

  defp resolve_value(_, _, _, _), do: invalid(:unsupported_document_mutations)

  defp typed?(field, nil), do: field["nullable"] == true
  defp typed?(field, submitted), do: Selecto.Query.Plan.typed?(field["type"], submitted)

  defp returning(returning, _release, _root) when returning in [nil, :none, "none"], do: :ok

  defp returning(fields, release, root) when is_list(fields) and length(fields) in 1..16 do
    with {:ok, ids} <- identifiers(fields),
         true <- Enum.uniq(ids) == ids,
         true <-
           Enum.all?(ids, fn id ->
             case ShapeRelease.field(release, root, id) do
               {:ok, field} -> field["type"] in @types
               _ -> false
             end
           end) do
      :ok
    else
      _ -> invalid(:invalid_document_postimage)
    end
  end

  defp returning(_, _, _), do: invalid(:invalid_document_postimage)

  defp allowed?(operation, field, action) do
    policy = operation.domain |> value(:writes, %{}) |> value(:fields, %{}) |> value(field, %{})
    actions = value(policy, :document_actions, [])

    is_list(actions) and
      Enum.any?(actions, &((is_atom(&1) or is_binary(&1)) and to_string(&1) == to_string(action)))
  end

  defp protected?(release, path) do
    protected = [
      release["source"]["identity_path"],
      release["source"]["tenant_path"],
      release["source"]["version_path"],
      release["shape"]["variants"]["path"],
      ["_selecto_receipts"]
    ]

    protected =
      Enum.reduce(release["shape"]["fields"], protected, fn {_id, field}, acc ->
        if field["server_managed"] == true, do: [field["path"] | acc], else: acc
      end)

    protected =
      Enum.reduce(release["relations"], protected, fn
        {_id, %{"kind" => "array", "path" => array}}, acc ->
          [array | acc]

        {_id, %{"kind" => "object"} = relation}, acc ->
          Enum.reduce(relation["fields"], acc, fn {_id, field}, paths ->
            if field["server_managed"] == true,
              do: [relation["path"] ++ field["path"] | paths],
              else: paths
          end)

        _, acc ->
          acc
      end)

    Enum.any?(protected, &overlap?(path, &1))
  end

  defp overlap?(a, b), do: Enum.take(a, length(b)) == b or Enum.take(b, length(a)) == a

  defp identifier(id) when is_atom(id) and not is_nil(id), do: identifier(Atom.to_string(id))

  defp identifier(id) when is_binary(id) do
    if Path.safe_key?(id), do: {:ok, id}, else: invalid(:invalid_document_field)
  end

  defp identifier(_), do: invalid(:invalid_document_field)

  defp identifiers(fields) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, acc} ->
      case identifier(field) do
        {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
        error -> {:halt, error}
      end
    end)
  end

  defp exact_keys?(map, allowed) when is_map(map) and not is_struct(map) do
    keys = Map.keys(map)

    Enum.all?(keys, &(is_atom(&1) or is_binary(&1))) and
      Enum.sort(Enum.map(keys, &to_string/1)) == Enum.sort(allowed)
  end

  defp exact_keys?(_, _), do: false

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    Enum.find_value(map, default, fn {candidate, item} ->
      if (is_atom(candidate) or is_binary(candidate)) and to_string(candidate) == to_string(key),
        do: {:found, item}
    end)
    |> case do
      {:found, item} -> item
      item -> item
    end
  end

  defp value(_, _, default), do: default

  defp invalid(code),
    do:
      {:error,
       Error.new(:invalid_action_plan, "Invalid governed document root patch",
         details: %{code: code}
       )}
end
