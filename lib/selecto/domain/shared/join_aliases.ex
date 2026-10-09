defmodule Selecto.Domain.Shared.JoinAliases do
  @moduledoc false

  alias Selecto.Domain.Shared.Map, as: MapHelpers

  def all(normalized) do
    all(
      Map.get(normalized, :source),
      Map.get(normalized, :schemas, %{}),
      Map.get(normalized, :joins, %{})
    )
  end

  def all(source, schemas, joins), do: walk(joins, source, schemas, source, [])

  # Complete paths own their namespace before established local aliases. A
  # repeated local name is ambiguous even when only one target has a field.
  def index({__MODULE__, _source, _projection, _full, _local, _namespaces} = index), do: index

  def index(normalized) do
    joins =
      Enum.map(all(normalized), fn join ->
        entries = MapHelpers.relation_field_entries(join.relation)

        fields =
          Map.new(entries, fn {key, column} -> {MapHelpers.field_id(key), {key, column}} end)

        Map.merge(join, %{field_entries: entries, fields: fields})
      end)

    full = Enum.group_by(joins, &Enum.join(&1.join_path, "."))
    local = Enum.group_by(joins, &MapHelpers.field_id(&1.id))

    {__MODULE__, Map.get(normalized, :source), Map.get(normalized, :projection, %{}), full, local,
     Map.merge(local, full)}
  end

  def source(normalized), do: normalized |> index() |> elem(1)
  def namespaces(normalized), do: normalized |> index() |> elem(5)

  def claimed_field?(normalized, field) do
    field = MapHelpers.field_id(field)

    Enum.any?(namespaces(normalized), fn {id, _joins} -> String.starts_with?(field, id <> ".") end)
  end

  def lookup(normalized, field) do
    field = MapHelpers.field_id(field)
    index = index(normalized)

    case matching_namespace(elem(index, 3), field) || matching_namespace(elem(index, 4), field) do
      nil ->
        :error

      {id, [join]} ->
        suffix = String.replace_prefix(field, id <> ".", "")

        case Map.get(join.fields, suffix) do
          nil -> {:error, :field_not_found}
          {key, column} -> {:ok, field_column(index, id, join, key, column)}
        end

      {_id, _ambiguous} ->
        {:error, :ambiguous_join_alias}
    end
  end

  def field_columns(normalized) do
    index = index(normalized)

    index
    |> namespaces()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn
      {id, [join]} ->
        join.field_entries
        |> Enum.map(fn {field, column} -> field_column(index, id, join, field, column) end)
        |> Enum.filter(fn entry ->
          case lookup(index, entry.field) do
            {:ok, owner} -> owner.alias_id == entry.alias_id and owner.path == entry.path
            _ -> false
          end
        end)

      {_id, _ambiguous} ->
        []
    end)
  end

  defp matching_namespace(namespaces, field) do
    Enum.reduce(namespaces, nil, fn {id, _joins} = entry, best ->
      if String.starts_with?(field, id <> ".") and
           (is_nil(best) or byte_size(id) > byte_size(elem(best, 0))) do
        entry
      else
        best
      end
    end)
  end

  defp field_column(normalized, id, join, field, column) do
    projection = normalized |> index() |> elem(2) |> MapHelpers.map_value(:columns)
    field_id = id <> "." <> MapHelpers.field_id(field)

    projected =
      case MapHelpers.fetch_key(projection, field_id) do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end

    %{
      field: field_id,
      path: join.source_path ++ [:columns, field],
      column: Map.merge(column, projected),
      alias_id: id,
      source_field: field,
      relation_id: if(id == MapHelpers.field_id(join.id), do: join.id, else: id)
    }
  end

  defp walk(joins, parent, schemas, source, path) when is_map(joins) and is_map(parent) do
    joins
    |> MapHelpers.sorted_entries()
    |> Enum.flat_map(fn {id, config} ->
      association = MapHelpers.relation_association(parent, id)
      target = MapHelpers.map_value(association, :queryable)
      {relation, source_path} = target_relation(target, source, schemas)

      if is_map(config) and not is_nil(target) and is_map(relation) do
        join_path = path ++ [MapHelpers.field_id(id)]
        full = Enum.join(join_path, ".")
        aliases = Enum.uniq([full, MapHelpers.field_id(id)])

        entry = %{
          id: id,
          join_path: join_path,
          aliases: aliases,
          relation: relation,
          source_path: source_path,
          config: config
        }

        [entry | walk(MapHelpers.map_value(config, :joins), relation, schemas, source, join_path)]
      else
        []
      end
    end)
  end

  defp walk(_joins, _parent, _schemas, _source, _path), do: []

  defp target_relation(target, source, _schemas) when target in [:source, "source"],
    do: {source, [:source]}

  defp target_relation(target, _source, schemas) do
    case MapHelpers.fetch_key(schemas, target) do
      {:ok, relation} when is_map(relation) -> {relation, [:schemas, target]}
      _ -> {nil, []}
    end
  end
end
