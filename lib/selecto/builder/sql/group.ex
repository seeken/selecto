defmodule Selecto.Builder.Sql.Group do
  @moduledoc """
  GROUP BY clause builder for Selecto queries.

  Group expressions are compiled through `Selecto.Builder.Sql.Select` and can be
  emitted either as standard grouped columns or wrapped in SQL `ROLLUP(...)`,
  `CUBE(...)` or `GROUPING SETS (...)`.
  """

  alias Selecto.AdapterSQL

  def group(selecto, rollup: groups) do
    {joins, clauses_iodata, params} = group(selecto, groups)

    {joins, AdapterSQL.rollup_sql(selecto, clauses_iodata), params}
  end

  def group(selecto, cube: groups) do
    {joins, clauses_iodata, params} = group(selecto, groups)

    {joins, AdapterSQL.cube_sql(selecto, clauses_iodata), params}
  end

  # Each set is compiled on its own; `[]` is the grand total, `()`.
  def group(selecto, grouping_sets: sets) do
    {joins, clauses, params} =
      Enum.reduce(sets, {[], [], []}, fn
        [], {joins, clauses, params} ->
          {joins, ["()" | clauses], params}

        set, {joins, clauses, params} ->
          {j, c, p} = group(selecto, set)
          {[j | joins], [["(", c, ")"] | clauses], Enum.reverse(p, params)}
      end)

    {Enum.reverse(joins),
     AdapterSQL.grouping_sets_sql(selecto, Enum.intersperse(Enum.reverse(clauses), ", ")),
     Enum.reverse(params)}
  end

  def group(selecto, {:grouping_set, groups}) do
    {joins, clauses_iodata, params} = group(selecto, groups)
    {joins, ["(", clauses_iodata, ")"], params}
  end

  def group(selecto, groups) when is_list(groups) do
    {joins, clauses_iodata, params} =
      groups
      |> Enum.reduce(
        {[], [], []},
        fn g, {joins, clauses, params} ->
          {j, c, p} = group(selecto, g)
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

  # A dialect without positional GROUP BY (`group_by_position: :expression`)
  # would read the number as a constant, so it groups by the selected
  # expression at that position instead.
  def group(selecto, {:literal_position, position} = group_by) when is_integer(position) do
    case Selecto.DialectSupport.query_strategy(selecto.adapter, :group_by_position, selecto) do
      :expression -> group(selecto, selected_at!(selecto, position))
      _ -> group_expression(selecto, group_by)
    end
  end

  def group(selecto, group_by), do: group_expression(selecto, group_by)

  def build(selecto) do
    group(selecto, selecto.set.group_by)
  end

  defp group_expression(selecto, group_by) do
    {c, j, p, _a} = Selecto.Builder.Sql.Select.build(selecto, group_by)

    case Selecto.Builder.Sql.Select.selected_position(selecto, group_by, p) do
      nil -> {j, c, p}
      position -> {j, [Integer.to_string(position)], []}
    end
  end

  defp selected_at!(selecto, position) do
    selected = List.wrap(get_in(selecto, [Access.key(:set), :selected]))

    if position >= 1 and position <= length(selected),
      do: Enum.at(selected, position - 1),
      else: raise(ArgumentError, "GROUP BY position #{position} is not a selected column")
  end
end
