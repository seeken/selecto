defmodule Selecto.TextSearch do
  @moduledoc false

  alias Selecto.Dialect.TextSearch.Rank

  def text_search_rank(selecto, fields, opts \\ [])

  def text_search_rank(selecto, fields, opts) when is_map(opts) do
    text_search_rank(selecto, fields, Enum.into(opts, []))
  end

  def text_search_rank(selecto, fields, opts) when is_list(opts) do
    :ok = Selecto.SetOperations.ensure_query_mutation_allowed!(selecto, :text_search_rank)

    adapter = Map.get(selecto, :adapter)
    capability = Selecto.AdapterSupport.capability(adapter, :text_search)
    mode = normalize_mode(Keyword.get(opts, :mode, Map.get(capability, :default_mode)))

    ensure_supported!(adapter, capability, mode)

    rank = %Rank{
      fields: Enum.map(List.wrap(fields), &to_string/1),
      query: Keyword.get(opts, :query),
      alias: opts |> Keyword.get(:as, "fts_rank") |> to_string(),
      mode: mode,
      weights: Keyword.get(opts, :weights, []),
      configuration: Keyword.get(opts, :configuration)
    }

    case Selecto.DialectSupport.render_text_search_rank(adapter, rank, selecto) do
      {:ok, selector} ->
        put_in(selecto.set[:selected], Enum.uniq(selecto.set.selected ++ [selector]))

      {:error, %Selecto.Error{} = error} ->
        raise ArgumentError, error.message

      {:error, reason} ->
        raise ArgumentError,
              "text_search_rank/3 is not implemented by adapter #{inspect(Selecto.AdapterSupport.adapter_name(adapter))}: #{inspect(reason)}"
    end
  end

  defp ensure_supported!(adapter, capability, mode) do
    adapter_name = Selecto.AdapterSupport.adapter_name(adapter)

    cond do
      Map.get(capability, :supported?, false) != true ->
        raise ArgumentError,
              "text_search_rank/3 is not yet implemented for adapter #{inspect(adapter_name)}"

      mode in Map.get(capability, :modes, []) ->
        :ok

      true ->
        raise ArgumentError,
              "text_search_rank/3 does not support #{inspect(mode)} for adapter #{inspect(adapter_name)}"
    end
  end

  defp normalize_mode(:web), do: :websearch
  defp normalize_mode(mode), do: mode
end
