defmodule Selecto.FunctionSpec do
  @moduledoc """
  Normalization and call-signature resolution for registered database functions.

  Existing function specs with top-level `args` and `returns` are treated as a
  single signature. Specs may additionally declare `overloads`, where each
  overload supplies its own `args` and `returns` and inherits common metadata
  such as `kind`, `sql_name`, and `allowed_in`.

  Resolution is deliberately database-independent. It proves that a call is
  consistent with the Selecto declaration; connected database verification is
  a separate evidence layer.
  """

  alias Selecto.FieldResolver
  alias Selecto.TypeSystem

  @known_spec_keys [:kind, :sql_name, :allowed_in, :args, :returns, :overloads, :database]
  @known_arg_keys [:name, :type, :source, :required, :default, :null?]

  defmodule ResolutionError do
    @moduledoc false
    @enforce_keys [:message, :code, :function_id]
    defstruct [:message, :code, :function_id, details: %{}]
  end

  @type resolution_error :: %ResolutionError{}

  @doc "Returns normalized effective signatures for a registered function spec."
  @spec signatures(map()) :: [map()]
  def signatures(spec) when is_map(spec) do
    normalized = normalize_spec(spec)
    base = Map.drop(normalized, [:overloads])

    case Map.get(normalized, :overloads) do
      overloads when is_list(overloads) and overloads != [] ->
        Enum.map(overloads, fn overload ->
          base
          |> Map.merge(normalize_spec(overload))
          |> Map.update(:args, [], &Enum.map(List.wrap(&1), fn arg -> normalize_arg(arg) end))
        end)

      _ ->
        [Map.update(base, :args, [], &Enum.map(List.wrap(&1), fn arg -> normalize_arg(arg) end))]
    end
  end

  @doc """
  Resolves one effective registered signature for the supplied call.

  The result is the normalized signature that validation, type inference, and
  SQL generation must all use.
  """
  @spec resolve(Selecto.t(), atom() | String.t(), [term()], atom() | nil) ::
          {:ok, map()} | {:error, resolution_error()}
  def resolve(selecto, function_id, args, call_site \\ nil) when is_list(args) do
    with {:ok, spec} <- fetch_spec(selecto, function_id),
         :ok <- validate_common_use(spec, function_id, call_site),
         {:ok, arity_candidates} <- arity_candidates(spec, function_id, args),
         {:ok, signature} <- type_candidate(selecto, function_id, args, arity_candidates) do
      {:ok, signature}
    end
  end

  @doc "Like `resolve/4`, but raises `ArgumentError` for public API compatibility."
  @spec resolve!(Selecto.t(), atom() | String.t(), [term()], atom() | nil) :: map()
  def resolve!(selecto, function_id, args, call_site \\ nil) do
    case resolve(selecto, function_id, args, call_site) do
      {:ok, signature} -> signature
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp fetch_spec(selecto, function_id) do
    case Selecto.UDF.fetch(selecto, function_id) do
      {:ok, spec} ->
        {:ok, normalize_spec(spec)}

      :error ->
        {:error,
         error(
           :unknown_function,
           function_id,
           "Unknown UDF '#{Selecto.UDF.normalize_id(function_id)}'"
         )}
    end
  end

  defp validate_common_use(spec, function_id, call_site) do
    allowed_in = Map.get(spec, :allowed_in, [])
    kind = Map.get(spec, :kind)

    cond do
      is_nil(call_site) ->
        :ok

      not allowed_for_call_site?(call_site, allowed_in) ->
        {:error,
         error(
           :call_site_not_allowed,
           function_id,
           "UDF '#{Selecto.UDF.normalize_id(function_id)}' is not allowed in :#{call_site}. Allowed: #{inspect(allowed_in)}",
           %{call_site: call_site, allowed_in: allowed_in}
         )}

      call_site == :filter and kind != :predicate ->
        {:error,
         error(
           :kind_mismatch,
           function_id,
           "UDF '#{Selecto.UDF.normalize_id(function_id)}' must be kind :predicate to be used in filters",
           %{call_site: call_site, expected_kind: :predicate, actual_kind: kind}
         )}

      call_site in [:lateral, :query_member] and kind != :table ->
        {:error,
         error(
           :kind_mismatch,
           function_id,
           "UDF '#{Selecto.UDF.normalize_id(function_id)}' must be kind :table to be used in lateral joins",
           %{call_site: call_site, expected_kind: :table, actual_kind: kind}
         )}

      kind == :table and call_site not in [:lateral, :query_member] ->
        {:error,
         error(
           :kind_mismatch,
           function_id,
           "UDF '#{Selecto.UDF.normalize_id(function_id)}' is a table function and cannot be used as a selector",
           %{call_site: call_site, expected_kind: :scalar_or_predicate, actual_kind: kind}
         )}

      true ->
        :ok
    end
  end

  defp allowed_for_call_site?(:lateral, allowed_in),
    do: :lateral in allowed_in or :query_member in allowed_in

  defp allowed_for_call_site?(call_site, allowed_in), do: call_site in allowed_in

  defp arity_candidates(spec, function_id, args) do
    signatures = signatures(spec)
    matching = Enum.filter(signatures, &(length(Map.get(&1, :args, [])) == length(args)))

    case matching do
      [] ->
        expected =
          signatures |> Enum.map(&length(Map.get(&1, :args, []))) |> Enum.uniq() |> Enum.sort()

        expected_label =
          case expected do
            [count] -> "#{count} argument(s)"
            counts -> "one of #{inspect(counts)} argument counts"
          end

        {:error,
         error(
           :argument_count_mismatch,
           function_id,
           "UDF '#{Selecto.UDF.normalize_id(function_id)}' expects #{expected_label}, got #{length(args)}",
           %{expected_arities: expected, actual_arity: length(args)}
         )}

      candidates ->
        {:ok, candidates}
    end
  end

  defp type_candidate(selecto, function_id, args, candidates) do
    evaluated = Enum.map(candidates, &evaluate_candidate(selecto, args, &1))
    compatible = Enum.filter(evaluated, &match?({:ok, _, _}, &1))

    case compatible do
      [] ->
        mismatches = Enum.map(evaluated, fn {:error, details} -> details end)

        {:error,
         error(
           :argument_type_mismatch,
           function_id,
           type_mismatch_message(function_id, mismatches),
           %{candidates: mismatches}
         )}

      matches ->
        best_score = matches |> Enum.map(fn {:ok, score, _} -> score end) |> Enum.max()
        best = Enum.filter(matches, fn {:ok, score, _} -> score == best_score end)

        case best do
          [{:ok, _score, signature}] ->
            {:ok, signature}

          ambiguous ->
            signatures =
              Enum.map(ambiguous, fn {:ok, _score, signature} -> signature_summary(signature) end)

            {:error,
             error(
               :ambiguous_overload,
               function_id,
               "UDF '#{Selecto.UDF.normalize_id(function_id)}' has ambiguous overloads for the supplied argument types: #{Enum.join(signatures, "; ")}",
               %{signatures: signatures}
             )}
        end
    end
  end

  defp evaluate_candidate(selecto, args, signature) do
    results =
      args
      |> Enum.zip(Map.get(signature, :args, []))
      |> Enum.with_index()
      |> Enum.map(fn {{arg, arg_spec}, index} -> evaluate_arg(selecto, arg, arg_spec, index) end)

    mismatches = Enum.filter(results, &match?({:error, _}, &1))

    if mismatches == [] do
      score = Enum.reduce(results, 0, fn {:ok, arg_score}, acc -> acc + arg_score end)
      {:ok, score, signature}
    else
      {:error,
       %{
         signature: signature_summary(signature),
         arguments: Enum.map(mismatches, fn {:error, details} -> details end)
       }}
    end
  end

  defp evaluate_arg(selecto, arg, arg_spec, index) do
    expected = arg_spec |> Map.get(:type, :unknown) |> TypeSystem.normalize_type()
    actual = infer_arg_type(selecto, arg, Map.get(arg_spec, :source))
    null_allowed? = Map.get(arg_spec, :null?, true)

    cond do
      null_value?(arg) and not null_allowed? ->
        {:error,
         %{
           index: index,
           name: Map.get(arg_spec, :name),
           expected: expected,
           actual: :null,
           reason: :null_not_allowed
         }}

      actual == :unknown ->
        {:ok, 0}

      actual == expected ->
        {:ok, 2}

      TypeSystem.compatible?(actual, expected) ->
        {:ok, 1}

      true ->
        {:error,
         %{
           index: index,
           name: Map.get(arg_spec, :name),
           expected: expected,
           actual: actual,
           reason: :incompatible_type
         }}
    end
  end

  defp infer_arg_type(selecto, arg, :selector) when is_binary(arg) or is_atom(arg) do
    case FieldResolver.resolve_field(selecto, arg) do
      {:ok, %{type: type}} -> TypeSystem.normalize_type(type)
      _ -> :unknown
    end
  end

  defp infer_arg_type(selecto, arg, :selector), do: TypeSystem.infer_type!(selecto, arg)
  defp infer_arg_type(_selecto, {:param, value}, :value), do: literal_type(value)

  defp infer_arg_type(_selecto, {:literal, value}, source) when source in [:value, :literal],
    do: literal_type(value)

  defp infer_arg_type(_selecto, value, source) when source in [:value, :literal],
    do: literal_type(value)

  defp infer_arg_type(_selecto, _arg, _source), do: :unknown

  defp literal_type(nil), do: :unknown
  defp literal_type(value) when is_integer(value), do: :integer
  defp literal_type(value) when is_float(value), do: :decimal
  defp literal_type(value) when is_boolean(value), do: :boolean
  defp literal_type(value) when is_binary(value), do: :string
  defp literal_type(%Date{}), do: :date
  defp literal_type(%Time{}), do: :time
  defp literal_type(%DateTime{}), do: :utc_datetime
  defp literal_type(%NaiveDateTime{}), do: :naive_datetime
  defp literal_type(value) when is_list(value), do: {:array, :unknown}
  defp literal_type(value) when is_map(value), do: :jsonb
  defp literal_type(_value), do: :unknown

  defp null_value?(nil), do: true
  defp null_value?({:param, nil}), do: true
  defp null_value?({:literal, nil}), do: true
  defp null_value?(_value), do: false

  defp signature_summary(signature) do
    args =
      signature
      |> Map.get(:args, [])
      |> Enum.map(fn arg -> inspect(Map.get(arg, :type, :unknown)) end)
      |> Enum.join(", ")

    "(#{args}) -> #{inspect(Map.get(signature, :returns, :unknown))}"
  end

  defp type_mismatch_message(function_id, [first | _]) do
    details =
      first.arguments
      |> Enum.map(fn mismatch ->
        "argument #{mismatch.index + 1} expected #{inspect(mismatch.expected)}, got #{inspect(mismatch.actual)}"
      end)
      |> Enum.join(", ")

    "UDF '#{Selecto.UDF.normalize_id(function_id)}' argument type mismatch: #{details}"
  end

  defp type_mismatch_message(function_id, _mismatches) do
    "UDF '#{Selecto.UDF.normalize_id(function_id)}' has no compatible signature"
  end

  defp normalize_spec(spec) do
    Enum.reduce(@known_spec_keys, spec, fn key, acc -> normalize_key(acc, key) end)
  end

  defp normalize_arg(arg) when is_map(arg) do
    Enum.reduce(@known_arg_keys, arg, fn key, acc -> normalize_key(acc, key) end)
  end

  defp normalize_arg(arg), do: arg

  defp normalize_key(map, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) ->
        Map.delete(map, string_key)

      Map.has_key?(map, string_key) ->
        map |> Map.put(key, Map.fetch!(map, string_key)) |> Map.delete(string_key)

      true ->
        map
    end
  end

  defp error(code, function_id, message, details \\ %{}) do
    %ResolutionError{
      code: code,
      function_id: Selecto.UDF.normalize_id(function_id),
      message: message,
      details: details
    }
  end
end
