defmodule Selecto.Domain.Values do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core

  @doc "Derives direct to-one foreign keys from values-backed schemas."
  def foreign_keys(domain) when is_map(domain) do
    source = get(domain, :source)
    schemas = get(domain, :schemas) || %{}
    joins = get(domain, :joins) || %{}
    associations = get(source, :associations) || %{}

    Enum.reduce(associations, {%{}, []}, fn {name, association}, {keys, errors} ->
      schema = fetch(schemas, get(association, :queryable))
      rows = get(schema, :values)
      related_key = get(association, :related_key)
      owner_key = get(association, :owner_key)
      cardinality = get(association, :cardinality)
      primary_key = get(schema, :primary_key)
      direct? = is_nil(get(association, :through))

      one? =
        cardinality in [:one, "one"] or
          (is_nil(cardinality) and to_string(related_key) == to_string(primary_key))

      if is_list(rows) and direct? and one? do
        key = to_string(owner_key)
        join = fetch(joins, name)
        star? = get(join, :type) in [:star_dimension, "star_dimension"]
        label_field = if star?, do: get(join, :display_field) || :name, else: related_key

        cond do
          Map.has_key?(keys, key) ->
            {keys,
             [
               Core.error(
                 :duplicate_values_foreign_key,
                 [:source, :associations, name],
                 "root field references multiple values associations",
                 field: key
               )
               | errors
             ]}

          Enum.any?(rows, &is_nil(fetch(&1, related_key))) ->
            {keys,
             [
               Core.error(
                 :null_values_foreign_key,
                 [:schemas, get(association, :queryable), :values],
                 "values foreign keys cannot contain null",
                 field: related_key
               )
               | errors
             ]}

          true ->
            options =
              Enum.map(rows, fn row ->
                value = fetch(row, related_key)
                label = fetch(row, label_field)

                label =
                  if is_nil(label) or is_map(label) or is_list(label), do: value, else: label

                %{value: value, label: to_string(label)}
              end)

            spec = %{
              kind: :values,
              association: to_string(name),
              display_name: get(join, :name) || to_string(name),
              value_field: to_string(related_key),
              label_field: to_string(label_field),
              options: options
            }

            {Map.put(keys, key, spec), errors}
        end
      else
        {keys, errors}
      end
    end)
    |> then(fn {keys, errors} -> {keys, Enum.reverse(errors)} end)
  end

  def foreign_keys(_), do: {%{}, []}

  def validate(domain) do
    {_keys, errors} = foreign_keys(domain)
    errors
  end

  def decorate(domain) do
    {keys, _errors} = foreign_keys(domain)
    source = get(domain, :source)
    columns = get(source, :columns)
    writes = get(domain, :writes)
    write_fields = get(writes, :fields)

    columns =
      if is_map(columns) do
        Map.new(columns, fn {field, column} ->
          case Map.get(keys, to_string(field)) do
            nil ->
              {field, column}

            spec ->
              metadata = Map.take(spec, [:kind, :association, :value_field, :label_field])
              {field, column |> put(:foreign_key, metadata) |> put(:options, spec.options)}
          end
        end)
      else
        columns
      end

    write_fields =
      if is_map(write_fields) do
        Map.new(write_fields, fn {field, field_spec} ->
          case Map.get(keys, to_string(field)) do
            spec when is_map(spec) and is_map(field_spec) ->
              if get(field_spec, :insertable) == true do
                metadata = Map.take(spec, [:kind, :association, :value_field, :label_field])
                {field, put(field_spec, :foreign_key, metadata)}
              else
                {field, field_spec}
              end

            _ ->
              {field, field_spec}
          end
        end)
      else
        write_fields
      end

    domain
    |> put(:source, put(source, :columns, columns))
    |> maybe_put_writes(writes, write_fields)
  end

  defp maybe_put_writes(domain, writes, fields) when is_map(writes) and is_map(fields),
    do: put(domain, :writes, put(writes, :fields, fields))

  defp maybe_put_writes(domain, _writes, _fields), do: domain

  defp get(map, key), do: Core.map_value(map, key)

  defp fetch(map, key) when is_map(map) and not is_nil(key) do
    case Core.fetch_key(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch(_, _), do: nil

  defp put(map, key, value) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.put(map, key, value)
      Map.has_key?(map, to_string(key)) -> Map.put(map, to_string(key), value)
      true -> Map.put(map, key, value)
    end
  end

  defp put(value, _key, _entry), do: value
end
