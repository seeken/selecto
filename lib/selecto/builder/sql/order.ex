defmodule Selecto.Builder.Sql.Order do
  @moduledoc """
  ORDER BY clause builder for Selecto queries.

  Supports field/function selectors, explicit sort directions with NULL handling,
  and CASE-based ordering expressions. Returns join dependencies, iodata SQL
  fragments, and bind parameters for the ordering clause.
  """

  alias Selecto.AdapterSQL

  @dirs %{
    asc: "asc",
    desc: "desc",
    asc_nulls_first: "asc nulls first",
    asc_nulls_last: "asc nulls last",
    desc_nulls_first: "desc nulls first",
    desc_nulls_last: "desc nulls last"
  }

  @dir_list [
    :asc,
    :desc,
    :asc_nulls_first,
    :asc_nulls_last,
    :desc_nulls_first,
    :desc_nulls_last
  ]

  # Handle CASE expressions in ORDER BY
  def order(selecto, {:case, when_clauses, else_clause}) when is_list(when_clauses) do
    {case_iodata, joins, params} = build_order_case_expression(selecto, when_clauses, else_clause)
    {joins, case_iodata, params}
  end

  def order(selecto, {:case, when_clauses}) when is_list(when_clauses) do
    order(selecto, {:case, when_clauses, nil})
  end

  # Handle CASE with direction: {{:case, ...}, :asc}
  def order(selecto, {{:case, when_clauses, else_clause}, dir})
      when dir in @dir_list and is_list(when_clauses) do
    {case_iodata, joins, params} = build_order_case_expression(selecto, when_clauses, else_clause)

    if null_term?(selecto, dir),
      do: {joins, null_clause(case_iodata, case_iodata, dir), params ++ params},
      else: {joins, build_order_clause(selecto, case_iodata, dir), params}
  end

  def order(selecto, {{:case, when_clauses}, dir})
      when dir in @dir_list and is_list(when_clauses) do
    order(selecto, {{:case, when_clauses, nil}, dir})
  end

  def order(selecto, {dir, order}) when dir in @dir_list, do: ordered(selecto, order, dir)

  # Handle {field, direction} format which is the standard in this codebase
  def order(selecto, {order, dir}) when dir in @dir_list, do: ordered(selecto, order, dir)

  def order(selecto, order_by) do
    order(selecto, {:asc_nulls_first, order_by})
  end

  def build(selecto) do
    {joins, clauses_iodata, params} =
      selecto.set.order_by
      |> Enum.reduce(
        {[], [], []},
        fn g, {joins, clauses, params} ->
          {j, c, p} = order(selecto, g)
          {[j | joins], [c | clauses], Enum.reverse(p, params)}
        end
      )

    joins = Enum.reverse(joins)
    clauses_iodata = Enum.reverse(clauses_iodata)
    params = Enum.reverse(params)

    # Join clauses with ", " separator as iodata
    clause_parts = Enum.intersperse(clauses_iodata, ", ")
    {joins, clause_parts, params}
  end

  # Build CASE expression for ORDER BY clause
  defp build_order_case_expression(selecto, when_clauses, else_clause) do
    alias Selecto.Builder.Sql.Where
    # alias Selecto.Builder.Sql.Select

    # Collect joins and params from all parts
    {when_parts, all_joins, all_params} =
      when_clauses
      |> Enum.reduce({[], [], []}, fn {condition, result}, {parts_acc, joins_acc, params_acc} ->
        # Build the condition - use standard WHERE builder  
        {cond_joins, cond_iodata, cond_params} = Where.build(selecto, condition)

        # Build the result (typically a number for ordering)
        result_iodata =
          case result do
            r when is_number(r) -> [{:param, r}]
            r when is_binary(r) -> [{:param, r}]
            nil -> ["NULL"]
          end

        result_params =
          case result do
            r when is_number(r) or is_binary(r) -> [r]
            _ -> []
          end

        when_part = ["WHEN ", cond_iodata, " THEN ", result_iodata]

        {parts_acc ++ [when_part], joins_acc ++ List.wrap(cond_joins),
         params_acc ++ cond_params ++ result_params}
      end)

    # Build ELSE clause
    {else_iodata, else_params} =
      case else_clause do
        nil -> {[], []}
        e when is_number(e) -> {[" ELSE ", {:param, e}], [e]}
        e when is_binary(e) -> {[" ELSE ", {:param, e}], [e]}
      end

    case_iodata = ["CASE ", Enum.intersperse(when_parts, " ")] ++ else_iodata ++ [" END"]

    {case_iodata, all_joins, all_params ++ else_params}
  end

  defp ordered(selecto, order, dir) do
    if null_term?(selecto, dir) do
      null_placed(selecto, order, dir)
    else
      {c, j, p} = build_order_selector(selecto, order)
      {j, build_order_clause(selecto, c, dir), p}
    end
  end

  # A NULL-placement term needs the expression itself: `1 IS NULL` would test
  # the literal, not the selected column at position 1. No term ever names an
  # output alias: MySQL resolves an identifier inside an ORDER BY expression
  # against the FROM tables first, so an alias would read a same-named hidden
  # column instead (an existence/NULLness oracle).
  #
  # Under GROUP BY the term tests MIN(expression) for every grouped key that
  # is not itself an aggregate. MySQL's ONLY_FULL_GROUP_BY does not match a
  # repeated computed expression (upper(name), a `?` literal) to its grouped
  # item, but admits an aggregate of it; MIN over a group that is constant in
  # the expression is that value, and NULL exactly when the group's key is
  # NULL. A selected key keeps its select-list position as the sort key.
  # ROLLUP's super-aggregate rows break that equality: a plain grouped column
  # is tested directly there, and anything else is refused.
  defp null_placed(selecto, {:literal_position, position}, dir) when is_integer(position) do
    key = [Integer.to_string(position)]

    cond do
      not postgresql_null_order?(selecto) ->
        {[], [key, " ", plain_direction(dir)], []}

      # A set-operation result has no FROM scope; its operands name every
      # projection `selecto_projection_<n>` (Builder.Sql), and that is the only
      # name its ORDER BY can resolve.
      Selecto.Builder.SetOperations.has_set_operations?(selecto) ->
        {[], null_clause(projection_name(selecto, position), key, dir), []}

      true ->
        case Enum.at(Map.get(selecto.set, :selected, []), position - 1) do
          nil ->
            refuse_null_order(position)

          selected ->
            {c, j, p, _alias} = Selecto.Builder.Sql.Select.build(selecto, selected)
            placed(selecto, selected, {c, j, p}, {key, []}, dir)
        end
    end
  end

  defp null_placed(selecto, order, dir) do
    {c, j, p} = build_order_selector(selecto, order, false)

    key =
      case grouped?(selecto) && selected_index(selecto, order) do
        index when is_integer(index) -> {[Integer.to_string(index)], []}
        _ -> nil
      end

    placed(selecto, order, {c, j, p}, key, dir)
  end

  defp placed(selecto, selector, {c, j, p}, key, dir) do
    cond do
      not grouped?(selecto) or aggregate?(selector) ->
        {sort, sort_params} = key || {c, p}
        {j, null_clause(c, sort, dir), p ++ sort_params}

      rollup?(selecto) ->
        if p == [] and plain_column?(c) do
          {sort, sort_params} = key || {c, p}
          {j, null_clause(c, sort, dir), p ++ sort_params}
        else
          refuse_null_order(selector)
        end

      true ->
        test = ["MIN(", c, ")"]
        {sort, sort_params} = key || {test, p}
        {j, null_clause(test, sort, dir), p ++ sort_params}
    end
  end

  defp selected_index(selecto, order) do
    case Enum.find_index(Map.get(selecto.set, :selected, []), &(&1 == order)) do
      nil -> nil
      index -> index + 1
    end
  end

  @aggregates ~w(count count_distinct sum avg min max stddev variance string_agg array_agg json_agg jsonb_agg bool_and bool_or every)

  defp aggregate?({:field, inner, _alias}), do: aggregate?(inner)
  defp aggregate?({:as, inner, _alias}), do: aggregate?(inner)
  defp aggregate?({name, _args}) when is_atom(name), do: Atom.to_string(name) in @aggregates

  defp aggregate?({:func, name, _args}) when is_binary(name) or is_atom(name),
    do: name |> to_string() |> String.downcase() |> then(&(&1 in @aggregates))

  defp aggregate?(_selector), do: false

  defp plain_column?(iodata) do
    sql = IO.iodata_to_binary(iodata)
    Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\z/, sql)
  rescue
    _ -> false
  end

  defp refuse_null_order(order) do
    raise Selecto.Error.to_exception(
            Selecto.Error.validation_error(
              "PostgreSQL NULL placement cannot be expressed for this ordering",
              %{order: inspect(order), unsupported_feature: :null_ordering}
            )
          )
  end

  defp grouped?(selecto), do: Map.get(selecto.set, :group_by, []) != []

  defp rollup?(selecto),
    do: Enum.any?(Map.get(selecto.set, :group_by, []), &match?({:rollup, _}, &1))

  defp projection_name(selecto, position),
    do:
      Selecto.Builder.Sql.Helpers.force_quote_identifier(
        selecto,
        Selecto.Builder.Sql.projection_alias(position)
      )

  @doc false
  # True when a set-operation ORDER BY needs a NULL-placement term, so the
  # operands must name their projections `selecto_projection_<n>`.
  def set_projection_aliases?(selecto, order_by) do
    postgresql_null_order?(selecto) and not native_null_ordering?(selecto) and
      Enum.any?(order_by, fn entry ->
        case order_entry(entry) do
          {_order, dir} -> null_term?(selecto, dir)
          nil -> false
        end
      end)
  end

  defp order_entry({dir, order}) when dir in @dir_list, do: {order, dir}
  defp order_entry({order, dir}) when dir in @dir_list, do: {order, dir}
  defp order_entry(order) when is_binary(order) or is_atom(order), do: {order, :asc_nulls_first}
  defp order_entry({:literal_position, _} = order), do: {order, :asc_nulls_first}
  defp order_entry(_order), do: nil

  defp null_clause(test, key, dir) when dir in [:asc, :asc_nulls_last],
    do: ["CASE WHEN ", test, " IS NULL THEN 1 ELSE 0 END asc, ", key, " asc"]

  defp null_clause(test, key, dir) when dir in [:desc, :desc_nulls_first],
    do: ["CASE WHEN ", test, " IS NULL THEN 0 ELSE 1 END asc, ", key, " desc"]

  defp plain_direction(dir) when dir in [:asc, :asc_nulls_first, :asc_nulls_last], do: "asc"
  defp plain_direction(_dir), do: "desc"

  defp build_order_selector(selecto, order, allow_position? \\ true)

  defp build_order_selector(selecto, order, allow_position?)
       when is_binary(order) or is_atom(order) do
    {c, j, p} = Selecto.Builder.Sql.Select.prep_selector(selecto, order)

    case allow_position? && Selecto.Builder.Sql.Select.selected_position(selecto, order, p) do
      position when is_integer(position) -> {[Integer.to_string(position)], j, []}
      _ -> {c, j, p}
    end
  end

  defp build_order_selector(selecto, order, _allow_position?) do
    {c, j, p, _a} = Selecto.Builder.Sql.Select.build(selecto, order)
    {c, j, p}
  end

  defp build_order_clause(selecto, order_iodata, dir) do
    if native_null_ordering?(selecto) do
      [order_iodata, " ", @dirs[dir]]
    else
      case dir do
        :asc ->
          [order_iodata, " asc"]

        :desc ->
          [order_iodata, " desc"]

        :asc_nulls_first ->
          [order_iodata, " asc"]

        :desc_nulls_last ->
          [order_iodata, " desc"]

        dir when dir in [:asc_nulls_last, :desc_nulls_first] ->
          null_clause(order_iodata, order_iodata, dir)
      end
    end
  end

  # True when the clause needs a NULL-placement term: an explicit NULLS
  # FIRST/LAST the database cannot spell, or (for `:postgresql_null_order`
  # adapters, MySQL and MariaDB) an unqualified ASC/DESC, which PostgreSQL
  # sorts NULLs last and first respectively.
  defp null_term?(selecto, dir) do
    not native_null_ordering?(selecto) and
      (dir in [:asc_nulls_last, :desc_nulls_first] or
         (dir in [:asc, :desc] and postgresql_null_order?(selecto)))
  end

  defp native_null_ordering?(selecto) do
    AdapterSQL.native_null_ordering?(selecto)
  end

  defp postgresql_null_order?(selecto) do
    Selecto.AdapterSupport.supports_feature?(AdapterSQL.adapter(selecto), :postgresql_null_order)
  end
end
