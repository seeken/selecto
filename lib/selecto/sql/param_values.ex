defmodule Selecto.SQL.ParamValues do
  @moduledoc false

  # Values a dialect would get wrong. Bound anyway, the server stores or
  # compares something else: MySQL and MariaDB take a NaN Decimal as 0, and
  # compare a Decimal needing more than nine 9-digit words (more than 81 integer
  # digits, or 72 after the point; measured live) as another number; MariaDB stores a year past 9999 as
  # a zero date; SQLite keeps a NaN as text and takes a Decimal that overflows
  # a double as an infinity, and a nonzero one that underflows as 0. Every other value binds as it always did: a
  # Decimal.div result or a 20-digit decimal keeps working. An adapter refuses
  # such a value typed before it is bound, in reads (parameter_placeholder/2)
  # and in writes (where a server rounding a value to its column's scale is
  # the column's own behaviour, so only :finite applies).
  #
  # Rules (keyword list):
  #   decimal: :finite  - finite
  #   decimal: :mysql   - finite, its integer and fraction parts within nine 9-digit words
  #   decimal: :double  - finite, neither overflowing a double nor a nonzero value underflowing to 0
  #   years: true       - Date, NaiveDateTime and DateTime years in 0..9999
  #   float_atoms: true - :nan, :inf and :"-inf" (PostgreSQL's float specials)
  #   uuid_text: true   - writes only: a :uuid field's text must read as a UUID

  alias Selecto.Builder.ScopeRefusal

  @float_atoms [:nan, :inf, :"-inf"]

  @doc false
  @spec check(term(), keyword()) :: :ok | {:error, String.t(), atom()}
  def check(%Decimal{coef: coef} = decimal, rules) do
    case Keyword.get(rules, :decimal) do
      nil -> :ok
      _rule when not is_integer(coef) -> non_finite()
      :finite -> :ok
      :mysql -> mysql_decimal(decimal)
      :double -> double_decimal(decimal)
    end
  end

  def check(%module{year: year}, rules) when module in [Date, NaiveDateTime, DateTime] do
    if Keyword.get(rules, :years, false) and year not in 0..9999,
      do: {:error, "cannot bind a date or datetime outside the years 0 to 9999", :date_range},
      else: :ok
  end

  def check(value, rules) when value in @float_atoms do
    if Keyword.get(rules, :float_atoms, false),
      do: {:error, "cannot bind a NaN or infinite float parameter", :float_non_finite},
      else: :ok
  end

  def check(_value, _rules), do: :ok

  @doc false
  # Raises the read-side refusal (typed through every execute entry point).
  def refuse!(value, rules, adapter) do
    case check(value, rules) do
      :ok -> :ok
      {:error, message, feature} -> refusal!(adapter, message, feature)
    end
  end

  @doc false
  # The first value of a write (its assignments, predicate, batch commands or
  # graph nodes, walked through) the dialect cannot bind, as a write error.
  @spec write_refusal(term(), keyword(), atom()) :: :ok | {:error, Selecto.Write.Error.t()}
  def write_refusal(write, rules, adapter) do
    found =
      find(write, rules) ||
        if(Keyword.get(rules, :uuid_text, false), do: uuid_refusal(write))

    case found do
      nil ->
        :ok

      {message, feature} ->
        {:error,
         Selecto.Write.Error.new(:invalid_value, adapter_label(adapter) <> " " <> message,
           details: %{
             adapter: adapter,
             unsupported_feature: feature,
             reason: :parameter_unbindable
           }
         )}
    end
  end

  # A :uuid field (by the command's metadata field_types, or its graph node's)
  # written as text must read as a UUID, as a read filter's text must (it
  # binds as given).
  defp uuid_refusal(%Selecto.Write.Batch{commands: commands}),
    do: Enum.find_value(commands, &uuid_refusal/1)

  defp uuid_refusal(%Selecto.Write.Graph{nodes: nodes}) do
    Enum.find_value(nodes, fn
      %Selecto.Write.Graph.Node{rows: rows, field_types: types} when is_list(rows) ->
        Enum.find_value(rows, fn
          %Selecto.Write.Graph.Row{command: %Selecto.Write.Command{} = command} ->
            uuid_refusal(command, types)

          _row ->
            nil
        end)

      _node ->
        nil
    end)
  end

  defp uuid_refusal(%Selecto.Write.Command{} = command), do: uuid_refusal(command, %{})

  defp uuid_refusal(_write), do: nil

  defp uuid_refusal(%Selecto.Write.Command{assignments: assignments, metadata: metadata}, extra) do
    types = Map.merge(extra || %{}, Map.get(metadata || %{}, :field_types) || %{})

    Enum.find_value(assignments, fn
      %{field: field, value: {:literal, value}} when is_binary(value) ->
        if uuid_field?(types, field) and not uuid_text?(value),
          do: {"cannot write text that is no UUID to a :uuid field", :uuid_text}

      _assignment ->
        nil
    end)
  end

  defp uuid_field?(types, field),
    do:
      Enum.any?(types, fn {key, type} ->
        to_string(key) == to_string(field) and type in [:uuid, "uuid"]
      end)

  defp uuid_text?(value) do
    String.valid?(value) and byte_size(value) != 16 and
      match?({:ok, _}, UUID.info(value))
  end

  defp find(%Decimal{} = value, rules), do: found(value, rules)
  defp find(%Date{} = value, rules), do: found(value, rules)
  defp find(%NaiveDateTime{} = value, rules), do: found(value, rules)
  defp find(%DateTime{} = value, rules), do: found(value, rules)
  defp find(value, rules) when is_atom(value), do: found(value, rules)
  defp find(value, rules) when is_struct(value), do: value |> Map.from_struct() |> find(rules)
  defp find(value, rules) when is_map(value), do: Enum.find_value(value, &find(&1, rules))
  defp find(value, rules) when is_tuple(value), do: value |> Tuple.to_list() |> find(rules)

  defp find(value, rules) when is_list(value) do
    if List.improper?(value), do: nil, else: Enum.find_value(value, &find(&1, rules))
  end

  defp find(_value, _rules), do: nil

  defp found(value, rules) do
    case check(value, rules) do
      :ok -> nil
      {:error, message, feature} -> {message, feature}
    end
  end

  defp refusal!(adapter, message, feature) do
    ScopeRefusal.unsupported!(
      Selecto.Error.validation_error(adapter_label(adapter) <> " " <> message, %{
        adapter: adapter,
        unsupported_feature: feature
      }),
      :parameter_unbindable
    )
  end

  defp non_finite,
    do: {:error, "cannot bind a NaN or infinite decimal parameter", :decimal_non_finite}

  defp adapter_label(:mysql), do: "MySQL"
  defp adapter_label(:mariadb), do: "MariaDB"
  defp adapter_label(:sqlite), do: "SQLite"
  defp adapter_label(:duckdb), do: "DuckDB"
  defp adapter_label(adapter), do: to_string(adapter)

  # DECIMAL(65,30): at most 65 digits, 30 of them after the point.
  # MySQL and MariaDB read a decimal into nine 9-digit words, its integer and
  # fraction parts each in whole words (an integer part of at least one). A
  # value that needs more is cut, and compares as another number (measured
  # live: 30 integer digits hold 45 after the point, 20 hold 54, none 72; a
  # large negative value compared as positive).
  defp mysql_decimal(decimal) do
    {precision, scale} = digits(decimal)
    words = max(ceil_div(precision - scale, 9), 1) + ceil_div(scale, 9)

    if words > 9,
      do: {:error, "cannot bind a decimal of that many digits", :decimal_range},
      else: :ok
  end

  defp ceil_div(n, d), do: div(n + d - 1, d)

  # A value a double cannot hold becomes an infinity (at or past the midpoint
  # between the largest double and the next power) or 0.0 (a nonzero value at
  # or below half the smallest subnormal). Every other value converts to a
  # finite, nonzero double, as SQLite has always stored and compared it.
  @double_overflow %Decimal{
    sign: 1,
    coef: 1_797_693_134_862_315_807_937_289_714_053_034_150_799_341_327_710_736,
    exp: 257
  }
  @double_underflow %Decimal{sign: 1, coef: 2_470_328_229_206_232_720_882_538_326, exp: -351}

  defp double_decimal(%Decimal{coef: 0}), do: :ok

  defp double_decimal(%Decimal{} = decimal) do
    # Exact: Decimal.abs/1 rounds to the context precision (28 digits).
    magnitude = %{decimal | sign: 1}

    cond do
      Decimal.compare(magnitude, @double_overflow) != :lt ->
        {:error, "cannot bind a decimal that overflows a double", :decimal_range}

      Decimal.compare(magnitude, @double_underflow) != :gt ->
        {:error, "cannot bind a nonzero decimal that underflows a double to 0", :decimal_range}

      true ->
        :ok
    end
  end

  defp digits(%Decimal{coef: 0}), do: {1, 0}

  defp digits(decimal) do
    {coefficient, exponent} = stripped(decimal)
    count = length(Integer.digits(coefficient))
    scale = max(-exponent, 0)
    integer_digits = max(count + exponent, 0)
    {max(integer_digits + scale, 1), scale}
  end

  defp stripped(%Decimal{coef: coefficient, exp: exponent}), do: strip(coefficient, exponent)

  defp strip(coefficient, exponent) when coefficient != 0 and rem(coefficient, 10) == 0,
    do: strip(div(coefficient, 10), exponent + 1)

  defp strip(coefficient, exponent), do: {coefficient, exponent}
end
