defmodule Selecto.Helpers.Date do
  @moduledoc """
  Date helper functions for Selecto.

  Uses half-open intervals (>= start AND < end) for datetime ranges
  to avoid precision issues with timestamps.
  """

  # Handle nil case when regex doesn't match
  defp expand_date(nil) do
    # Default to today if pattern doesn't match
    start = today_start()
    {start, shift_days(start, 1)}
  end

  defp expand_date(%{"year" => year, "month" => "", "day" => ""}) do
    start = date_start(String.to_integer(year), 1, 1)
    # Use start of next year instead of end of current year
    stop = shift_months(start, 12)
    {start, stop}
  end

  defp expand_date(%{"year" => year, "month" => month, "day" => ""}) do
    start = date_start(String.to_integer(year), String.to_integer(month), 1)

    # Use start of next month instead of end of current month
    stop = shift_months(start, 1)
    {start, stop}
  end

  defp expand_date(%{"year" => year, "month" => month, "day" => day}) do
    start =
      date_start(String.to_integer(year), String.to_integer(month), String.to_integer(day))

    # Use start of next day instead of end of current day
    stop = shift_days(start, 1)
    {start, stop}
  end

  # Catch-all for unexpected input
  defp expand_date(_other) do
    # Default to today if pattern doesn't match expected format
    start = today_start()
    {start, shift_days(start, 1)}
  end

  # Convert various date formats to DateTime
  defp proc_date(%NaiveDateTime{} = date) do
    DateTime.from_naive!(date, "Etc/UTC")
  end

  defp proc_date(%DateTime{} = date) do
    date
  end

  defp proc_date(date) when is_binary(date) do
    date =
      cond do
        Regex.match?(~r/Z$/, date) -> date
        # Weird...
        Regex.match?(~r/\d\d:\d\d:\d\d/, date) -> date <> "Z"
        Regex.match?(~r/\d\d:\d\d/, date) -> date <> ":00Z"
        true -> date
      end

    # IO.inspect(date, label: "Parsing...")
    {:ok, value, _} = DateTime.from_iso8601(date)
    value
  end

  def val_to_dates(%{"value" => "today", "value2" => ""}) do
    start = today_start()
    # Use start of tomorrow instead of end of today
    {start, shift_days(start, 1)}
  end

  def val_to_dates(%{"value" => "tomorrow", "value2" => ""}) do
    start = today_start() |> shift_days(1)
    # Use start of day after tomorrow
    {start, shift_days(start, 1)}
  end

  def val_to_dates(%{"value" => "yesterday", "value2" => ""}) do
    start = today_start() |> shift_days(-1)
    # Use start of today
    {start, shift_days(start, 1)}
  end

  def val_to_dates(%{"value" => "this_week", "value2" => ""}) do
    start = Date.utc_today() |> beginning_of_week() |> start_of_day()
    # Use start of next week
    {start, shift_days(start, 7)}
  end

  def val_to_dates(%{"value" => "last_week", "value2" => ""}) do
    start = Date.utc_today() |> Date.add(-7) |> beginning_of_week() |> start_of_day()
    # Use start of this week
    {start, shift_days(start, 7)}
  end

  def val_to_dates(%{"value" => "this_month", "value2" => ""}) do
    today = Date.utc_today()
    start = date_start(today.year, today.month, 1)
    # Use start of next month
    {start, shift_months(start, 1)}
  end

  def val_to_dates(%{"value" => "last_month", "value2" => ""}) do
    today = Date.utc_today()
    start = date_start(today.year, today.month, 1) |> shift_months(-1)
    # Use start of this month
    {start, shift_months(start, 1)}
  end

  def val_to_dates(%{"value" => "this_year", "value2" => ""}) do
    start = date_start(Date.utc_today().year, 1, 1)
    # Use start of next year
    {start, shift_months(start, 12)}
  end

  def val_to_dates(%{"value" => "last_year", "value2" => ""}) do
    start = date_start(Date.utc_today().year - 1, 1, 1)
    # Use start of this year
    {start, shift_months(start, 12)}
  end

  def val_to_dates(%{"value" => "this_quarter", "value2" => ""}) do
    today = Date.utc_today()
    start = date_start(today.year, quarter_start_month(today.month), 1)
    # Use start of next quarter
    {start, shift_months(start, 3)}
  end

  def val_to_dates(%{"value" => "last_quarter", "value2" => ""}) do
    today = Date.utc_today()
    start = date_start(today.year, quarter_start_month(today.month), 1) |> shift_months(-3)
    # Use start of this quarter
    {start, shift_months(start, 3)}
  end

  def val_to_dates(%{"value" => v1, "value2" => ""}) do
    Regex.named_captures(~r/(?<year>\d{4})-?(?<month>\d{2})?-?(?<day>\d{2})?/, v1)
    |> expand_date()
  end

  def val_to_dates(%{"value" => v1, "value2" => v2}) do
    {proc_date(v1), proc_date(v2)}
  end

  defp today_start, do: Date.utc_today() |> start_of_day()

  defp start_of_day(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp date_start(year, month, day) do
    year
    |> Date.new!(month, day)
    |> start_of_day()
  end

  defp shift_days(datetime, days), do: DateTime.add(datetime, days * 86_400, :second)

  defp shift_months(datetime, months) do
    month_index = datetime.year * 12 + datetime.month - 1 + months
    year = Integer.floor_div(month_index, 12)
    month = Integer.mod(month_index, 12) + 1
    date_start(year, month, 1)
  end

  defp beginning_of_week(date), do: Date.add(date, 1 - Date.day_of_week(date))

  defp quarter_start_month(month), do: div(month - 1, 3) * 3 + 1
end
