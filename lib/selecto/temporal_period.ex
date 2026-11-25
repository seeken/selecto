defmodule Selecto.TemporalPeriod do
  @moduledoc false
  alias Selecto.ReadClock
  alias Selecto.Builder.Sql.Select

  # Parse calendar periods without ever applying a function to the indexed column.
  def bounds!(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{4})(?:-(\d{2})(?:-(\d{2})(?:T(\d{2})(?::(\d{2}))?)?)?)?\z/, value,
           capture: :all_but_first
         ) do
      nil ->
        ReadClock.invalid!("invalid temporal period")

      captures ->
        [y, m, d, h, minute] = captures ++ List.duplicate("", 5 - length(captures))

        with {:ok, date} <- Date.new(String.to_integer(y), number(m, 1), number(d, 1)),
             {:ok, time} <- Time.new(number(h, 0), number(minute, 0), 0) do
          lower = NaiveDateTime.new!(date, time)

          {upper, subday} =
            cond do
              minute != "" -> {NaiveDateTime.add(lower, 60), true}
              h != "" -> {NaiveDateTime.add(lower, 3600), true}
              d != "" -> {NaiveDateTime.add(lower, 86400), false}
              m != "" -> {NaiveDateTime.new!(Date.shift(date, month: 1), time), false}
              true -> {NaiveDateTime.new!(Date.shift(date, year: 1), time), false}
            end

          {lower, upper, subday}
        else
          _ -> ReadClock.invalid!("invalid temporal period")
        end
    end
  end

  def bounds!(_), do: ReadClock.invalid!("temporal period must be a string")
  defp number("", default), do: default
  defp number(value, _), do: String.to_integer(value)

  def compile(query, field, value), do: compile_bounds(query, field, bounds!(value))

  def compile_bounds(query, field, {lower, upper, subday}) do
    conf = Selecto.field(query, field)
    type = to_string(Map.get(conf, :type))

    unless type in ~w(date datetime timestamp utc_datetime utc_datetime_usec naive_datetime timestamptz epoch_datetime) or
             Selecto.Temporal.date_like?(conf),
           do: ReadClock.invalid!("on requires a temporal field")

    if type == "date" and subday, do: ReadClock.invalid!("date fields refuse subday periods")

    instant? =
      type in ~w(utc_datetime utc_datetime_usec timestamptz epoch_datetime) or
        Selecto.Temporal.epoch_storage(conf) != nil

    ranges =
      if instant?, do: instant_ranges(lower, upper, ReadClock.zone(query)), else: [{lower, upper}]

    # A wholly skipped local period remains an empty comparison on the column,
    # so SQL three-valued logic also holds under NOT for NULL values.
    ranges =
      if ranges == [] do
        point = ReadClock.instant(lower |> NaiveDateTime.to_iso8601(), ReadClock.zone(query))
        [{point, point}]
      else
        ranges
      end

    {column, joins, params} = Select.prep_selector(query, field)

    clauses =
      Enum.map(ranges, fn {start, finish} ->
        [
          "(",
          column,
          " >= ",
          bound(query, conf, type, start),
          " AND ",
          column,
          " < ",
          bound(query, conf, type, finish),
          ")"
        ]
      end)

    sql = ["(", Enum.intersperse(clauses, " OR "), ")"]
    {List.wrap(joins), sql, params}
  end

  # Database-clock shortcuts use SQL calendar bounds. Convert only the bound,
  # keeping the indexed storage column untouched (including naive UTC/epochs).
  def compile_sql_bounds(query, field, lower, upper) do
    conf = Selecto.field(query, field)
    type = to_string(Map.get(conf, :type))

    unless Selecto.Temporal.date_like?(conf) or
             type in ~w(date datetime timestamp utc_datetime utc_datetime_usec naive_datetime timestamptz epoch_datetime),
           do: ReadClock.invalid!("date shortcut requires a temporal field")

    epoch = Selecto.Temporal.epoch_storage(conf)

    kind =
      cond do
        epoch == :unix_milliseconds ->
          "epoch_ms"

        type == "epoch_datetime" or epoch != nil ->
          "epoch_seconds"

        type == "date" ->
          "date"

        type in ~w(utc_datetime utc_datetime_usec timestamptz) ->
          if Map.get(conf, :storage) in [:naive_utc, "naive_utc"],
            do: "naive_utc",
            else: "instant"

        true ->
          "datetime"
      end

    zone = Map.get(ReadClock.context(query), :timezone)

    bounds =
      Enum.map([lower, upper], fn value ->
        fragment = %Selecto.Dialect.ComputedValue{
          operation: :calendar_bound,
          expression: value,
          type: kind,
          path: if(zone, do: [{:param, zone}], else: [])
        }

        case Selecto.DialectSupport.render_computed_value(query.adapter, fragment, query) do
          {:ok, sql} -> sql
          {:error, error} -> Selecto.Builder.ScopeRefusal.unsupported!(error)
        end
      end)

    [lower, upper] = bounds
    {column, joins, params} = Select.prep_selector(query, field)

    {List.wrap(joins), ["(", column, " >= ", lower, " AND ", column, " < ", upper, ")"],
     params ++ params}
  end

  defp bound(query, conf, type, value) do
    epoch = Selecto.Temporal.epoch_storage(conf)

    cond do
      type == "epoch_datetime" or epoch != nil ->
        seconds = DateTime.to_unix(value)
        {:param, if(epoch == :unix_milliseconds, do: seconds * 1000, else: seconds)}

      type == "date" ->
        ReadClock.render!(
          query,
          :period_bound,
          {:param, value |> NaiveDateTime.to_date() |> Date.to_iso8601()},
          "date"
        )

      true ->
        value = if is_struct(value, DateTime), do: DateTime.to_naive(value), else: value
        text = value |> NaiveDateTime.to_iso8601() |> String.replace("T", " ")

        instant =
          type in ~w(utc_datetime utc_datetime_usec timestamptz) and
            Map.get(conf, :storage) not in [:naive_utc, "naive_utc"]

        offset? = instant and ReadClock.database_clock?(query)

        ReadClock.render!(
          query,
          :period_bound,
          {:param, text <> if(offset?, do: "+00:00", else: "")},
          if(instant, do: "instant", else: "datetime")
        )
    end
  end

  # Split the UTC interval at every timezone transition. Intersect each offset's
  # local interval, so a folded minute yields two disjoint one-minute ranges.
  def instant_ranges(lower, upper, zone) do
    start = NaiveDateTime.add(lower, -172_800) |> DateTime.from_naive!("Etc/UTC")
    stop = NaiveDateTime.add(upper, 172_800) |> DateTime.from_naive!("Etc/UTC")

    pieces(start, stop, zone, [])
    |> Enum.flat_map(fn {a, b, offset} ->
      lo = lower |> NaiveDateTime.add(-offset) |> DateTime.from_naive!("Etc/UTC")
      hi = upper |> NaiveDateTime.add(-offset) |> DateTime.from_naive!("Etc/UTC")
      lo = if DateTime.compare(a, lo) == :gt, do: a, else: lo
      hi = if DateTime.compare(b, hi) == :lt, do: b, else: hi
      if DateTime.compare(lo, hi) == :lt, do: [{lo, hi}], else: []
    end)
    |> Enum.sort_by(fn {a, _} -> DateTime.to_unix(a) end)
    |> Enum.reduce([], fn {a, b}, acc ->
      case acc do
        [{x, y} | rest] ->
          if DateTime.compare(a, y) != :gt,
            do: [{x, if(DateTime.compare(b, y) == :gt, do: b, else: y)} | rest],
            else: [{a, b} | acc]

        [] ->
          [{a, b}]
      end
    end)
    |> Enum.reverse()
  end

  # Transition search is bounded by the authored period (at most one year).
  defp pieces(start, stop, zone, acc) do
    if DateTime.compare(start, stop) != :lt do
      Enum.reverse(acc)
    else
      next = DateTime.add(start, min(21600, DateTime.diff(stop, start)))
      offset = offset(start, zone)

      if offset(next, zone) == offset do
        pieces(next, stop, zone, [{start, next, offset} | acc])
      else
        transition = transition(start, next, zone, offset)
        pieces(transition, stop, zone, [{start, transition, offset} | acc])
      end
    end
  end

  defp offset(dt, zone) do
    zoned = DateTime.shift_zone!(dt, zone, Tzdata.TimeZoneDatabase)
    zoned.utc_offset + zoned.std_offset
  end

  defp transition(a, b, _zone, _offset) when b == a, do: b

  defp transition(a, b, zone, old) do
    delta = DateTime.diff(b, a)

    if delta <= 1 do
      b
    else
      mid = DateTime.add(a, div(delta, 2))

      if offset(mid, zone) == old,
        do: transition(mid, b, zone, old),
        else: transition(a, mid, zone, old)
    end
  end
end
