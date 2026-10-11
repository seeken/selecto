defmodule Selecto.Rule.Budget do
  @moduledoc false

  defmodule Limit do
    @moduledoc false
    defexception message: "portable rule evaluation limit exceeded"
  end

  @work 2_000_000
  @bytes 4096
  @text_bytes 16_384
  @items 1000
  @max_integer String.duplicate("9", @bytes) |> String.to_integer()

  # Decimal 3 defaults to decimal128 limits: parsing stops at 34 significant
  # digits and arithmetic rounds to 34. Rule numbers are already bounded by
  # @bytes (see number/2), so parsing and arithmetic are sized from that bound
  # instead. Selecto's own refusals remain the only effective cap, and any
  # operation that would still round refuses rather than return an inexact
  # result. Two admitted operands align to at most 2 * @bytes digits.
  @exact_digits 2 * @bytes + 2
  @exact_context %Decimal.Context{
    precision: @exact_digits,
    emax: @exact_digits,
    emin: -@exact_digits,
    traps: [:invalid_operation, :division_by_zero, :inexact, :overflow, :underflow]
  }

  # One invocation owns this in-memory counter. It is never stored in the
  # process dictionary, returned in results, or shared with another invocation.
  def new do
    counter = :atomics.new(1, signed: true)
    :atomics.put(counter, 1, @work)
    counter
  end

  def spend(counter, amount \\ 1) when is_integer(amount) and amount >= 0 do
    if amount > @work or :atomics.sub_get(counter, 1, amount) < 0, do: refuse()
    :ok
  end

  def refuse, do: raise(Limit)

  def artifact(value, counter), do: value(value, counter, 0, 64)

  def value(value, counter, depth \\ 0, maximum_depth \\ 32) do
    spend(counter)
    if depth > maximum_depth, do: refuse()
    check(value, counter, depth, maximum_depth)
  end

  def text(value, counter) do
    if byte_size(value) > @text_bytes or not String.valid?(value), do: refuse()
    spend(counter, byte_size(value))
  end

  def pattern_text(value, counter) do
    if byte_size(value) > @bytes, do: refuse()
    text(value, counter)
  end

  def number(%Decimal{coef: coef, exp: exponent, sign: sign}, counter)
      when is_integer(coef) and coef >= 0 and is_integer(exponent) and sign in [-1, 1] do
    integer(coef, counter)
    if abs(exponent) > @bytes, do: refuse()
    digits = byte_size(Integer.to_string(coef))
    size = if exponent < 0, do: max(digits, 1 - exponent) + 2, else: digits + exponent
    if size + if(sign < 0, do: 1, else: 0) > @bytes, do: refuse()
    spend(counter, size)
    size
  end

  def number(_value, _counter), do: refuse()

  # Callers bound the text first (pattern_text/2); this keeps Decimal's parse
  # limits at that same bound rather than the decimal128 default.
  def parse_number(text) when is_binary(text) do
    case Decimal.parse(text, max_digits: @bytes, max_exponent: @bytes) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  # Runs Decimal arithmetic on operands already admitted by number/2.
  def exact(fun) when is_function(fun, 0) do
    Decimal.Context.with(@exact_context, fun)
  rescue
    Decimal.Error -> refuse()
  end

  def arithmetic(left, right, counter, kind) do
    a = number(left, counter)
    b = number(right, counter)
    spend(counter, if(kind == :remainder, do: a * b, else: a + b + abs(left.exp - right.exp)))
  end

  defp integer(value, counter) do
    # Compare before decimal conversion: a caller-provided huge integer must
    # not enter Integer.to_string/1 or arbitrary-precision decimal arithmetic.
    if value > @max_integer or value < -@max_integer, do: refuse()
    spend(counter, byte_size(Integer.to_string(value)))
  end

  defp check(value, counter, _depth, _maximum) when is_binary(value), do: text(value, counter)
  defp check(value, counter, _depth, _maximum) when is_integer(value), do: integer(value, counter)
  defp check(%Decimal{} = value, counter, _depth, _maximum), do: number(value, counter)

  defp check(value, counter, depth, maximum) when is_list(value) do
    check_list(value, counter, depth, maximum, 0)
  end

  defp check(value, counter, depth, maximum) when is_map(value) do
    if map_size(value) > @items, do: refuse()

    Enum.each(Map.to_list(value), fn {key, child} ->
      cond do
        is_binary(key) -> text(key, counter)
        is_atom(key) -> :ok
        true -> refuse()
      end

      value(child, counter, depth + 1, maximum)
    end)
  end

  defp check(_value, _counter, _depth, _maximum), do: :ok

  defp check_list([], _counter, _depth, _maximum, _count), do: :ok
  defp check_list([_child | _tail], _counter, _depth, _maximum, @items), do: refuse()

  defp check_list([child | tail], counter, depth, maximum, count) do
    value(child, counter, depth + 1, maximum)
    check_list(tail, counter, depth, maximum, count + 1)
  end
end
