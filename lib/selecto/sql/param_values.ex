defmodule Selecto.SQL.ParamValues do
  @moduledoc false

  # Values a dialect would get wrong. Bound anyway, the server stores or
  # compares something else: MySQL and MariaDB take a NaN Decimal as 0, and
  # compare a Decimal needing more than nine 9-digit words (more than 81 integer
  # digits, or 72 after the point; measured live) as another number; MariaDB stores a year past 9999 as
  # a zero date; SQLite keeps a NaN as text and takes a Decimal past the double
  # range as an infinity or 0. Every other value binds as it always did: a
  # Decimal.div result or a 20-digit decimal keeps working. An adapter refuses
  # such a value typed before it is bound, in reads (parameter_placeholder/2)
  # and in writes (where a server rounding a value to its column's scale is
  # the column's own behaviour, so only :finite applies).
  #
  # Rules (keyword list):
  #   decimal: :finite  - finite
  #   decimal: :mysql   - finite, its integer and fraction parts within nine 9-digit words
  #   decimal: :double  - finite, within the double range (a nonzero value stays nonzero)
  #   years: true       - Date, NaiveDateTime and DateTime years in 0..9999
  #   float_atoms: true - :nan, :inf and :"-inf" (PostgreSQL's float specials)

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
    case find(write, rules) do
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

  # Past the double range a value becomes an infinity, or 0.
  defp double_decimal(%Decimal{coef: 0}), do: :ok

  defp double_decimal(decimal) do
    {coefficient, exponent} = stripped(decimal)
    adjusted = length(Integer.digits(coefficient)) + exponent - 1

    if adjusted > 307 or adjusted < -307,
      do: {:error, "cannot bind a decimal beyond the double range", :decimal_range},
      else: :ok
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
