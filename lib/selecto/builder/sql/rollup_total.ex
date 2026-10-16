defmodule Selecto.Builder.Sql.RollupTotal do
  @moduledoc false

  # PostgreSQL's GROUP BY ROLLUP returns the grand-total row even on empty
  # input (COUNT(*) = 0, other aggregates NULL). A native `WITH ROLLUP`
  # (MySQL, MariaDB) returns no row at all there. Adapters declaring
  # `:rollup_without_empty_total` therefore get the native rollup as one UNION
  # ALL branch and, as the other, the same query without GROUP BY (dimensions
  # NULL, GROUPING markers all ones), kept only when it aggregated no row:
  #
  #     SELECT p1 AS a1, ... FROM (
  #       SELECT p1, ... FROM (<native WITH ROLLUP>) AS selecto_rollup_native
  #       UNION ALL
  #       SELECT p1, ... FROM (<grand total>) AS selecto_rollup_total
  #        WHERE selecto_rollup_rows = 0
  #     ) AS selecto_rollup ORDER BY ... LIMIT ...
  #
  # Ordering keeps Selecto's rollup semantics (subtotal NULLs first unless the
  # order names NULLS LAST), on output positions only. A rollup this shape
  # cannot express (expressions over dimensions, windows, subselects, an order
  # on an unselected value) keeps the native statement unchanged.

  alias Selecto.Builder.Sql
  alias Selecto.Builder.Sql.Select

  @feature :rollup_without_empty_total
  @directions [
    :asc,
    :desc,
    :asc_nulls_first,
    :asc_nulls_last,
    :desc_nulls_first,
    :desc_nulls_last
  ]
  @aggregate_functions ~w(COUNT SUM AVG MIN MAX)
  @rows_alias "selecto_rollup_rows"

  @doc false
  def applies?(selecto, opts) do
    not Keyword.get(opts, :rollup_native, false) and
      Selecto.AdapterSupport.supports_feature?(selecto.adapter, @feature)
  end

  @doc false
  # `{iodata, aliases, joins}`, or :native when the shape needs the native
  # statement unchanged.
  def render(selecto, opts) do
    with {:ok, dimensions} <- dimensions(selecto.set.group_by),
         selectors when selectors != [] <- Map.get(selecto.set, :selected, []),
         true <- plain_shape?(selecto),
         true <- Enum.all?(selectors, &supported?(&1, dimensions)),
         {:ok, order} <- order(Map.get(selecto.set, :order_by, []), selectors, selecto),
         {:ok, pagination} <- pagination(selecto.set) do
      branch_opts = Keyword.merge(opts, unique_projection_aliases: true, rollup_native: true)

      native_set =
        selecto.set
        |> Map.put(:order_by, [])
        |> Map.put(:limit, nil)
        |> Map.put(:offset, nil)

      {native, aliases, joins} =
        Sql.build_iodata_with_joins(%{selecto | set: native_set}, branch_opts)

      total_selected =
        Enum.map(selectors, &{:field, rewrite(&1, dimensions), selector_alias(selecto, &1)}) ++
          [{:field, {:count, "*"}, @rows_alias}]

      total_set =
        native_set
        |> Map.put(:selected, total_selected)
        |> Map.put(:group_by, [])
        |> Map.put(
          :active_joins,
          Enum.uniq(List.wrap(Map.get(selecto.set, :active_joins, [])) ++ List.wrap(joins))
        )

      {total, _aliases, _joins} =
        Sql.build_iodata_with_joins(%{selecto | set: total_set}, branch_opts)

      positions = Enum.map(1..length(selectors), &qid(selecto, Sql.projection_alias(&1)))
      columns = Enum.intersperse(positions, ", ")
      rows_column = qid(selecto, Sql.projection_alias(length(selectors) + 1))

      outputs =
        positions
        |> Enum.zip(aliases)
        |> Enum.with_index(1)
        |> Enum.map(fn {{position, name}, index} ->
          output =
            if Keyword.get(opts, :unique_projection_aliases, false),
              do: Sql.projection_alias(index),
              else: to_string(name)

          [position, " AS ", qid(selecto, output)]
        end)

      sql = [
        "SELECT ",
        Enum.intersperse(outputs, ", "),
        " FROM (SELECT ",
        columns,
        " FROM (",
        native,
        ") AS ",
        qid(selecto, "selecto_rollup_native"),
        " UNION ALL SELECT ",
        columns,
        " FROM (",
        total,
        ") AS ",
        qid(selecto, "selecto_rollup_total"),
        " WHERE ",
        rows_column,
        " = 0) AS ",
        qid(selecto, "selecto_rollup"),
        order,
        pagination
      ]

      {sql, aliases, joins}
    else
      _ -> :native
    end
  end

  defp dimensions([{:rollup, dimensions}]) when is_list(dimensions) and dimensions != [] do
    if Enum.all?(dimensions, &is_binary(field(&1))) and
         length(Enum.uniq_by(dimensions, &field/1)) == length(dimensions),
       do: {:ok, dimensions},
       else: :error
  end

  defp dimensions(_group_by), do: :error

  defp plain_shape?(selecto) do
    Enum.all?(
      [:window_functions, :json_selects, :array_operations, :subselects, :json_order_by],
      &(Map.get(selecto.set, &1, []) in [nil, [], %{}])
    )
  end

  defp supported?({:field, selector, _alias}, dimensions), do: supported?(selector, dimensions)
  defp supported?({:field, selector}, dimensions), do: supported?(selector, dimensions)

  defp supported?({:grouping, arguments}, dimensions) when is_list(arguments) do
    fields = Enum.map(dimensions, &field/1)
    arguments != [] and Enum.all?(arguments, &(field(&1) in fields))
  end

  defp supported?(selector, dimensions) do
    field(selector) in Enum.map(dimensions, &field/1) or
      (aggregate?(selector) and not contains_grouping?(selector)) or literal?(selector)
  end

  defp rewrite({:field, selector, _alias}, dimensions), do: rewrite(selector, dimensions)
  defp rewrite({:field, selector}, dimensions), do: rewrite(selector, dimensions)

  # Every dimension is rolled up in the grand total: each GROUPING bit is 1.
  defp rewrite({:grouping, arguments}, _dimensions),
    do: {:literal, Integer.pow(2, length(arguments)) - 1}

  defp rewrite(selector, dimensions) do
    if field(selector) in Enum.map(dimensions, &field/1),
      do: {:literal, nil},
      else: selector
  end

  defp selector_alias(selecto, selector) do
    {_sql, _joins, _params, name} = Select.build(selecto, selector)
    to_string(name)
  end

  defp aggregate?({:count}), do: true
  defp aggregate?({:count, _}), do: true
  defp aggregate?({:count_distinct, _}), do: true
  defp aggregate?({name, _}) when name in [:sum, :avg, :min, :max], do: true

  defp aggregate?({:func, name, [_]}),
    do: String.upcase(to_string(name)) in @aggregate_functions

  defp aggregate?({:func, name, [_], opts}) when is_list(opts),
    do:
      String.upcase(to_string(name)) in @aggregate_functions and Keyword.keyword?(opts) and
        Enum.all?(opts, fn {key, _} -> key in [:as, :distinct] end)

  defp aggregate?(_), do: false

  defp literal?({kind, value}) when kind in [:literal, :param],
    do: is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value)

  defp literal?(value), do: is_number(value) or is_boolean(value)

  defp field(value) when is_binary(value), do: value
  defp field(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp field({:field, value}), do: field(value)
  defp field(_), do: nil

  defp contains_grouping?({:grouping, _}), do: true

  defp contains_grouping?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&contains_grouping?/1)

  defp contains_grouping?(value) when is_list(value), do: Enum.any?(value, &contains_grouping?/1)
  defp contains_grouping?(_), do: false

  defp order([], _selectors, _selecto), do: {:ok, []}

  defp order(orders, selectors, selecto) do
    orders
    |> Enum.reduce_while({:ok, []}, fn order, {:ok, clauses} ->
      {selector, direction} =
        case order do
          {direction, selector} when direction in @directions -> {selector, direction}
          {selector, direction} when direction in @directions -> {selector, direction}
          selector -> {selector, :asc_nulls_first}
        end

      case position(selector, selectors, selecto) do
        nil ->
          {:halt, :error}

        position ->
          column = qid(selecto, Sql.projection_alias(position))
          {:cont, {:ok, clauses ++ [order_clause(column, direction)]}}
      end
    end)
    |> case do
      {:ok, clauses} -> {:ok, [" ORDER BY ", Enum.intersperse(clauses, ", ")]}
      :error -> :error
    end
  end

  defp position({:literal_position, position}, selectors, _selecto)
       when is_integer(position) and position > 0,
       do: if(position <= length(selectors), do: position)

  defp position(selector, selectors, selecto) do
    selectors
    |> Enum.with_index(1)
    |> Enum.find_value(fn {selected, index} ->
      if selector == selected or selector == unalias(selected) or
           (is_binary(selector) and selector == selector_alias(selecto, selected)),
         do: index
    end)
  end

  defp unalias({:field, expression, _}), do: expression
  defp unalias(expression), do: expression

  # PostgreSQL's placement: an explicit ASC puts NULLs last and DESC first; a
  # bare rollup term is ASC NULLS FIRST (Selecto's rollup default). Both
  # servers sort NULL first ascending and last descending.
  defp order_clause(column, :asc), do: ["(", column, " IS NULL) ASC, ", column, " ASC"]
  defp order_clause(column, :asc_nulls_first), do: [column, " ASC"]
  defp order_clause(column, :desc), do: ["(", column, " IS NULL) DESC, ", column, " DESC"]

  defp order_clause(column, :desc_nulls_first),
    do: ["(", column, " IS NULL) DESC, ", column, " DESC"]

  defp order_clause(column, :asc_nulls_last), do: ["(", column, " IS NULL) ASC, ", column, " ASC"]
  defp order_clause(column, :desc_nulls_last), do: [column, " DESC"]

  defp pagination(set) do
    limit = Map.get(set, :limit)
    offset = Map.get(set, :offset)

    cond do
      not ((is_nil(limit) or (is_integer(limit) and limit >= 0)) and
               (is_nil(offset) or (is_integer(offset) and offset >= 0))) ->
        :error

      is_nil(limit) and is_nil(offset) ->
        {:ok, []}

      is_nil(limit) ->
        {:ok, [" LIMIT 18446744073709551615 OFFSET ", {:param, offset}]}

      is_nil(offset) ->
        {:ok, [" LIMIT ", {:param, limit}]}

      true ->
        {:ok, [" LIMIT ", {:param, limit}, " OFFSET ", {:param, offset}]}
    end
  end

  defp qid(selecto, identifier), do: selecto.adapter.quote_identifier(identifier)
end
