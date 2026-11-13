defmodule SelectoUpdato.QueryEnforcement.Scalar do
  @moduledoc false

  # In-process scalar comparison by the column's declared type
  # (query_enforced_scalar v2, certification specification 2.37, "Scalar
  # comparison by declared type").
  #
  # A comparison is decided only when the evaluator can prove the database
  # (or the MySQL-family host-exact SQL) decides it the same way on the stored
  # row:
  #
  #   * text (with no or a deterministic collation): eq/ne on the UTF-8 bytes,
  #     ranges refused (their order depends on the column collation);
  #   * numeric (integer and decimal bases): exact decimal comparison of finite
  #     ASCII decimals; the candidate must be stored unchanged (length, range,
  #     precision, scale);
  #   * identity (everything else: char(n), citext, uuid, boolean, temporals,
  #     floats, enum, json, custom names, undeclared columns, invalid
  #     parameter lists, nondeterministic collations): only byte-identical
  #     eq/ne is decided.
  #
  # Trust levels (`:verified`, `:base_verified`, `:unverified`) say how much of
  # the declared type is known to be the column's real type. Under
  # `:unverified` nothing is decided; under `:base_verified` only integer
  # bases keep the numeric rule and every other base is identity.
  #
  # Results are `true`, `false`, `:unknown` (SQL NULL) or `:not_evaluable`.
  # `:not_evaluable` is never turned into true or false here: the caller
  # defers to verified storage or refuses.

  # The type classes are the specification's lists, kept as data
  # (priv/query_enforced_scalar_v2_type_classes.json, copied from the harness
  # corpus; a test checks they still match it).
  @classes_path Path.expand("../../../priv/query_enforced_scalar_v2_type_classes.json", __DIR__)
  @external_resource @classes_path
  @classes @classes_path |> File.read!() |> Jason.decode!() |> Map.fetch!("type_classes")

  @text @classes["text"]
  @unbounded @classes["unbounded_length"]
  @char_family @classes["char_family"]
  @integer Map.new(@classes["integer"], fn {name, [low, high]} ->
             {name, {String.to_integer(low), String.to_integer(high)}}
           end)
  @decimal @classes["decimal"]
  @deterministic_any @classes["deterministic_collations"]["any_backend"]
  @mysql_charsets @classes["deterministic_collations"]["mysql_family_only"]["charsets"]
  @temporal @classes["temporal"]
  @time_dependent @classes["time_dependent_inputs"]
  @base_verified_identity @classes["base_verified_identity"]
  @ranges [:gt, :gte, :lt, :lte]

  @type trust :: :verified | :base_verified | :unverified
  @type backend :: :other | :mysql_family
  @type result :: true | false | :unknown | :not_evaluable

  @doc """
  The column descriptor for a declared type name (nil when undeclared).

  Options: `:trust` (default `:unverified`), `:backend` (`:other` or
  `:mysql_family`), and `:deterministic` (the catalog's collation determinism:
  `false` makes the column identity whatever its name, `true` accepts the
  collation the name carries).
  """
  @spec column(String.t() | atom() | nil, keyword()) :: map()
  def column(type, opts \\ []) do
    backend = Keyword.get(opts, :backend, :other)
    declared = parse(type)
    class = classify_declared(declared, backend, Keyword.get(opts, :deterministic))

    %{
      declared: declared,
      class: class,
      trust: Keyword.get(opts, :trust, :unverified),
      backend: backend
    }
  end

  @doc false
  def type_classes, do: @classes

  @doc "The class (`:text`, `:numeric` or `:identity`) of a declared type name."
  @spec classify(String.t() | atom() | nil, backend()) :: :text | :numeric | :identity
  def classify(type, backend \\ :other), do: classify_declared(parse(type), backend, nil)

  @doc """
  `op(actual, expected)` on `column`. Operands are the exact text the runtime
  binds (or nil for SQL NULL). `op` is one of :eq, :ne/:neq, :gt, :gte, :lt,
  :lte, :in and :not_in (expected a list for the last two).
  """
  @spec compare(map(), atom(), String.t() | nil, term()) :: result()
  def compare(column, :in, actual, list) when is_list(list), do: member(column, actual, list)

  def compare(column, :not_in, actual, list) when is_list(list),
    do: negate(member(column, actual, list))

  def compare(column, :neq, actual, expected), do: compare(column, :ne, actual, expected)

  def compare(_column, _op, nil, _expected), do: :unknown

  def compare(column, op, actual, expected) when op in [:eq, :ne, :gt, :gte, :lt, :lte] do
    cond do
      not admissible?(column, actual) -> :not_evaluable
      is_nil(expected) -> :unknown
      true -> compare_values(effective(column), op, actual, expected)
    end
  end

  def compare(_column, _op, _actual, _expected), do: :not_evaluable

  defp member(_column, nil, _list), do: :unknown

  defp member(column, actual, list) do
    if admissible?(column, actual) do
      column = effective(column)
      results = for item <- list, not is_nil(item), do: compare_values(column, :eq, actual, item)

      cond do
        :not_evaluable in results -> :not_evaluable
        true in results -> true
        nil in list -> :unknown
        true -> false
      end
    else
      :not_evaluable
    end
  end

  defp negate(true), do: false
  defp negate(false), do: true
  defp negate(other), do: other

  # base_verified metadata decides only byte-identical operands, except on
  # integer bases, which carry no length, scale or collation.
  defp effective(%{trust: :verified} = column), do: column

  defp effective(%{declared: %{base: base}} = column) do
    if Map.has_key?(@integer, base), do: column, else: %{column | class: :identity}
  end

  ## Declared names

  @doc false
  # Declared name -> %{base, params, collation}; params is a list of integers
  # ([] when absent or `max` on a text base) or :invalid.
  def parse(nil), do: %{base: nil, params: [], collation: nil}
  def parse(type) when is_atom(type), do: parse(Atom.to_string(type))

  def parse(type) when is_binary(type) do
    lowered = type |> String.trim() |> String.downcase()
    lowered = Regex.replace(~r/\s+(?:character\s+set|charset)\s+"?[^"\s]+"?/, lowered, "")

    collation =
      case Regex.run(~r/\s+collate\s+"?([^"\s]+)"?/, lowered) do
        [_, collation] -> collation
        nil -> nil
      end

    lowered = Regex.replace(~r/\s+collate\s+"?[^"\s]+"?/, lowered, "")

    base =
      lowered
      |> then(&Regex.replace(~r/\([^)]*\)/, &1, ""))
      |> then(&Regex.replace(~r/\s+/, &1, " "))
      |> String.trim()

    params =
      case Regex.run(~r/\(([^)]*)\)/, lowered) do
        nil ->
          []

        [_, inner] ->
          inner = String.trim(inner)
          parts = inner |> String.split(",") |> Enum.map(&String.trim/1)

          cond do
            Enum.all?(parts, &(&1 =~ ~r/\A-?[0-9]+\z/)) -> Enum.map(parts, &String.to_integer/1)
            inner in @unbounded and base in @text -> []
            true -> :invalid
          end
      end

    %{base: base, params: params, collation: collation}
  end

  def parse(_type), do: %{base: nil, params: :invalid, collation: nil}

  defp classify_declared(declared, backend, deterministic) do
    cond do
      declared.base in [nil, ""] ->
        :identity

      declared.params == :invalid ->
        :identity

      deterministic == false ->
        :identity

      declared.collation != nil and deterministic != true and
          not deterministic?(declared.collation, backend) ->
        :identity

      declared.base in @text ->
        :text

      Map.has_key?(@integer, declared.base) ->
        :numeric

      declared.base in @decimal ->
        :numeric

      true ->
        :identity
    end
  end

  # MySQL binary collation names are deterministic only on a MySQL-family
  # backend; elsewhere a `_bin` name may be a nondeterministic ICU collation.
  defp deterministic?(collation, backend) do
    collation in @deterministic_any or
      (backend == :mysql_family and
         case Regex.run(~r/\A([a-z0-9]+)_(?:nopad_|0900_)?bin\z/, collation) do
           [_, charset] -> charset in @mysql_charsets
           nil -> false
         end)
  end

  ## Stored-unchanged check

  defp admissible?(%{declared: %{base: base}}, _actual) when base in [nil, ""], do: false
  defp admissible?(%{declared: %{params: :invalid}}, _actual), do: false

  defp admissible?(%{declared: declared, class: class, trust: trust}, actual)
       when is_binary(actual) do
    length_bearing = declared.base in (@text ++ @char_family)
    params = declared.params
    integer? = Map.has_key?(@integer, declared.base)

    cond do
      not String.valid?(actual) ->
        false

      length_bearing and length(params) > 1 ->
        false

      length_bearing and params != [] and length(String.codepoints(actual)) > hd(params) ->
        false

      String.contains?(actual, <<0>>) and (length_bearing or class == :text) ->
        false

      trust == :unverified ->
        false

      trust != :verified and integer? ->
        numeric_admissible?(declared, decimal(actual))

      trust != :verified ->
        declared.base in (@text ++ @char_family ++ @base_verified_identity) and
          not String.ends_with?(actual, " ")

      class == :text ->
        true

      class == :numeric ->
        numeric_admissible?(declared, decimal(actual))

      params != [] and not length_bearing ->
        false

      declared.base in @temporal ->
        String.downcase(String.trim(actual)) not in @time_dependent

      true ->
        true
    end
  end

  defp admissible?(_column, _actual), do: false

  defp numeric_admissible?(_declared, nil), do: false

  defp numeric_admissible?(declared, {sign, magnitude, digits}) do
    digits = String.trim_trailing(digits, "0")

    {integer_digits, fraction_digits} =
      if digits == "",
        do: {0, 0},
        else: {max(magnitude, 0), max(String.length(digits) - magnitude, 0)}

    case Map.fetch(@integer, declared.base) do
      {:ok, {low, high}} ->
        fraction_digits == 0 and integer_digits <= 20 and
          (digits == "" or
             (sign *
                String.to_integer(
                  digits <> String.duplicate("0", magnitude - String.length(digits))
                ))
             |> then(&(&1 >= low and &1 <= high)))

      :error ->
        case declared.params do
          [] ->
            true

          [precision] when precision >= 1 ->
            integer_digits <= precision and fraction_digits == 0

          [precision, scale] when precision >= 1 and scale >= 0 and scale <= precision ->
            integer_digits <= precision - scale and fraction_digits <= scale

          _ ->
            false
        end
    end
  end

  ## Comparison

  defp compare_values(_column, _op, _actual, expected) when not is_binary(expected),
    do: :not_evaluable

  defp compare_values(%{class: :text}, op, actual, expected) do
    cond do
      not String.valid?(expected) -> :not_evaluable
      String.contains?(expected, <<0>>) -> :not_evaluable
      op in @ranges -> :not_evaluable
      true -> verdict(op, if(actual == expected, do: 0, else: 1))
    end
  end

  defp compare_values(%{class: :identity}, op, actual, actual) when op in [:eq, :ne],
    do: verdict(op, 0)

  defp compare_values(%{class: :identity}, _op, _actual, _expected), do: :not_evaluable

  defp compare_values(%{class: :numeric}, op, actual, expected) do
    case {decimal(actual), decimal(expected)} do
      {nil, _} -> :not_evaluable
      {_, nil} -> :not_evaluable
      {left, right} -> verdict(op, order(left, right))
    end
  end

  defp verdict(:eq, order), do: order == 0
  defp verdict(:ne, order), do: order != 0
  defp verdict(:gt, order), do: order > 0
  defp verdict(:gte, order), do: order >= 0
  defp verdict(:lt, order), do: order < 0
  defp verdict(:lte, order), do: order <= 0

  # Finite ASCII decimal: {sign, magnitude, significant digits}; the value is
  # sign * 0.digits * 10^magnitude. Exponents stay arbitrary integers, so
  # nothing is rounded.
  @decimal_grammar ~r/\A[ \t\r\n\f\x0b]*([+-]?)(?:([0-9]+)(?:\.([0-9]*))?|\.([0-9]+))(?:[eE]([+-]?[0-9]+))?[ \t\r\n\f\x0b]*\z/

  defp decimal(value) when is_binary(value) do
    case Regex.run(@decimal_grammar, value) do
      nil ->
        nil

      captures ->
        [_, sign, whole, fraction, leading, exponent] =
          captures ++ List.duplicate("", 6 - length(captures))

        {whole, fraction} = if leading != "", do: {"", leading}, else: {whole, fraction}
        digits = String.trim_leading(whole <> fraction, "0")
        exponent = if exponent == "", do: 0, else: String.to_integer(exponent)
        sign = if(digits == "", do: 0, else: if(sign == "-", do: -1, else: 1))
        {sign, exponent + String.length(digits) - String.length(fraction), digits}
    end
  end

  defp order({sign, _, _}, {other, _, _}) when sign != other,
    do: if(sign > other, do: 1, else: -1)

  defp order({0, _, _}, {0, _, _}), do: 0

  defp order({sign, magnitude, digits}, {_, other_magnitude, other_digits}) do
    result =
      cond do
        magnitude > other_magnitude ->
          1

        magnitude < other_magnitude ->
          -1

        true ->
          width = max(String.length(digits), String.length(other_digits))
          left = String.pad_trailing(digits, width, "0")
          right = String.pad_trailing(other_digits, width, "0")

          cond do
            left > right -> 1
            left < right -> -1
            true -> 0
          end
      end

    sign * result
  end

  ## Native operands

  @doc """
  The canonical text bound for a native value, nil for NULL, or `:error` when
  the runtime cannot reproduce the bound text (floats and temporals: the
  driver converts them) or the value is no scalar.
  """
  @spec bound_text(term()) :: {:ok, String.t() | nil} | :error
  def bound_text(nil), do: {:ok, nil}
  def bound_text(value) when is_binary(value), do: {:ok, value}
  def bound_text(true), do: {:ok, "true"}
  def bound_text(false), do: {:ok, "false"}
  def bound_text(value) when is_integer(value), do: {:ok, Integer.to_string(value)}

  def bound_text(%Decimal{} = value) do
    if Decimal.nan?(value) or Decimal.inf?(value),
      do: :error,
      else: {:ok, Decimal.to_string(value, :normal)}
  end

  def bound_text(_value), do: :error
end
