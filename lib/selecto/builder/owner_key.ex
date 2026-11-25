defmodule Selecto.Builder.OwnerKey do
  @moduledoc false
  alias Selecto.Domain.Contract.Shared.Core, as: M

  @cache_key {__MODULE__, :compiled}

  def with_context(fun) do
    if Process.get(@cache_key) do
      fun.()
    else
      Process.put(@cache_key, %{})

      try do
        fun.()
      after
        Process.delete(@cache_key)
      end
    end
  end

  defp memoized(key, fun) do
    with_context(fn ->
      case Map.fetch(Process.get(@cache_key), key) do
        {:ok, value} ->
          value

        :error ->
          value = fun.()
          Process.put(@cache_key, Map.put(Process.get(@cache_key), key, value))
          value
      end
    end)
  end

  def relation(query, alias_name) when alias_name in [:selecto_root, "selecto_root"],
    do: query.domain.source

  def relation(query, alias_name) do
    case M.fetch_key(Map.get(query.config, :joins, %{}), alias_name) do
      {:ok, config} ->
        Selecto.Builder.ExactCompare.relation_for_table(query, Map.get(config, :source))

      _ ->
        nil
    end
  end

  def sql(query, alias_name, key, relation \\ nil) do
    relation = relation || relation(query, alias_name)
    computed = relation |> Selecto.ComputedOwnerKeys.column(key) |> M.map_value(:computed)

    if is_map(computed) do
      sql =
        memoized({query.domain, relation, key, query.adapter, query.runtime}, fn ->
          domain = %{
            name: "Computed owner",
            source: relation,
            schemas: query.domain.schemas,
            joins: %{}
          }

          unless Selecto.ComputedOwnerKeys.errors(domain) == [] do
            Selecto.Builder.ScopeRefusal.unsupported!(
              Selecto.Error.validation_error("invalid computed owner key", %{
                code: :invalid_domain
              }),
              :invalid_domain
            )
          end

          local =
            Selecto.configure(domain, query.runtime, adapter: query.adapter, validate: false)

          {sql, _joins, _params} =
            Selecto.Builder.Sql.Select.prep_selector(
              local,
              {:computed_value, M.map_value(computed, :expression)}
            )

          sql
        end)

      rename(sql, "selecto_root", to_string(alias_name))
    else
      [
        to_string(alias_name),
        ".",
        query.adapter.quote_identifier(to_string(key))
      ]
    end
  end

  # Compiler-owned SQL only; parameter markers are never rewritten.
  def rename({:param, _} = marker, _, _), do: marker
  def rename(list, from, to) when is_list(list), do: Enum.map(list, &rename(&1, from, to))

  def rename(text, from, to) when is_binary(text),
    do:
      Regex.replace(
        Regex.compile!("(?<![A-Za-z0-9_])" <> Regex.escape(from) <> "(?![A-Za-z0-9_])"),
        text,
        to
      )

  def rename(value, _, _), do: value
end
