defmodule Selecto.Domain.Relations do
  @moduledoc false

  # What a domain says about the relations a read over it may name: every
  # `source_table` and association bridge (`through.table`), and the schema
  # each table is declared with (`source_schema`). Both depend on the domain
  # alone, so `Selecto.configure/3` indexes them once and a read looks them up
  # instead of walking the domain again (index/1, kept at
  # `config.domain_relations`).
  #
  # The index holds the domain it was built from. A query whose domain is no
  # longer that one (a struct put together by hand, a domain replaced after
  # configure) is walked as before, so a lookup is never stale.

  @type t :: %{domain: term(), tables: [String.t()], schemas: %{String.t() => schema()}}
  @type schema :: String.t() | :conflict

  @doc "The index of `domain`."
  @spec index(term()) :: t()
  def index(domain),
    do: %{
      domain: domain,
      tables: collect_tables(domain, []),
      schemas: collect_schemas(domain, %{})
    }

  @doc """
  Every relation `query`'s domain names, one entry per place it names it: its
  source and schema tables and its association bridges.
  """
  @spec tables(map()) :: [String.t()]
  def tables(query) do
    case indexed(query) do
      %{tables: tables} -> tables
      nil -> collect_tables(Map.get(query, :domain), [])
    end
  end

  @doc """
  The schema each table of `query`'s domain is declared with: the
  `source_schema` next to its `source_table`. A table declared with two
  schemas maps to `:conflict`; a table declared with none is absent.
  """
  @spec schemas(map()) :: %{String.t() => schema()}
  def schemas(query) do
    case indexed(query) do
      %{schemas: schemas} -> schemas
      nil -> collect_schemas(Map.get(query, :domain) || %{}, %{})
    end
  end

  @doc "Whether `query`'s domain is the one `Selecto.configure/3` indexed for it."
  @spec indexed?(map()) :: boolean()
  def indexed?(query), do: indexed(query) != nil

  # The index `Selecto.configure/3` built, when it is this domain's. The
  # configured domain is the very term the index holds, so the comparison is
  # one pointer test.
  defp indexed(%{domain: domain, config: %{domain_relations: %{domain: indexed} = index}})
       when indexed === domain,
       do: index

  defp indexed(_query), do: nil

  defp collect_tables(map, acc) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, acc, fn
      {key, value}, acc
      when key in [:source_table, "source_table"] and
             (is_binary(value) or (is_atom(value) and not is_nil(value))) ->
        [to_string(value) | acc]

      {key, %{} = through}, acc when key in [:through, "through"] ->
        table = Map.get(through, :table) || Map.get(through, "table")
        acc = if is_binary(table), do: [table | acc], else: acc
        collect_tables(through, acc)

      {_key, value}, acc ->
        collect_tables(value, acc)
    end)
  end

  defp collect_tables(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_tables/2)

  defp collect_tables(_value, acc), do: acc

  defp collect_schemas(map, acc) when is_map(map) and not is_struct(map) do
    table = Map.get(map, :source_table) || Map.get(map, "source_table")
    schema = map |> Map.get(:source_schema, Map.get(map, "source_schema")) |> schema_name()

    acc =
      if table && schema do
        Map.update(acc, to_string(table), schema, fn
          ^schema -> schema
          _other -> :conflict
        end)
      else
        acc
      end

    Enum.reduce(Map.values(map), acc, &collect_schemas/2)
  end

  defp collect_schemas(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_schemas/2)

  defp collect_schemas(_value, acc), do: acc

  defp schema_name(schema) when is_binary(schema) and schema != "", do: schema
  defp schema_name(schema) when is_atom(schema) and not is_nil(schema), do: Atom.to_string(schema)
  defp schema_name(_schema), do: nil
end
