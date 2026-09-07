defmodule Selecto.Rule.Evaluator do
  @moduledoc """
  Pure evaluator for compiled Selecto data rules.

  Evaluation never performs IO. Transaction and evidence bindings are returned
  as obligations until a host supplies the corresponding authoritative stage.
  """

  alias Selecto.Rule.{Contract, Result}

  @missing :__selecto_rule_missing__
  @max_text_bytes 4096

  @spec evaluate(Contract.t(), atom() | String.t(), term(), keyword()) :: Result.t()
  def evaluate(%Contract{} = contract, scope, values, opts \\ []) do
    scope = to_string(scope)

    {values, outcomes, obligations} =
      contract.bindings
      |> Enum.sort_by(fn {id, _binding} -> id end)
      |> Enum.reduce({values, [], []}, fn {_id, binding}, {current, outcomes, obligations} ->
        if applies?(binding, scope, opts) do
          evaluate_binding(contract, binding, current, outcomes, obligations, opts)
        else
          {current, outcomes, obligations}
        end
      end)

    %Result{
      values: values,
      outcomes: outcomes,
      obligations: obligations,
      disposition: overall_disposition(outcomes, obligations)
    }
  end

  @doc "Evaluates one compiled test against one value."
  @spec evaluate_test(map(), term(), keyword()) :: :passed | {:failed, map()} | {:error, map()}
  def evaluate_test(test, value, opts \\ []) when is_map(test) do
    safe_evaluate(test, value, opts)
  end

  @doc "Applies a compiled normalizer pipeline to one value."
  @spec normalize([map()], term()) :: {:ok, term()} | {:error, map()}
  def normalize(steps, value) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, value}, fn step, {:ok, current} ->
      case safe_normalize_step(step, current) do
        {:ok, normalized} -> {:cont, {:ok, normalized}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp applies?(binding, scope, opts) do
    operation = opts |> Keyword.get(:operation) |> maybe_string()
    action = opts |> Keyword.get(:action) |> maybe_string()

    binding.stage == scope and
      (binding.operations == [] or operation in binding.operations) and
      (is_nil(binding.subject[:action]) or binding.subject.action == action)
  end

  defp evaluate_binding(contract, binding, values, outcomes, obligations, opts) do
    cond do
      binding.stage in ["transaction", "evidence"] and
          Keyword.get(opts, :authoritative_stage) != binding.stage ->
        obligation = %{
          binding_id: binding.id,
          stage: binding.stage,
          rule: binding.rule,
          enforcement: binding.enforcement
        }

        {values, outcomes, obligations ++ [obligation]}

      true ->
        value = fetch_path(values, binding.subject.path)
        definition = Map.fetch!(contract.definitions, binding.rule.id)
        normalizer = binding.normalizer && Map.fetch!(contract.normalizers, binding.normalizer.id)

        with :passed <- evaluate_condition(binding.condition, values, opts),
             {:ok, normalized} <- apply_normalizer(normalizer, value),
             result <- safe_evaluate(definition.test, normalized, opts) do
          updated =
            if normalizer && value != @missing,
              do: put_path(values, binding.subject.path, normalized),
              else: values

          outcome = outcome(binding, definition, result)
          {updated, outcomes ++ [outcome], obligations}
        else
          :not_applicable ->
            outcome = outcome(binding, definition, :not_applicable)
            {values, outcomes ++ [outcome], obligations}

          {:error, error} ->
            outcome = outcome(binding, definition, {:error, error})
            {values, outcomes ++ [outcome], obligations}
        end
    end
  end

  defp evaluate_condition(nil, _values, _opts), do: :passed

  defp evaluate_condition(condition, values, opts) do
    case safe_evaluate(condition, values, opts) do
      :passed -> :passed
      {:failed, _} -> :not_applicable
      {:error, error} -> {:error, error}
    end
  end

  defp apply_normalizer(nil, value), do: {:ok, value}
  defp apply_normalizer(_normalizer, @missing), do: {:ok, @missing}
  defp apply_normalizer(normalizer, value), do: normalize(normalizer.steps, value)

  defp outcome(binding, definition, result) do
    {disposition, diagnostic} =
      case result do
        :passed -> {:passed, %{}}
        :not_applicable -> {:not_applicable, %{}}
        {:failed, details} -> {:failed, details}
        {:error, details} -> {:error, details}
      end

    %{
      binding_id: binding.id,
      rule_id: definition.id,
      rule_version: definition.version,
      path: binding.subject.path,
      enforcement: binding.enforcement,
      disposition: disposition,
      code: Map.get(diagnostic, :code),
      message: definition.message[:default] || Map.get(diagnostic, :message),
      details: Map.drop(diagnostic, [:code, :message])
    }
  end

  defp overall_disposition(outcomes, obligations) do
    required = Enum.filter(outcomes, &(&1.enforcement == "required"))
    required_obligations = Enum.filter(obligations, &(&1.enforcement == "required"))

    cond do
      Enum.any?(required, &(&1.disposition == :error)) -> :error
      Enum.any?(required, &(&1.disposition == :failed)) -> :failed
      required_obligations != [] -> :pending
      true -> :passed
    end
  end

  defp do_evaluate(%{"op" => "presence.required"}, value, _opts) do
    if value == @missing, do: failed(:required, "value is required"), else: :passed
  end

  defp do_evaluate(%{"op" => "presence.non_null"}, value, _opts) do
    if value in [@missing, nil], do: failed(:null, "value must not be null"), else: :passed
  end

  defp do_evaluate(%{"op" => "presence.absent"}, value, _opts) do
    if value == @missing, do: :passed, else: failed(:forbidden, "value must be absent")
  end

  defp do_evaluate(%{"op" => "type.is", "type" => type}, value, _opts) do
    valid =
      case type do
        type when type in ["text", "string"] -> is_binary(value)
        "integer" -> is_integer(value)
        "decimal" -> match?({:ok, _decimal}, decimal(value))
        "boolean" -> is_boolean(value)
        "collection" -> is_list(value)
        "object" -> is_map(value)
      end

    if valid, do: :passed, else: failed(:invalid_type, "value has the wrong portable type")
  end

  defp do_evaluate(%{"op" => "text.nonblank"}, value, _opts) when is_binary(value) do
    if String.trim(value) == "", do: failed(:blank, "text must not be blank"), else: :passed
  end

  defp do_evaluate(%{"op" => "text.nonblank"}, _value, _opts),
    do: failed(:invalid_type, "value must be text")

  defp do_evaluate(%{"op" => "text.length"} = test, value, _opts) when is_binary(value) do
    check_bounds(
      String.length(value),
      test,
      :invalid_text_length,
      "text length is outside its declared bounds"
    )
  end

  defp do_evaluate(%{"op" => "text.length"}, _value, _opts),
    do: failed(:invalid_type, "value must be text")

  defp do_evaluate(%{"op" => "text.pattern"} = test, value, _opts)
       when is_binary(value) and byte_size(value) <= @max_text_bytes do
    pattern =
      if test["match"] == "full", do: "\\A(?:#{test["pattern"]})\\z", else: test["pattern"]

    case Regex.compile(pattern) do
      {:ok, regex} ->
        if Regex.match?(regex, value),
          do: :passed,
          else: failed(:pattern_mismatch, "text does not match its declared pattern")

      {:error, reason} ->
        errored(:invalid_pattern, "compiled text pattern is invalid", reason: inspect(reason))
    end
  end

  defp do_evaluate(%{"op" => "text.pattern"}, value, _opts) when is_binary(value),
    do: errored(:text_budget_exceeded, "text exceeds the portable pattern input budget")

  defp do_evaluate(%{"op" => "text.pattern"}, _value, _opts),
    do: failed(:invalid_type, "value must be text")

  for {op, function} <- [
        {"text.prefix", :starts_with?},
        {"text.suffix", :ends_with?},
        {"text.contains", :contains?}
      ] do
    defp do_evaluate(%{"op" => unquote(op), "text" => expected}, value, _opts)
         when is_binary(value) do
      if apply(String, unquote(function), [value, expected]),
        do: :passed,
        else: failed(:text_mismatch, "text does not satisfy its declared content rule")
    end

    defp do_evaluate(%{"op" => unquote(op)}, _value, _opts),
      do: failed(:invalid_type, "value must be text")
  end

  for {op, comparison} <- [
        {"number.gt", :gt},
        {"number.gte", :gte},
        {"number.lt", :lt},
        {"number.lte", :lte}
      ] do
    defp do_evaluate(%{"op" => unquote(op), "bound" => bound}, value, _opts) do
      with {:ok, number} <- decimal(value) do
        valid = compare(number, bound.decimal, unquote(comparison))

        if valid,
          do: :passed,
          else:
            failed(:numeric_bound, "number violates its declared bound",
              actual: display_number(number),
              bound: bound.value
            )
      else
        :error -> failed(:invalid_type, "value must be an exact number")
      end
    end
  end

  defp do_evaluate(%{"op" => "number.range"} = test, value, _opts) do
    with {:ok, number} <- decimal(value) do
      minimum =
        if test["include_min"],
          do: Decimal.compare(number, test["min"].decimal) in [:eq, :gt],
          else: Decimal.compare(number, test["min"].decimal) == :gt

      maximum =
        if test["include_max"],
          do: Decimal.compare(number, test["max"].decimal) in [:eq, :lt],
          else: Decimal.compare(number, test["max"].decimal) == :lt

      if minimum and maximum,
        do: :passed,
        else: failed(:numeric_range, "number is outside its declared range")
    else
      :error -> failed(:invalid_type, "value must be an exact number")
    end
  end

  defp do_evaluate(%{"op" => "number.integer"}, value, _opts) do
    with {:ok, number} <- decimal(value) do
      if Decimal.equal?(number, Decimal.round(number, 0)),
        do: :passed,
        else: failed(:not_integer, "number must be an integer")
    else
      :error -> failed(:invalid_type, "value must be an exact number")
    end
  end

  defp do_evaluate(%{"op" => "number.multiple_of", "factor" => factor}, value, _opts) do
    with {:ok, number} <- decimal(value) do
      if Decimal.equal?(Decimal.rem(number, factor.decimal), Decimal.new(0)),
        do: :passed,
        else: failed(:not_multiple, "number is not a declared multiple")
    else
      :error -> failed(:invalid_type, "value must be an exact number")
    end
  end

  defp do_evaluate(%{"op" => "membership.in", "values" => allowed}, value, _opts) do
    if Enum.member?(allowed, value),
      do: :passed,
      else: failed(:not_included, "value is not in the declared set")
  end

  defp do_evaluate(%{"op" => "membership.not_in", "values" => denied}, value, _opts) do
    if Enum.member?(denied, value),
      do: failed(:excluded, "value is in the excluded set"),
      else: :passed
  end

  defp do_evaluate(%{"op" => "collection.count"} = test, value, _opts) when is_list(value),
    do:
      check_bounds(
        length(value),
        test,
        :invalid_collection_count,
        "collection count is outside its declared bounds"
      )

  defp do_evaluate(%{"op" => "collection.count"}, _value, _opts),
    do: failed(:invalid_type, "value must be a collection")

  defp do_evaluate(%{"op" => "collection.unique_by", "paths" => paths}, value, _opts)
       when is_list(value) do
    keys = Enum.map(value, fn item -> Enum.map(paths, &fetch_path(item, &1)) end)

    if Enum.any?(keys, fn key -> Enum.any?(key, &(&1 == @missing)) end),
      do: failed(:missing_unique_field, "collection uniqueness fields are missing"),
      else:
        if(length(keys) == length(Enum.uniq(keys)),
          do: :passed,
          else: failed(:duplicate_collection_value, "collection contains duplicate values")
        )
  end

  defp do_evaluate(%{"op" => "collection.unique_by"}, _value, _opts),
    do: failed(:invalid_type, "value must be a collection")

  defp do_evaluate(%{"op" => "value.eq", "value" => expected}, value, _opts),
    do:
      if(value == expected,
        do: :passed,
        else: failed(:not_equal, "value does not equal its declared value")
      )

  defp do_evaluate(%{"op" => "value.neq", "value" => expected}, value, _opts),
    do:
      if(value != expected,
        do: :passed,
        else: failed(:equal_to_excluded, "value equals its excluded value")
      )

  defp do_evaluate(%{"op" => "all", "rules" => rules}, value, opts) do
    results = Enum.map(rules, &do_evaluate(&1, value, opts))

    cond do
      Enum.any?(results, &match?({:failed, _}, &1)) ->
        Enum.find(results, &match?({:failed, _}, &1))

      Enum.any?(results, &match?({:error, _}, &1)) ->
        Enum.find(results, &match?({:error, _}, &1))

      true ->
        :passed
    end
  end

  defp do_evaluate(%{"op" => "any", "rules" => rules}, value, opts) do
    results = Enum.map(rules, &do_evaluate(&1, value, opts))

    cond do
      Enum.any?(results, &(&1 == :passed)) -> :passed
      Enum.any?(results, &match?({:error, _}, &1)) -> Enum.find(results, &match?({:error, _}, &1))
      true -> hd(results)
    end
  end

  defp do_evaluate(%{"op" => "not", "rule" => rule}, value, opts) do
    case do_evaluate(rule, value, opts) do
      :passed -> failed(:negated_rule_matched, "negated rule matched")
      {:failed, _details} -> :passed
      {:error, _details} = error -> error
    end
  end

  defp do_evaluate(_test, _value, _opts),
    do: errored(:unsupported_rule, "compiled rule is unsupported")

  defp safe_evaluate(test, value, opts) do
    do_evaluate(test, value, opts)
  rescue
    error ->
      errored(:rule_evaluation_error, "rule evaluation failed safely",
        exception: Exception.message(error)
      )
  end

  defp safe_normalize_step(step, value) do
    normalize_step(step, value)
  rescue
    error ->
      {:error,
       %{
         code: :normalizer_error,
         message: "normalizer failed safely",
         exception: Exception.message(error)
       }}
  end

  defp normalize_step(%{"op" => "text.trim"}, value) when is_binary(value),
    do: {:ok, Regex.replace(~r/\A[ \t\r\n]+|[ \t\r\n]+\z/, value, "")}

  defp normalize_step(%{"op" => "text.uppercase"}, value) when is_binary(value),
    do: ascii_case(value, :upcase)

  defp normalize_step(%{"op" => "text.lowercase"}, value) when is_binary(value),
    do: ascii_case(value, :downcase)

  defp normalize_step(%{"op" => "text.nfc"}, value) when is_binary(value),
    do: {:ok, :unicode.characters_to_nfc_binary(value)}

  defp normalize_step(%{"op" => "text.line_endings"}, value) when is_binary(value),
    do: {:ok, value |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")}

  defp normalize_step(%{"op" => "text.empty_to_null"}, ""), do: {:ok, nil}

  defp normalize_step(%{"op" => "text.empty_to_null"}, value) when is_binary(value),
    do: {:ok, value}

  defp normalize_step(_step, _value),
    do: {:error, %{code: :normalizer_type, message: "text normalizer requires text"}}

  defp ascii_case(value, direction) do
    if value |> :binary.bin_to_list() |> Enum.all?(&(&1 < 128)) do
      {:ok, apply(String, direction, [value, :ascii])}
    else
      {:error, %{code: :normalizer_profile, message: "ascii_v1 normalizer requires ASCII text"}}
    end
  end

  defp check_bounds(actual, test, code, message) do
    valid =
      cond do
        is_integer(test["exact"]) ->
          actual == test["exact"]

        true ->
          (is_nil(test["min"]) or actual >= test["min"]) and
            (is_nil(test["max"]) or actual <= test["max"])
      end

    if valid,
      do: :passed,
      else:
        failed(code, message,
          actual: actual,
          min: test["min"],
          max: test["max"],
          exact: test["exact"]
        )
  end

  defp compare(left, right, :gt), do: Decimal.compare(left, right) == :gt
  defp compare(left, right, :gte), do: Decimal.compare(left, right) in [:gt, :eq]
  defp compare(left, right, :lt), do: Decimal.compare(left, right) == :lt
  defp compare(left, right, :lte), do: Decimal.compare(left, right) in [:lt, :eq]

  defp decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal(%Decimal{} = value), do: {:ok, value}

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp decimal(_value), do: :error

  defp fetch_path(value, []), do: value

  defp fetch_path(map, [segment | rest]) when is_map(map) do
    case Enum.find(map, fn {key, _value} -> to_string(key) == segment end) do
      nil -> @missing
      {_key, value} -> fetch_path(value, rest)
    end
  end

  defp fetch_path(_value, _path), do: @missing

  defp put_path(map, [segment], value) when is_map(map) do
    case Enum.find(Map.keys(map), &(to_string(&1) == segment)) do
      nil -> Map.put(map, segment, value)
      key -> Map.put(map, key, value)
    end
  end

  defp put_path(map, [segment | rest], value) when is_map(map) do
    key = Enum.find(Map.keys(map), segment, &(to_string(&1) == segment))
    child = Map.get(map, key, %{})
    Map.put(map, key, put_path(child, rest, value))
  end

  defp put_path(value, _path, _replacement), do: value

  defp failed(code, message, attrs \\ []),
    do: {:failed, attrs |> Map.new() |> Map.merge(%{code: code, message: message})}

  defp errored(code, message, attrs \\ []),
    do: {:error, attrs |> Map.new() |> Map.merge(%{code: code, message: message})}

  defp display_number(number), do: Decimal.to_string(number, :normal)
  defp maybe_string(nil), do: nil
  defp maybe_string(value), do: to_string(value)
end
