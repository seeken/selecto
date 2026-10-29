defmodule Selecto.Schema.JoinNamespaces do
  @moduledoc false
  @comparators ~w(eq ne neq gt gte lt lte in between is_null not_null)a
  @comparator_names ~w(eq ne neq gt gte lt lte in between is_null not_null)

  # Public field namespaces follow complete relationship paths. A repeated
  # local name must never overwrite another edge in the flat SQL join index.
  def normalize(joins) do
    joins = Enum.map(joins, &Map.put_new(&1, :join_path, [&1.id]))

    repeated =
      joins
      |> Enum.group_by(&to_string(&1.id), & &1.join_path)
      |> Enum.filter(fn {_, paths} -> length(Enum.uniq(paths)) > 1 end)
      |> MapSet.new(&elem(&1, 0))

    reserved = MapSet.new(["selecto_root" | Enum.map(joins, &to_string(&1.id))])

    {aliases, _} =
      joins
      |> Enum.sort_by(&Enum.map(&1.join_path, fn id -> to_string(id) end))
      |> Enum.reduce({%{}, reserved}, fn join, {aliases, reserved} ->
        {id, reserved} = alias_for(join, repeated, reserved)
        {Map.put(aliases, join.join_path, id), reserved}
      end)

    Enum.map(joins, &normalize_join(&1, aliases))
  end

  defp alias_for(%{join_path: [_]} = join, _, reserved), do: {join.id, reserved}

  defp alias_for(join, repeated, reserved) do
    if MapSet.member?(repeated, to_string(join.id)) do
      id =
        Stream.iterate(0, &(&1 + 1))
        |> Stream.map(&"_selecto_join_#{&1}")
        |> Enum.find(&(not MapSet.member?(reserved, &1)))

      {id, MapSet.put(reserved, id)}
    else
      {join.id, reserved}
    end
  end

  defp normalize_join(join, aliases) do
    id = Map.fetch!(aliases, join.join_path)
    namespace = Enum.map_join(join.join_path, ".", &to_string/1)
    parent = Map.get(aliases, Enum.drop(join.join_path, -1), join.requires_join)

    fields =
      Map.new(join.fields, fn {key, column} ->
        if id == join.id do
          {key, column}
        else
          next =
            if Map.has_key?(column, :field),
              do: namespace <> "." <> to_string(column.field),
              else: key

          column =
            column
            |> Map.put(:colid, next)
            |> Map.put(:requires_join, id)
            |> update_selector(to_string(column.requires_join) <> ".", namespace <> ".")

          {next, column}
        end
      end)

    # Keep established unambiguous local aliases, and register full paths too.
    # The root path owns its local namespace even when a child reuses its name.
    full =
      fields
      |> Enum.filter(fn {_, column} -> Map.has_key?(column, :field) end)
      |> Map.new(fn {_key, column} ->
        key = namespace <> "." <> to_string(column.field)
        {key, Map.put(column, :colid, key)}
      end)

    join
    |> Map.put(:id, id)
    |> Map.put(:requires_join, parent)
    |> Map.put(:fields, Map.merge(fields, full))
  end

  defp update_selector(column, old, new) do
    if Map.has_key?(column, :select),
      do: Map.update!(column, :select, &rewrite(&1, old, new)),
      else: column
  end

  defp rewrite([tag | _] = value, _, _) when tag in [:literal, "literal"], do: value
  defp rewrite({:literal, _} = value, _, _), do: value

  defp rewrite([tag, field], old, new) when tag in [:field, "field"],
    do: [tag, rename_field(field, old, new)]

  defp rewrite([tag, field, segments], old, new) when tag in [:json_text, "json_text"],
    do: [tag, rename_field(field, old, new), segments]

  defp rewrite([op, field | values], old, new)
       when op in @comparators or op in @comparator_names,
       do: [op, rename_field(field, old, new) | Enum.map(values, &rewrite(&1, old, new))]

  defp rewrite(value, old, new) when is_list(value), do: Enum.map(value, &rewrite(&1, old, new))

  defp rewrite(value, old, new) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&rewrite(&1, old, new)) |> List.to_tuple()

  defp rewrite(value, _, _), do: value

  defp rename_field(field, old, new) when is_binary(field),
    do: String.replace_prefix(field, old, new)

  defp rename_field(field, _, _), do: field
end
