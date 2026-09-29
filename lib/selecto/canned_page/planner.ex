defmodule Selecto.CannedPage.Planner do
  @moduledoc "Derives result, entity-total and exclude-self facet queries without removing scope."
  alias Selecto.CannedPage.{Definition, State}
  alias Selecto.Expr, as: X

  def build(page, %Selecto{} = authorized, input) do
    Definition.plain!(authorized)
    if authorized.domain != page.domain, do: raise(ArgumentError, "page domain mismatch")

    # A page over a tenant_field domain needs a tenant boundary in the
    # authorized query or the page's server-authored dataset filters; browser
    # state never supplies one. A trusted tenant is ANDed into every query.
    with {:ok, authorized} <-
           Selecto.Tenant.require_read_boundary(authorized, scope: page.dataset_filters),
         {:ok, state} <- State.normalize(page, input) do
      base = Selecto.filter(authorized, page.dataset_filters)
      view = Enum.find(page.views, &(&1.id == state["view"]))
      filtered = apply_controls(base, page, state)
      groups = if view.kind == :detail, do: detail_groups(page, view), else: view.groups
      orders = view.orders ++ if(view.kind == :detail, do: [page.entity_key], else: view.groups)

      query =
        filtered
        |> Selecto.select(view.selected)
        |> Selecto.group_by(Enum.uniq(groups))
        |> add_collections(view.collections)
        |> Selecto.order_by(Enum.uniq(orders))
        |> Selecto.limit(state["limit"] + 1)
        |> Selecto.offset((state["page"] - 1) * state["limit"])

      total = Selecto.select(filtered, X.as(X.count_distinct(page.entity_key), "total"))

      facets =
        page.controls
        |> Enum.filter(&(&1.kind == :facet))
        |> Map.new(fn control -> {control.id, facet(base, page, state, control)} end)

      {:ok, %{state: state, view: view, query: query, total_query: total, facets: facets}}
    end
  rescue
    _ in [ArgumentError, KeyError] -> {:error, :invalid_canned_page_definition}
  end

  defp add_collections(query, []), do: query
  defp add_collections(query, collections), do: Selecto.subselect(query, collections)

  defp detail_groups(page, view) do
    fields =
      Enum.map(view.selected, fn
        {:field, field, _alias} -> field
        field -> field
      end)

    orders =
      Enum.map(view.orders, fn
        {field, _direction} -> field
        field -> field
      end)

    [page.entity_key | fields ++ orders]
  end

  defp apply_controls(base, page, state, except \\ nil) do
    predicates =
      page.controls
      |> Enum.reject(&(&1.id == except))
      |> Enum.flat_map(&predicate(&1, state["filters"][&1.id]))

    Selecto.filter(base, predicates ++ drilldown(page, state))
  end

  defp predicate(_, nil), do: []
  defp predicate(%{kind: :text}, ""), do: []
  defp predicate(%{kind: :text, field: field}, value), do: [X.starts_with(field, value)]
  defp predicate(%{kind: :facet}, []), do: []
  defp predicate(%{kind: :facet, field: field}, values), do: [X.in(field, values)]

  defp predicate(%{kind: :range, field: field}, range) do
    Enum.map(range, fn
      {"min", value} -> X.gte(field, value)
      {"max", value} -> X.lte(field, value)
    end)
  end

  defp drilldown(page, %{"drilldown" => drilldown}) do
    view = Enum.find(page.views, &(&1.id == drilldown["view"]))

    Enum.zip_with(view.groups, drilldown["values"], fn
      field, nil -> X.is_null(field)
      field, value -> X.eq(field, value)
    end)
  end

  defp drilldown(_, _), do: []

  defp facet(base, page, state, control) do
    groups = Enum.uniq(Enum.reject([control.field, control.label_field], &is_nil/1))
    selected = [X.as(control.field, "value")]

    selected =
      if control.label_field, do: selected ++ [X.as(control.label_field, "label")], else: selected

    count = X.as(X.count_distinct(page.entity_key), "count")

    base =
      base
      |> apply_controls(page, state, control.id)
      |> Selecto.select(selected ++ [count])
      |> Selecto.group_by(groups)

    options = Selecto.filter(base, X.not_null(control.field))

    options =
      if control.options,
        do: Selecto.filter(options, X.in(control.field, Enum.map(control.options, & &1.value))),
        else: options

    search = state["facet_search"][control.id]

    options =
      if search not in [nil, ""],
        do: Selecto.filter(options, X.starts_with(control.label_field || control.field, search)),
        else: options

    options =
      Selecto.order_by(options, [{X.count_distinct(page.entity_key), :desc}, control.field])

    options = if control.options, do: options, else: Selecto.limit(options, control.limit + 1)
    values = Map.get(state["filters"], control.id, [])

    selected_query =
      if values != [], do: Selecto.filter(base, X.in(control.field, values)), else: nil

    %{options: options, selected: selected_query}
  end
end
