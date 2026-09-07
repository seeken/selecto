defmodule Selecto.Rule.Legacy do
  @moduledoc """
  Explicit translations from delivered Elixir validator forms to canonical
  rule tests. Unknown or ambiguous forms return `:unsupported`.
  """

  alias Selecto.Rule.Contract

  @spec field_test(term()) :: {:ok, map()} | :unsupported
  def field_test({:number, opts}) when is_list(opts) do
    opts
    |> Enum.map(&number_option/1)
    |> combine()
    |> valid_test()
  end

  def field_test({:length, opts}) when is_list(opts) do
    test = %{"op" => "text.length", "unit" => "unicode_scalar"}
    translated = Enum.reduce_while(opts, {:ok, test}, &length_option/2)
    valid_test(translated)
  end

  def field_test({:format, %Regex{source: source, opts: ""}}) do
    valid_test(
      {:ok,
       %{
         "op" => "text.pattern",
         "profile" => "ascii_v1",
         "pattern" => source,
         "match" => "full",
         "flags" => []
       }}
    )
  end

  def field_test({:inclusion, values}) when is_list(values) and values != [],
    do: valid_test({:ok, %{"op" => "membership.in", "values" => values}})

  def field_test({:exclusion, values}) when is_list(values) and values != [],
    do: valid_test({:ok, %{"op" => "membership.not_in", "values" => values}})

  def field_test(_validator), do: :unsupported

  @spec input_tests(map()) :: {:ok, [map()]} | {:error, term()}
  def input_tests(spec) when is_map(spec) do
    validators =
      get(spec, :rules, get(spec, :validators, get(spec, :validations, []))) |> List.wrap()

    inline =
      []
      |> maybe_required(get(spec, :required))
      |> maybe_nonblank(get(spec, :nonblank))
      |> maybe_length(spec)
      |> maybe_pattern(spec)
      |> maybe_number(spec)

    Enum.reduce_while(validators, {:ok, inline}, fn validator, {:ok, tests} ->
      case validator do
        %{} = test ->
          {:cont, {:ok, tests ++ [test]}}

        _ ->
          case field_test(validator) do
            {:ok, test} -> {:cont, {:ok, tests ++ [test]}}
            :unsupported -> {:halt, {:error, {:unsupported, validator}}}
          end
      end
    end)
  end

  defp number_option({:greater_than, bound}), do: number_test("number.gt", bound)
  defp number_option({:greater_than_or_equal_to, bound}), do: number_test("number.gte", bound)
  defp number_option({:less_than, bound}), do: number_test("number.lt", bound)
  defp number_option({:less_than_or_equal_to, bound}), do: number_test("number.lte", bound)
  defp number_option(_option), do: :unsupported

  defp number_test(op, bound) when is_integer(bound) or is_binary(bound),
    do: {:ok, %{"op" => op, "bound" => bound}}

  defp number_test(_op, _bound), do: :unsupported

  defp length_option({:is, exact}, {:ok, test}) when is_integer(exact),
    do: {:cont, {:ok, Map.put(test, "exact", exact)}}

  defp length_option({:min, minimum}, {:ok, test}) when is_integer(minimum),
    do: {:cont, {:ok, Map.put(test, "min", minimum)}}

  defp length_option({:max, maximum}, {:ok, test}) when is_integer(maximum),
    do: {:cont, {:ok, Map.put(test, "max", maximum)}}

  defp length_option(_option, _acc), do: {:halt, :unsupported}

  defp combine(tests) do
    case Enum.reduce_while(tests, {:ok, []}, fn
           {:ok, test}, {:ok, acc} -> {:cont, {:ok, acc ++ [test]}}
           :unsupported, _acc -> {:halt, :unsupported}
         end) do
      {:ok, [test]} -> {:ok, test}
      {:ok, tests} when tests != [] -> {:ok, %{"op" => "all", "rules" => tests}}
      _ -> :unsupported
    end
  end

  defp valid_test({:ok, test}) do
    case Contract.compile_test(test) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, _error} -> :unsupported
    end
  end

  defp valid_test(_result), do: :unsupported

  defp maybe_required(tests, value) when value in [true, "true"],
    do: tests ++ [%{"op" => "presence.required"}]

  defp maybe_required(tests, _value), do: tests

  defp maybe_nonblank(tests, value) when value in [true, "true"],
    do: tests ++ [%{"op" => "text.nonblank"}]

  defp maybe_nonblank(tests, _value), do: tests

  defp maybe_length(tests, spec) do
    bounds =
      %{
        "op" => "text.length",
        "unit" => "unicode_scalar",
        "min" => get(spec, :min_length),
        "max" => get(spec, :max_length),
        "exact" => get(spec, :exact_length)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    if map_size(bounds) > 2, do: tests ++ [bounds], else: tests
  end

  defp maybe_pattern(tests, spec) do
    case get(spec, :pattern) do
      pattern when is_binary(pattern) ->
        tests ++
          [
            %{
              "op" => "text.pattern",
              "profile" => "ascii_v1",
              "pattern" => pattern,
              "match" => get(spec, :pattern_match, "full"),
              "flags" => []
            }
          ]

      _ ->
        tests
    end
  end

  defp maybe_number(tests, spec) do
    tests
    |> add_number("number.gt", get(spec, :greater_than))
    |> add_number("number.gte", get(spec, :greater_than_or_equal_to))
    |> add_number("number.lt", get(spec, :less_than))
    |> add_number("number.lte", get(spec, :less_than_or_equal_to))
  end

  defp add_number(tests, _op, nil), do: tests
  defp add_number(tests, op, bound), do: tests ++ [%{"op" => op, "bound" => bound}]
  defp get(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, to_string(key), default))
end
