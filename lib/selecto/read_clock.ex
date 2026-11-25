defmodule Selecto.ReadClock do
  @moduledoc """
  A validated immutable clock for relative reads. It never changes the database snapshot
  or the clock used by writes. The outer compile owns the clock for nested/set queries.
  """
  @context_key {__MODULE__, :context}

  def bind(query, value) do
    validate!(value)
    put_in(query.set[:as_of], value)
  end

  def validate!(value) when is_binary(value) do
    valid =
      cond do
        Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, value) ->
          match?({:ok, _}, Date.from_iso8601(value))

        Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T/, value) ->
          match?({:ok, _, _}, DateTime.from_iso8601(value))

        true ->
          false
      end

    if valid, do: value, else: invalid!("as_of must be a valid ISO date or offset timestamp")
  end

  def validate!(_), do: invalid!("as_of must be a valid ISO date or offset timestamp")

  def with_context(query, fun) do
    previous = Process.get(@context_key)

    context =
      previous || %{as_of: Map.get(query.set, :as_of), timezone: Map.get(query.set, :timezone)}

    Process.put(@context_key, context)

    try do
      fun.()
    after
      if previous, do: Process.put(@context_key, previous), else: Process.delete(@context_key)
    end
  end

  def context(query), do: Process.get(@context_key) || Map.take(query.set, [:as_of, :timezone])

  def zone(query) do
    case Map.get(context(query), :timezone) do
      nil -> session_zone(query)
      zone -> zone
    end
  end

  defp session_zone(query) do
    connection = Selecto.Runtime.Context.connection(query)

    if Selecto.AdapterSupport.adapter_name(query.adapter) == :postgresql and
         connection not in [nil, :compile_only, :mock_connection] do
      case query.adapter.execute(connection, "SHOW TIME ZONE", [], []) do
        {:ok, %{rows: [[zone]]}} -> zone
        {:ok, {[[zone]], _columns}} -> zone
        _ -> invalid!("cannot resolve PostgreSQL session timezone")
      end
    else
      "Etc/UTC"
    end
  end

  def timezone(query, zone) when is_binary(zone) do
    case DateTime.now(zone, Tzdata.TimeZoneDatabase) do
      {:ok, _} -> put_in(query.set[:timezone], zone)
      _ -> invalid!("unknown query timezone")
    end
  end

  def timezone(_, _), do: invalid!("timezone must be an IANA zone")

  def now_sql(query) do
    case Map.get(context(query), :as_of) do
      nil ->
        "CURRENT_TIMESTAMP"

      value ->
        instant = instant(value, zone(query))
        render!(query, :read_clock, {:param, DateTime.to_iso8601(instant)}, "datetime")
    end
  end

  def date(query) do
    case Map.get(context(query), :as_of) do
      nil ->
        DateTime.now!(zone(query), Tzdata.TimeZoneDatabase) |> DateTime.to_date()

      value when byte_size(value) == 10 ->
        Date.from_iso8601!(value)

      value ->
        value
        |> instant(zone(query))
        |> DateTime.shift_zone!(zone(query), Tzdata.TimeZoneDatabase)
        |> DateTime.to_date()
    end
  end

  def instant(value, zone) when byte_size(value) == 10 do
    naive = NaiveDateTime.new!(Date.from_iso8601!(value), ~T[00:00:00])

    case DateTime.from_naive(naive, zone, Tzdata.TimeZoneDatabase) do
      {:ok, dt} -> dt
      {:ambiguous, first, _} -> first
      {:gap, _, after_gap} -> after_gap
      _ -> invalid!("cannot resolve read clock timezone")
    end
    |> DateTime.shift_zone!("Etc/UTC", Tzdata.TimeZoneDatabase)
  end

  def instant(value, _zone) do
    {:ok, dt, _} = DateTime.from_iso8601(value)
    dt
  end

  def render!(query, operation, expression, type) do
    fragment = %Selecto.Dialect.ComputedValue{
      operation: operation,
      expression: expression,
      type: type
    }

    case Selecto.DialectSupport.render_computed_value(query.adapter, fragment, query) do
      {:ok, sql} -> sql
      {:error, error} -> Selecto.Builder.ScopeRefusal.unsupported!(error)
    end
  end

  def invalid!(message) do
    Selecto.Builder.ScopeRefusal.unsupported!(
      Selecto.Error.validation_error(message, %{code: :invalid_query}),
      :invalid_query
    )
  end
end
