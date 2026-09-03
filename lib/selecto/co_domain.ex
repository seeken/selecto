defmodule Selecto.CoDomain do
  @moduledoc """
  Governed cross-domain lookup execution. The host supplies a configured target
  query and any request-specific scope; declarations never resolve credentials
  or connections. Lookup results are presentation data, not mutation authority.
  """

  alias Selecto.QueryLibrary

  @doc "Returns a declared co-domain without resolving its host-owned target."
  def definition(source, id) do
    source = if match?(%Selecto{}, source), do: source.domain, else: source

    case Selecto.Domain.validate(source) do
      {:ok, domain, _} ->
        case fetch(domain.co_domains, id) do
          nil -> raise ArgumentError, "unknown co-domain"
          definition -> definition
        end

      {:error, _} ->
        raise ArgumentError, "invalid source domain"
    end
  end

  @doc "Builds a bounded lookup query using the host-supplied target and scope."
  def plan(source, %Selecto{} = target, id, text, opts \\ []) do
    definition = definition(source, id)
    limit = Keyword.get(opts, :limit, 20)

    unless is_binary(text) and text != "" and String.length(text) <= 200 and
             not String.contains?(text, <<0>>) do
      raise ArgumentError, "lookup query must be a nonempty string of at most 200 characters"
    end

    unless is_integer(limit) and limit in 1..100,
      do: raise(ArgumentError, "lookup limit must be between 1 and 100")

    parameters = Keyword.get(opts, :parameters, fetch(definition, :parameters) || %{})
    unless is_map(parameters), do: raise(ArgumentError, "lookup parameters must be a map")

    query = apply_definition(target, definition, parameters)
    result = fetch(definition, :result)

    fields =
      [fetch(result, :value_field), fetch(result, :label_field)] ++
        (fetch(result, :description_fields) || [])

    indices = selection_indices(query)

    Enum.each(fields, fn field ->
      if is_nil(Selecto.field(query, to_string(field))) or
           not Map.has_key?(indices, to_string(field)),
         do: raise(ArgumentError, "co-domain result field is absent from its projection")
    end)

    search = fetch(definition, :search)
    search_fields = Enum.map(fetch(search, :fields), &to_string/1)

    Enum.each(search_fields, fn field ->
      if is_nil(Selecto.field(query, field)),
        do: raise(ArgumentError, "unknown lookup search field")
    end)

    mode = fetch(search, :mode) || :plain

    mode =
      Map.fetch!(
        %{"plain" => :plain, "phrase" => :phrase, "websearch" => :websearch, "prefix" => :prefix},
        to_string(mode)
      )

    capability = Selecto.AdapterSupport.capability(query.adapter, :text_search)

    unless Map.get(capability, :supported?, false) and
             Map.get(capability, :governed_lookup?, false) and
             mode in Map.get(capability, :modes, []),
           do: raise(ArgumentError, "lookup text-search mode is unsupported by this adapter")

    text = if mode == :prefix, do: prefix_query(text), else: text
    search_opts = [mode: mode, configuration: fetch(search, :configuration) || "simple"]

    query =
      case Keyword.get(opts, :scope) do
        nil -> query
        scope -> Selecto.filter(query, scope)
      end

    query =
      if text == "" do
        # A tokenless prefix must never become an unconstrained lookup.
        Selecto.filter(query, {to_string(fetch(result, :value_field)), {:in, []}})
      else
        Selecto.filter(query, {search_fields, {:text_search, text, search_opts}})
      end

    query =
      if fetch(search, :rank) == true and text != "" do
        ranked =
          Selecto.text_search_rank(
            query,
            search_fields,
            search_opts ++ [query: text, as: "__co_domain_rank"]
          )

        {:field, expression, _alias} = List.last(ranked.set.selected)
        put_in(ranked.set.order_by, [{:desc, expression} | query.set.order_by])
      else
        query
      end

    %{query: Selecto.limit(query, limit), result: result, indices: indices, empty?: text == ""}
  end

  @doc "Executes the governed lookup through the host-supplied target adapter."
  def lookup(source, %Selecto{} = target, id, text, opts \\ []) do
    plan = plan(source, target, id, text, opts)

    if plan.empty? do
      {:ok, %{results: [], query: plan.query}}
    else
      case Selecto.execute(plan.query) do
        {:ok, {rows, _columns, _aliases}} ->
          results = Enum.flat_map(rows, &result_row(&1, plan))
          {:ok, %{results: results, query: plan.query}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp apply_definition(target, definition, parameters) do
    case fetch(definition, :view) do
      nil ->
        query =
          target
          |> QueryLibrary.apply_segments(fetch(definition, :segments) || [], parameters)
          |> QueryLibrary.apply_projection(fetch(definition, :projection))

        case fetch(definition, :ordering) do
          nil -> query
          ordering -> QueryLibrary.apply_ordering(query, ordering)
        end

      view ->
        QueryLibrary.apply_view(target, view, parameters)
    end
  end

  defp selection_indices(query) do
    query.set.selected
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {selection, index}, acc ->
      case selection do
        field when is_atom(field) or is_binary(field) ->
          Map.put_new(acc, to_string(field), index)

        {:field, field, _alias} when is_atom(field) or is_binary(field) ->
          Map.put_new(acc, to_string(field), index)

        _ ->
          acc
      end
    end)
  end

  defp result_row(row, plan) when is_tuple(row), do: result_row(Tuple.to_list(row), plan)

  defp result_row(row, plan) when is_list(row) do
    value = cell(row, plan, fetch(plan.result, :value_field))

    if scalar?(value) do
      label = cell(row, plan, fetch(plan.result, :label_field))

      label =
        if scalar?(label) and to_string(label) != "", do: to_string(label), else: to_string(value)

      descriptions =
        (fetch(plan.result, :description_fields) || [])
        |> Enum.flat_map(fn field ->
          item = cell(row, plan, field)

          if scalar?(item) and to_string(item) != "" do
            metadata = fetch(plan.query.config.columns, field) || %{}
            name = fetch(metadata, :label)

            [
              if(is_binary(name) and name != "",
                do: name <> " " <> to_string(item),
                else: to_string(item)
              )
            ]
          else
            []
          end
        end)

      result = %{value: to_string(value), label: label}

      [
        if(descriptions == [],
          do: result,
          else: Map.put(result, :description, Enum.join(descriptions, " · "))
        )
      ]
    else
      []
    end
  end

  defp result_row(_, _), do: []
  defp cell(row, plan, field), do: Enum.at(row, Map.fetch!(plan.indices, to_string(field)))
  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  defp prefix_query(text),
    do:
      Regex.scan(~r/[\p{L}\p{N}_]+/u, text)
      |> List.flatten()
      |> Enum.map_join(" & ", &(String.downcase(&1) <> ":*"))

  defp fetch(map, key) when is_map(map) do
    case Enum.find_value(map, fn {candidate, value} ->
           if to_string(candidate) == to_string(key), do: {:found, value}
         end) do
      {:found, value} -> value
      _ -> nil
    end
  end

  defp fetch(_, _), do: nil
end
