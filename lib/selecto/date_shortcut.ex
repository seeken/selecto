defmodule Selecto.DateShortcut do
  @moduledoc false
  alias Selecto.ReadClock

  @plans %{
    "today" => {{:today, 0, 0}, {:today, 0, 1}},
    "yesterday" => {{:today, 0, -1}, {:today, 0, 0}},
    "tomorrow" => {{:today, 0, 1}, {:today, 0, 2}},
    "this_week" => {{:week, 0, 0}, {:week, 0, 7}},
    "last_week" => {{:week, 0, -7}, {:week, 0, 0}},
    "next_week" => {{:week, 0, 7}, {:week, 0, 14}},
    "this_month" => {{:month, 0, 0}, {:month, 1, 0}},
    "last_month" => {{:month, -1, 0}, {:month, 0, 0}},
    "next_month" => {{:month, 1, 0}, {:month, 2, 0}},
    "mtd" => {{:month, 0, 0}, {:today, 0, 1}},
    "this_quarter" => {{:quarter, 0, 0}, {:quarter, 3, 0}},
    "last_quarter" => {{:quarter, -3, 0}, {:quarter, 0, 0}},
    "next_quarter" => {{:quarter, 3, 0}, {:quarter, 6, 0}},
    "qtd" => {{:quarter, 0, 0}, {:today, 0, 1}},
    "this_year" => {{:year, 0, 0}, {:year, 12, 0}},
    "last_year" => {{:year, -12, 0}, {:year, 0, 0}},
    "next_year" => {{:year, 12, 0}, {:year, 24, 0}},
    "ytd" => {{:year, 0, 0}, {:today, 0, 1}},
    "last_7_days" => {{:today, 0, -6}, {:today, 0, 1}},
    "last_14_days" => {{:today, 0, -13}, {:today, 0, 1}},
    "last_30_days" => {{:today, 0, -29}, {:today, 0, 1}},
    "last_90_days" => {{:today, 0, -89}, {:today, 0, 1}},
    "next_7_days" => {{:today, 0, 1}, {:today, 0, 8}},
    "next_30_days" => {{:today, 0, 1}, {:today, 0, 31}},
    "last_3_months" => {{:month, -3, 0}, {:today, 0, 1}},
    "this_and_last_month" => {{:month, -1, 0}, {:month, 1, 0}},
    "this_and_last_year" => {{:year, -12, 0}, {:year, 12, 0}}
  }
  def compile(query, field, shortcut) do
    today = ReadClock.date(query)

    case Map.get(@plans, to_string(shortcut)) do
      {start, finish} ->
        lower = NaiveDateTime.new!(anchor(today, start), ~T[00:00:00])
        upper = NaiveDateTime.new!(anchor(today, finish), ~T[00:00:00])
        Selecto.TemporalPeriod.compile_bounds(query, field, {lower, upper, false})

      nil ->
        recurring(query, field, to_string(shortcut), today)
    end
  end

  defp recurring(query, field, shortcut, today)
       when shortcut in ~w(mtd_all_years qtd_all_years ytd_all_years) do
    key =
      %{"mtd_all_years" => :month, "qtd_all_years" => :quarter, "ytd_all_years" => :year}[
        shortcut
      ]

    start = anchor(today, {key, 0, 0})
    {column, joins, params} = Selecto.Builder.Sql.Select.prep_selector(query, field)
    expression = ReadClock.render!(query, :month_day, column, "integer")

    {List.wrap(joins),
     [
       "(",
       expression,
       " >= ",
       {:param, start.month * 100 + start.day},
       " AND ",
       expression,
       " <= ",
       {:param, today.month * 100 + today.day},
       ")"
     ], params ++ params}
  end

  defp recurring(_, _, _, _), do: ReadClock.invalid!("unsupported date shortcut")

  defp anchor(today, {kind, months, days}) do
    date =
      case kind do
        :today -> today
        :week -> Date.add(today, 1 - Date.day_of_week(today))
        :month -> Date.beginning_of_month(today)
        :quarter -> Date.new!(today.year, div(today.month - 1, 3) * 3 + 1, 1)
        :year -> Date.new!(today.year, 1, 1)
      end

    date |> Date.shift(month: months) |> Date.add(days)
  end
end
