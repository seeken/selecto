defmodule Selecto.CannedPage.State do
  @moduledoc "Closed, typed browser state. Explicit empty filters clear authored defaults."

  def normalize(page, input) do
    {:ok, normalize!(page, input)}
  rescue
    _ in [ArgumentError, KeyError, BadMapError, FunctionClauseError] ->
      {:error, :invalid_canned_page_state}
  end

  defp normalize!(page, input) do
    object!(input, ~w(version view filters facet_search drilldown page limit))
    ensure!(Map.get(input, "version", 1) in [1, "1"])
    view = Map.get(input, "view", Map.get(page.initial_state, "view", hd(page.views).id))
    ensure!(Enum.any?(page.views, &(&1.id == view)))
    filters = Map.get(input, "filters", Map.get(page.initial_state, "filters", %{}))
    controls = Map.new(page.controls, &{&1.id, &1})
    object!(filters, Map.keys(controls))
    filters = Map.new(filters, fn {id, value} -> {id, filter!(controls[id], value)} end)
    search = Map.get(input, "facet_search", %{})
    object!(search, Enum.map(Enum.filter(page.controls, & &1.searchable), & &1.id))
    search = Map.new(search, fn {id, value} -> {id, text!(value)} end)

    state = %{
      "version" => 1,
      "view" => view,
      "filters" => filters,
      "facet_search" => search,
      "page" => bounded!(Map.get(input, "page", 1), 100_000),
      "limit" => bounded!(Map.get(input, "limit", 25), 100)
    }

    if Map.has_key?(input, "drilldown"),
      do: Map.put(state, "drilldown", drilldown!(page, input["drilldown"])),
      else: state
  end

  defp drilldown!(page, input) do
    object!(input, ~w(view values))
    view = Enum.find(page.views, &(&1.id == input["view"] and &1.kind == :aggregate))

    ensure!(
      view != nil and is_list(input["values"]) and length(input["values"]) == length(view.groups)
    )

    values =
      Enum.zip_with(view.groups, input["values"], fn field, value ->
        if is_nil(value), do: nil, else: typed!(page.fields[field].type, value)
      end)

    %{"view" => view.id, "values" => values}
  end

  defp filter!(%{kind: :text}, value), do: text!(value)

  defp filter!(%{kind: :range, type: type}, value) do
    object!(value, ~w(min max))

    value
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Map.new(fn {key, v} -> {key, typed!(type, v)} end)
  end

  defp filter!(%{kind: :facet} = control, values) do
    ensure!(is_list(values) and length(values) <= 100)
    values = Enum.map(values, &typed!(control.type, &1)) |> Enum.uniq()

    if control.options do
      allowed = Enum.map(control.options, &typed!(control.type, &1.value))
      ensure!(Enum.all?(values, &(&1 in allowed)))
    end

    values
  end

  @doc false
  def typed!(type, value) when type in [:integer, :bigint, :smallint] do
    text = scalar!(value)
    ensure!(Regex.match?(~r/\A-?\d+\z/, text))
    String.to_integer(text)
  end

  def typed!(type, value) when type in [:float, :double] and is_float(value), do: value

  def typed!(type, value) when type in [:float, :double] do
    text = scalar!(value)
    ensure!(Regex.match?(~r/\A-?\d+(?:\.\d+)?\z/, text))

    case Float.parse(text) do
      {number, ""} -> number
      _ -> raise ArgumentError, "invalid floating point value"
    end
  end

  def typed!(type, value) when type in [:decimal, :numeric] do
    text = scalar!(value)
    ensure!(Regex.match?(~r/\A-?\d+(?:\.\d+)?\z/, text))
    # Preserve decimal precision across the browser and driver boundary.
    text |> Decimal.new() |> Decimal.normalize()
  end

  def typed!(:boolean, value) when value in [true, false], do: value
  def typed!(:boolean, value) when value in ["true", "1", 1], do: true
  def typed!(:boolean, value) when value in ["false", "0", 0], do: false
  def typed!(:boolean, _), do: raise(ArgumentError, "invalid boolean")
  def typed!(_type, value), do: text!(value)

  defp scalar!(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp scalar!(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp scalar!(value), do: text!(value)

  defp text!(value) do
    ensure!(is_binary(value) and byte_size(value) <= 512)
    value
  end

  defp bounded!(value, max) do
    value = typed!(:integer, value)
    ensure!(value >= 1 and value <= max)
    value
  end

  defp object!(value, allowed),
    do: ensure!(is_map(value) and not is_struct(value) and Map.keys(value) -- allowed == [])

  defp ensure!(true), do: :ok
  defp ensure!(_), do: raise(ArgumentError, "invalid page state")
end
