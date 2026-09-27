defmodule Selecto.CannedPage.Definition do
  @moduledoc "Validated server-authored page intent, without a stored connection."
  alias Selecto.CannedPage.State

  defstruct [
    :id,
    :domain,
    :entity_key,
    :fields,
    :dataset_filters,
    :views,
    :controls,
    :initial_state
  ]

  def new!(%Selecto{} = base, opts) when is_list(opts) do
    ensure!(
      Keyword.keys(opts) -- [:id, :entity_key, :views, :controls, :initial_state] == [],
      "unsupported page definition option"
    )

    plain!(base)
    {:ok, contract, _} = Selecto.Domain.query_contract(base.domain)
    fields = Map.new(contract.fields, &{to_string(&1.id), &1})
    key = to_string(base.domain.source.primary_key)
    ensure!(Keyword.get(opts, :entity_key, key) == key, "entity key must be the root primary key")
    views = Keyword.fetch!(opts, :views)
    controls = Keyword.get(opts, :controls, [])
    ensure!(is_list(views) and views != [], "views must be a nonempty list")
    ensure!(is_list(controls) and length(controls) <= 20, "at most 20 controls are supported")
    unique!(views)
    unique!(controls)

    page = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      domain: base.domain,
      entity_key: key,
      fields: fields,
      dataset_filters: Selecto.Query.query_filters(base),
      views: Enum.map(views, &view!(&1, base, fields, contract, key)),
      controls: Enum.map(controls, &control!(&1, fields)),
      initial_state: Keyword.get(opts, :initial_state, %{})
    }

    ensure!(valid_id?(page.id), "invalid page id")

    case State.normalize(page, page.initial_state) do
      {:ok, _} -> page
      {:error, _} -> raise ArgumentError, "invalid initial page state"
    end
  end

  @doc false
  def plain!(base) do
    allowed = ~w(selected filtered required_filters post_retarget_filters order_by group_by)a
    ensure!(Map.keys(base.set) -- allowed == [], "page base must be a plain query")

    ensure!(
      Enum.all?(
        [:selected, :order_by, :group_by, :post_retarget_filters],
        &(Map.get(base.set, &1, []) == [])
      ),
      "page base cannot project, group, order or retarget"
    )
  end

  defp view!(view, base, fields, contract, key) do
    ensure!(view.kind in [:detail, :aggregate], "unsupported view kind")
    query = Map.fetch!(view, :query)
    ensure!(match?(%Selecto{}, query) and query.domain == base.domain, "view domain mismatch")

    ensure!(
      Map.keys(query.set) --
        ~w(selected filtered required_filters post_retarget_filters order_by group_by subselected)a ==
        [],
      "unsupported view query"
    )

    ensure!(
      query.set.filtered == [] and query.set.post_retarget_filters == [],
      "view predicates belong in dataset"
    )

    selected = query.set.selected
    groups = query.set.group_by
    collections = Map.get(query.set, :subselected, [])

    Enum.each(collections, fn collection ->
      ensure!(
        view.kind == :detail and collection.format == :json_agg,
        "only detail JSON collections are supported"
      )

      ensure!(
        Map.get(collection, :filters, []) == [] and Map.get(collection, :nested, []) == [] and
          is_nil(Map.get(collection, :limit)) and is_nil(Map.get(collection, :after)),
        "canned collections cannot filter, nest or paginate"
      )

      Selecto.Subselect.validate_subselect_config(base, collection)
    end)

    ensure!(selected != [], "view must select fields")

    if view.kind == :detail do
      ensure!(groups == [], "detail cannot group")

      Enum.each(selected ++ Enum.map(query.set.order_by, &order_field/1), fn selector ->
        field = scalar_field!(selector)
        info = field!(fields, field)
        ensure!(not many?(info, contract), "detail fields must be entity grain")
      end)
    else
      ensure!(
        groups != [] and Enum.take(selected, length(groups)) == groups,
        "aggregate must project its group fields first"
      )

      Enum.each(groups, &field!(fields, &1))

      Enum.each(selected, fn
        {:field, {:count_distinct, ^key}, label} when is_binary(label) ->
          :ok

        field when is_binary(field) ->
          ensure!(field in groups, "aggregate field must be grouped")

        _ ->
          raise ArgumentError, "aggregate supports only group fields and distinct entity counts"
      end)
    end

    Map.merge(view, %{
      selected: selected,
      groups: groups,
      orders: query.set.order_by,
      collections: collections
    })
    |> Map.delete(:query)
    |> Map.put_new(:label, view.id)
  end

  defp many?(field, contract) do
    relation = field[:relation]
    joins = Map.get(contract, :joins, [])
    join = Enum.find(joins, &(to_string(&1.id) == to_string(relation)))
    path = if join, do: Map.get(join, :path, [relation]), else: []

    Enum.any?(
      joins,
      &(to_string(&1.id) in Enum.map(path, fn id -> to_string(id) end) and
          &1[:cardinality] in [:many, "many"])
    )
  end

  defp control!(control, fields) do
    ensure!(control.kind in [:text, :range, :facet], "unsupported control")
    info = field!(fields, control.field)
    ensure!(info[:filterable] == true, "control field is not filterable")
    type = info.type

    ensure!(
      type in [
        :string,
        :text,
        :varchar,
        :integer,
        :bigint,
        :smallint,
        :decimal,
        :numeric,
        :float,
        :double,
        :boolean
      ],
      "unsupported page control field type"
    )

    ensure!(
      Map.get(control, :op, :starts_with) == :starts_with and
        not Map.get(control, :ignore_case, false),
      "only literal case-sensitive starts_with text controls are supported"
    )

    ensure!(
      control.kind != :text or type in [:string, :text, :varchar],
      "text control requires text"
    )

    ensure!(
      control.kind != :range or
        type in [:integer, :bigint, :smallint, :decimal, :numeric, :float, :double],
      "range control requires numbers"
    )

    control =
      Map.merge(
        %{label: control.id, limit: 30, searchable: false, options: nil, label_field: nil},
        control
      )

    ensure!(is_integer(control.limit) and control.limit in 1..100, "invalid facet limit")

    ensure!(
      Map.get(control, :selection, :any) == :any and
        Map.get(control, :count_scope, :exclude_self) == :exclude_self,
      "only exclude-self OR facets are supported"
    )

    if control.label_field, do: field!(fields, control.label_field)

    if control.searchable do
      ensure!(
        control.kind == :facet and
          field!(fields, control.label_field || control.field).type in [:string, :text, :varchar],
        "facet search requires text"
      )
    end

    if control.options do
      ensure!(
        is_list(control.options) and length(control.options) in 1..100,
        "invalid fixed options"
      )

      values = Enum.map(control.options, &State.typed!(type, &1.value))
      ensure!(length(Enum.uniq(values)) == length(values), "duplicate fixed options")
    end

    Map.put(control, :type, type)
  end

  defp scalar_field!(field) when is_binary(field), do: field
  defp scalar_field!({:field, field, label}) when is_binary(field) and is_binary(label), do: field
  defp scalar_field!(_), do: raise(ArgumentError, "detail requires scalar fields")
  defp order_field({field, _direction}), do: field
  defp order_field(field), do: field

  defp field!(fields, field) do
    ensure!(is_binary(field) and Map.has_key?(fields, field), "unknown page field")
    Map.fetch!(fields, field)
  end

  defp unique!(items) do
    ids = Enum.map(items, & &1.id)

    ensure!(
      Enum.all?(ids, &valid_id?/1) and length(Enum.uniq(ids)) == length(ids),
      "invalid or duplicate id"
    )
  end

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, id)
  defp ensure!(true, _), do: :ok
  defp ensure!(_, message), do: raise(ArgumentError, message)
end
