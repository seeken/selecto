defmodule Selecto.CannedPage.Runner do
  @moduledoc "Executes page plans through Selecto's public adapter boundary."
  alias Selecto.CannedPage.{Planner, State}

  def run(page, authorized, input) do
    started = System.monotonic_time(:millisecond)

    with {:ok, plan} <- Planner.build(page, authorized, input),
         {:ok, {rows, columns, aliases}, metadata} <- Selecto.execute_with_metadata(plan.query),
         {:ok, {[[total]], _, _}} <- query_rows(plan.total_query),
         {:ok, facets} <- facets(page, plan),
         {:ok, result_total} <- result_total(plan, total) do
      {:ok,
       %{
         state: plan.state,
         view: plan.view,
         rows: Enum.take(rows, plan.state["limit"]),
         columns: columns,
         aliases: aliases,
         total: total,
         result_total: result_total,
         facets: facets,
         has_more: length(rows) > plan.state["limit"],
         metadata: metadata,
         elapsed_ms: System.monotonic_time(:millisecond) - started
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_canned_page_result}
    end
  end

  defp result_total(%{view: %{kind: :detail}}, total), do: {:ok, total}

  defp result_total(plan, _total) do
    query = Selecto.Query.unpaginate(plan.query)

    case Selecto.execute_count_with_metadata(query) do
      {:ok, total, _metadata} -> {:ok, total}
      {:error, reason} -> {:error, reason}
    end
  end

  defp facets(page, plan) do
    page.controls
    |> Enum.filter(&(&1.kind == :facet))
    |> Enum.reduce_while({:ok, %{}}, fn control, {:ok, acc} ->
      query = plan.facets[control.id]

      with {:ok, {rows, _, _}} <- query_rows(query.options),
           {:ok, {selected, _, _}} <- execute_selected(query.selected) do
        values = Map.get(plan.state["filters"], control.id, [])
        result = options(control, rows, selected, values)
        {:cont, {:ok, Map.put(acc, control.id, result)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_selected(nil), do: {:ok, {[], [], []}}
  defp execute_selected(query), do: query_rows(query)

  # Keep execution in the caller's process so a host-owned transaction or
  # sandbox checkout also covers totals and facet queries.
  defp query_rows(query) do
    case Selecto.execute_with_metadata(query) do
      {:ok, result, _metadata} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp options(control, rows, selected, values) do
    rows = Enum.map(rows, &option(control, &1))
    selected = Enum.map(selected, &option(control, &1))
    truncated = is_nil(control.options) and length(rows) > control.limit

    shown =
      if control.options do
        Enum.map(control.options, fn item ->
          value = State.typed!(control.type, item.value)
          match = Enum.find(rows, &(&1.value == value))

          %{
            value: value,
            label: Map.get(item, :label, value),
            count: if(match, do: match.count, else: 0)
          }
        end)
      else
        Enum.take(rows, control.limit)
      end

    missing =
      values
      |> Enum.reject(fn value -> Enum.any?(shown, &(&1.value == value)) end)
      |> Enum.map(fn value ->
        Enum.find(selected, &(&1.value == value)) || %{value: value, label: value, count: 0}
      end)

    %{options: shown ++ missing, truncated: truncated}
  end

  defp option(%{label_field: nil} = control, [value, count]),
    do: %{value: State.typed!(control.type, value), label: value, count: count}

  defp option(control, [value, label, count]),
    do: %{value: State.typed!(control.type, value), label: label, count: count}
end
