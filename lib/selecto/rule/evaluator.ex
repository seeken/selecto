defmodule Selecto.Rule.Evaluator do
  @moduledoc """
  Pure evaluator for compiled Selecto data rules.

  Evaluation never performs IO. Transaction and evidence bindings are returned
  as obligations until a host supplies the corresponding authoritative stage.
  """

  alias Selecto.Rule.{Budget, Contract, Pattern, Result}

  @missing :__selecto_rule_missing__

  @spec evaluate(Contract.t(), atom() | String.t(), term(), keyword()) :: Result.t()
  def evaluate(contract, scope, values, opts \\ [])

  def evaluate(%Contract{bindings: bindings}, _scope, values, _opts)
      when map_size(bindings) > 1000 do
    %Result{
      values: values,
      disposition: :error,
      outcomes: [
        %{disposition: :error, code: :evaluation_limit, enforcement: "required", path: []}
      ]
    }
  end

  def evaluate(%Contract{} = contract, scope, values, opts) do
    scope = to_string(scope)

    opts =
      opts
      |> Keyword.put(:rule_budget, Budget.new())
      |> Keyword.put(:rule_original_values, values)

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
    opts = Keyword.put(opts, :rule_budget, Budget.new())

    with :ok <- guarded_values(value, opts),
         :ok <- guarded_values(Keyword.get(opts, :values, %{}), opts),
         :ok <- guarded_values(Keyword.get(opts, :condition_values, %{}), opts) do
      safe_evaluate(test, value, opts)
    end
  end

  @doc "Applies a compiled normalizer pipeline to one value."
  @spec normalize([map()], term()) :: {:ok, term()} | {:error, map()}
  def normalize(steps, value) when is_list(steps) do
    opts = [rule_budget: Budget.new()]
    with :ok <- guarded_values(value, opts), do: normalize_steps(steps, value, opts)
  end

  defp normalize_steps(steps, value, opts) do
    Budget.artifact(steps, Keyword.fetch!(opts, :rule_budget))

    Enum.reduce_while(steps, {:ok, value}, fn step, {:ok, current} ->
      case safe_normalize_step(step, current, opts) do
        {:ok, normalized} -> {:cont, {:ok, normalized}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  rescue
    Budget.Limit -> evaluation_limit()
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
        definition = Map.fetch!(contract.definitions, binding.rule.id)
        normalizer = binding.normalizer && Map.fetch!(contract.normalizers, binding.normalizer.id)

        with :ok <- guarded_values(values, opts),
             value = fetch_path(values, binding.subject.path, opts),
             :ok <- guarded_original_patterns(definition.test, binding, opts),
             {:ok, normalized} <- apply_normalizer(normalizer, value, opts) do
          updated =
            if normalizer && value != @missing,
              do: put_path(values, binding.subject.path, normalized, opts),
              else: values

          evaluation_opts = Keyword.put(opts, :values, updated)

          result =
            case evaluate_condition(
                   binding.condition,
                   normalized,
                   Keyword.put(evaluation_opts, :condition_values, updated)
                 ) do
              :passed -> safe_evaluate(definition.test, normalized, evaluation_opts)
              :not_applicable -> :not_applicable
              {:error, error} -> {:error, error}
            end

          outcome = outcome(binding, definition, result)
          {updated, outcomes ++ [outcome], obligations}
        else
          {:error, error} ->
            outcome = outcome(binding, definition, {:error, error})
            {values, outcomes ++ [outcome], obligations}
        end
    end
  rescue
    Budget.Limit ->
      definition = Map.fetch!(contract.definitions, binding.rule.id)
      {values, outcomes ++ [outcome(binding, definition, evaluation_limit())], obligations}
  end

  defp evaluate_condition(nil, _values, _opts), do: :passed

  defp evaluate_condition(condition, values, opts) do
    case safe_evaluate(condition, values, opts) do
      :passed -> :passed
      {:failed, _} -> :not_applicable
      {:error, error} -> {:error, error}
    end
  end

  defp apply_normalizer(nil, value, _opts), do: {:ok, value}
  defp apply_normalizer(_normalizer, @missing, _opts), do: {:ok, @missing}

  defp apply_normalizer(normalizer, value, opts),
    do: normalize_steps(normalizer.steps, value, opts)

  defp guarded_original_patterns(test, binding, opts) do
    record = Keyword.fetch!(opts, :rule_original_values)
    original = fetch_path(record, binding.subject.path, opts)
    Budget.artifact(test, Keyword.fetch!(opts, :rule_budget))
    Budget.artifact(binding.condition, Keyword.fetch!(opts, :rule_budget))
    original_patterns(test, original, record, opts)
    original_patterns(binding.condition, original, record, opts)
    :ok
  end

  defp original_patterns(%{"op" => "text.pattern"}, value, _record, opts) when is_binary(value),
    do: Budget.pattern_text(value, Keyword.fetch!(opts, :rule_budget))

  defp original_patterns(%{"op" => op, "rules" => rules}, value, record, opts)
       when op in ["all", "any"],
       do: Enum.each(rules, &original_patterns(&1, value, record, opts))

  defp original_patterns(%{"op" => "not", "rule" => rule}, value, record, opts),
    do: original_patterns(rule, value, record, opts)

  defp original_patterns(
         %{"op" => "path.test", "path" => path, "test" => test},
         _value,
         record,
         opts
       ),
       do: original_patterns(test, fetch_path(record, path, opts), record, opts)

  defp original_patterns(
         %{"op" => "object.shape", "properties" => properties},
         value,
         record,
         opts
       ),
       do:
         Enum.each(properties, fn {key, test} ->
           original_patterns(test, fetch_path(value, [key], opts), record, opts)
         end)

  defp original_patterns(_test, _value, _record, _opts), do: :ok

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
      Enum.any?(outcomes, &(&1.disposition == :error and &1.code == :evaluation_limit)) -> :error
      Enum.any?(required, &(&1.disposition == :error)) -> :error
      Enum.any?(required, &(&1.disposition == :failed)) -> :failed
      required_obligations != [] -> :pending
      true -> :passed
    end
  end

  defp evaluate_node(%{"op" => "presence.required"}, value, _opts) do
    if value == @missing, do: failed(:required, "value is required"), else: :passed
  end

  defp evaluate_node(%{"op" => "presence.non_null"}, value, _opts) do
    if value in [@missing, nil], do: failed(:null, "value must not be null"), else: :passed
  end

  defp evaluate_node(%{"op" => "presence.absent"}, value, _opts) do
    if value == @missing, do: :passed, else: failed(:forbidden, "value must be absent")
  end

  defp evaluate_node(%{"op" => "type.is", "type" => type}, value, _opts) do
    valid =
      case type do
        type when type in ["text", "string"] -> is_binary(value)
        "integer" -> is_integer(value)
        "decimal" -> is_number(value) or match?(%Decimal{}, value)
        "boolean" -> is_boolean(value)
        "collection" -> is_list(value)
        "object" -> is_map(value) and not is_struct(value)
      end

    if valid, do: :passed, else: failed(:invalid_type, "value has the wrong portable type")
  end

  defp evaluate_node(%{"op" => "text.nonblank"}, value, _opts) when is_binary(value) do
    if String.trim(value) == "", do: failed(:blank, "text must not be blank"), else: :passed
  end

  defp evaluate_node(%{"op" => "text.nonblank"}, _value, _opts),
    do: failed(:invalid_type, "value must be text")

  defp evaluate_node(%{"op" => "text.length"} = test, value, _opts) when is_binary(value) do
    check_bounds(
      value |> String.to_charlist() |> length(),
      test,
      :invalid_text_length,
      "text length is outside its declared bounds"
    )
  end

  defp evaluate_node(%{"op" => "text.length"}, _value, _opts),
    do: failed(:invalid_type, "value must be text")

  defp evaluate_node(%{"op" => "text.pattern"} = test, value, opts) when is_binary(value) do
    case Pattern.compile(test["pattern"]) do
      {:ok, automaton} ->
        if Pattern.matches?(automaton, value, test["match"], Keyword.fetch!(opts, :rule_budget)),
          do: :passed,
          else: failed(:pattern_mismatch, "text does not match its declared pattern")

      {:error, :evaluation_limit} ->
        evaluation_limit()

      {:error, _reason} ->
        errored(:invalid_pattern, "compiled text pattern is invalid")
    end
  end

  defp evaluate_node(%{"op" => "text.pattern"}, _value, _opts),
    do: failed(:invalid_type, "value must be text")

  for {op, function} <- [
        {"text.prefix", :starts_with?},
        {"text.suffix", :ends_with?},
        {"text.contains", :contains?}
      ] do
    defp evaluate_node(%{"op" => unquote(op), "text" => expected}, value, _opts)
         when is_binary(value) do
      if apply(String, unquote(function), [value, expected]),
        do: :passed,
        else: failed(:text_mismatch, "text does not satisfy its declared content rule")
    end

    defp evaluate_node(%{"op" => unquote(op)}, _value, _opts),
      do: failed(:invalid_type, "value must be text")
  end

  for {op, comparison} <- [
        {"number.gt", :gt},
        {"number.gte", :gte},
        {"number.lt", :lt},
        {"number.lte", :lte}
      ] do
    defp evaluate_node(%{"op" => unquote(op), "bound" => bound}, value, opts) do
      with {:ok, number} <- decimal(value, opts) do
        valid = compare(number, bound.decimal, unquote(comparison), opts)

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

  defp evaluate_node(%{"op" => "number.range"} = test, value, opts) do
    with {:ok, number} <- decimal(value, opts) do
      minimum =
        if test["include_min"],
          do: compare(number, test["min"].decimal, :gte, opts),
          else: compare(number, test["min"].decimal, :gt, opts)

      maximum =
        if test["include_max"],
          do: compare(number, test["max"].decimal, :lte, opts),
          else: compare(number, test["max"].decimal, :lt, opts)

      if minimum and maximum,
        do: :passed,
        else: failed(:numeric_range, "number is outside its declared range")
    else
      :error -> failed(:invalid_type, "value must be an exact number")
    end
  end

  defp evaluate_node(%{"op" => "number.integer"}, value, opts) do
    with {:ok, number} <- decimal(value, opts) do
      Budget.spend(
        Keyword.fetch!(opts, :rule_budget),
        Budget.number(number, Keyword.fetch!(opts, :rule_budget))
      )

      if Decimal.equal?(number, Decimal.round(number, 0)),
        do: :passed,
        else: failed(:not_integer, "number must be an integer")
    else
      :error -> failed(:invalid_type, "value must be an exact number")
    end
  end

  defp evaluate_node(%{"op" => "number.multiple_of", "factor" => factor}, value, opts) do
    with {:ok, number} <- decimal(value, opts) do
      Budget.arithmetic(number, factor.decimal, Keyword.fetch!(opts, :rule_budget), :remainder)

      remainder =
        Decimal.Context.with(%Decimal.Context{precision: 8194}, fn ->
          Decimal.rem(number, factor.decimal)
        end)

      if Decimal.equal?(remainder, Decimal.new(0)),
        do: :passed,
        else: failed(:not_multiple, "number is not a declared multiple")
    else
      :error -> failed(:invalid_type, "value must be an exact number")
    end
  end

  defp evaluate_node(%{"op" => "membership.in", "values" => allowed}, value, opts) do
    Budget.value(allowed, Keyword.fetch!(opts, :rule_budget))

    if Enum.any?(allowed, &equal?(value, &1, opts)),
      do: :passed,
      else: failed(:not_included, "value is not in the declared set")
  end

  defp evaluate_node(%{"op" => "membership.not_in", "values" => denied}, value, opts) do
    Budget.value(denied, Keyword.fetch!(opts, :rule_budget))

    if Enum.any?(denied, &equal?(value, &1, opts)),
      do: failed(:excluded, "value is in the excluded set"),
      else: :passed
  end

  defp evaluate_node(%{"op" => "collection.count"} = test, value, _opts) when is_list(value),
    do:
      check_bounds(
        length(value),
        test,
        :invalid_collection_count,
        "collection count is outside its declared bounds"
      )

  defp evaluate_node(%{"op" => "collection.count"}, _value, _opts),
    do: failed(:invalid_type, "value must be a collection")

  defp evaluate_node(%{"op" => "collection.sum", "path" => path} = test, value, opts)
       when is_list(value) do
    case collection_sum(value, path, opts) do
      {:ok, total} ->
        case check_numeric_bounds(total, test, opts) do
          :ok ->
            :passed

          {:error, direction} ->
            failed(:invalid_collection_sum, "collection sum is outside its declared bounds",
              actual: display_number(total),
              direction: direction,
              min: test["min"] && test["min"].value,
              max: test["max"] && test["max"].value,
              exact: test["exact"] && test["exact"].value
            )
        end

      {:error, :missing} ->
        failed(:missing_sum_field, "collection sum field is missing")

      {:error, :invalid} ->
        failed(:invalid_sum_value, "collection sum values must be exact numbers")
    end
  end

  defp evaluate_node(%{"op" => "collection.sum"}, _value, _opts),
    do: failed(:invalid_type, "value must be a collection")

  defp evaluate_node(%{"op" => "collection.unique_by", "paths" => paths}, value, opts)
       when is_list(value) do
    Budget.value(paths, Keyword.fetch!(opts, :rule_budget))
    keys = Enum.map(value, fn item -> Enum.map(paths, &fetch_path(item, &1, opts)) end)
    Budget.value(keys, Keyword.fetch!(opts, :rule_budget))

    if Enum.any?(keys, fn key -> Enum.any?(key, &(&1 == @missing)) end),
      do: failed(:missing_unique_field, "collection uniqueness fields are missing"),
      else:
        if(length(keys) == length(Enum.uniq(keys)),
          do: :passed,
          else: failed(:duplicate_collection_value, "collection contains duplicate values")
        )
  end

  defp evaluate_node(%{"op" => "collection.unique_by"}, _value, _opts),
    do: failed(:invalid_type, "value must be a collection")

  defp evaluate_node(%{"op" => "object.shape"} = test, value, opts) when is_map(value) do
    keys = Map.keys(value) |> Enum.map(&to_string/1)
    required = test["required"]
    properties = test["properties"]

    cond do
      Enum.any?(required, &(&1 not in keys)) ->
        failed(:missing_object_key, "object is missing a required key")

      not test["additional"] and Enum.any?(keys, &(not Map.has_key?(properties, &1))) ->
        failed(:unknown_object_key, "object contains an undeclared key")

      true ->
        evaluate_object_properties(properties, value, opts)
    end
  end

  defp evaluate_node(%{"op" => "object.shape"}, _value, _opts),
    do: failed(:invalid_type, "value must be an object")

  defp evaluate_node(%{"op" => "path.test", "path" => path, "test" => nested_test}, value, opts) do
    do_evaluate(
      nested_test,
      fetch_path(Keyword.get(opts, :condition_values, value), path, opts),
      opts
    )
  end

  defp evaluate_node(%{"op" => "value.eq", "value" => expected}, value, opts),
    do:
      if(equal?(value, expected, opts),
        do: :passed,
        else: failed(:not_equal, "value does not equal its declared value")
      )

  defp evaluate_node(%{"op" => "value.neq", "value" => expected}, value, opts),
    do:
      if(not equal?(value, expected, opts),
        do: :passed,
        else: failed(:equal_to_excluded, "value equals its excluded value")
      )

  defp evaluate_node(
         %{"op" => "value.compare_path", "comparison" => comparison, "path" => path},
         value,
         opts
       ) do
    related = fetch_path(Keyword.get(opts, :values, %{}), path, opts)

    case compare_related(value, related, comparison, opts) do
      :passed -> :passed
      {:failed, _details} = failed -> failed
    end
  end

  for {op, kind} <- [
        {"temporal.date", :date},
        {"temporal.time", :time},
        {"temporal.instant", :instant}
      ] do
    defp evaluate_node(%{"op" => unquote(op)}, value, _opts) do
      case temporal(value, unquote(kind)) do
        {:ok, _value} -> :passed
        :error -> failed(:invalid_temporal_value, "value is not a valid #{unquote(kind)}")
      end
    end
  end

  defp evaluate_node(
         %{
           "op" => "temporal.compare_path",
           "kind" => kind,
           "comparison" => comparison,
           "path" => path
         },
         value,
         opts
       ) do
    related = fetch_path(Keyword.get(opts, :values, %{}), path, opts)

    with {:ok, value} <- temporal(value, temporal_kind(kind)),
         {:ok, related} <- temporal(related, temporal_kind(kind)) do
      temporal_comparison(value, related, comparison)
    else
      :error ->
        failed(:invalid_temporal_value, "temporal comparison requires matching valid values")
    end
  end

  defp evaluate_node(%{"op" => "all", "rules" => rules}, value, opts) do
    results = Enum.map(rules, &do_evaluate(&1, value, opts))

    cond do
      Enum.any?(results, &match?({:error, _}, &1)) ->
        Enum.find(results, &match?({:error, _}, &1))

      Enum.any?(results, &match?({:failed, _}, &1)) ->
        Enum.find(results, &match?({:failed, _}, &1))

      true ->
        :passed
    end
  end

  defp evaluate_node(%{"op" => "any", "rules" => rules}, value, opts) do
    results = Enum.map(rules, &do_evaluate(&1, value, opts))

    cond do
      Enum.any?(results, &match?({:error, _}, &1)) -> Enum.find(results, &match?({:error, _}, &1))
      Enum.any?(results, &(&1 == :passed)) -> :passed
      true -> hd(results)
    end
  end

  defp evaluate_node(%{"op" => "not", "rule" => rule}, value, opts) do
    case do_evaluate(rule, value, opts) do
      :passed -> failed(:negated_rule_matched, "negated rule matched")
      {:failed, _details} -> :passed
      {:error, _details} = error -> error
    end
  end

  defp evaluate_node(_test, _value, _opts),
    do: errored(:unsupported_rule, "compiled rule is unsupported")

  defp do_evaluate(test, value, opts) do
    Budget.spend(Keyword.fetch!(opts, :rule_budget))
    evaluate_node(test, value, opts)
  end

  defp safe_evaluate(test, value, opts) do
    Budget.artifact(test, Keyword.fetch!(opts, :rule_budget))
    do_evaluate(test, value, opts)
  rescue
    Budget.Limit ->
      evaluation_limit()

    error ->
      errored(:rule_evaluation_error, "rule evaluation failed safely",
        exception: Exception.message(error)
      )
  end

  defp evaluate_object_properties(properties, value, opts) do
    properties
    |> Enum.sort_by(fn {key, _test} -> key end)
    |> Enum.reduce_while(:passed, fn {key, property_test}, :passed ->
      case fetch_path(value, [key], opts) do
        @missing ->
          {:cont, :passed}

        property_value ->
          case do_evaluate(property_test, property_value, opts) do
            :passed -> {:cont, :passed}
            {:failed, details} -> {:halt, {:failed, Map.put(details, :object_key, key)}}
            {:error, details} -> {:halt, {:error, Map.put(details, :object_key, key)}}
          end
      end
    end)
  end

  defp safe_normalize_step(step, value, opts) do
    Budget.spend(Keyword.fetch!(opts, :rule_budget))

    with {:ok, normalized} <- normalize_step(step, value),
         :ok <- guarded_values(normalized, opts),
         do: {:ok, normalized}
  rescue
    Budget.Limit ->
      evaluation_limit()

    error ->
      {:error,
       %{
         code: :normalizer_error,
         message: "normalizer failed safely",
         exception: Exception.message(error)
       }}
  end

  defp normalize_step(%{"op" => "text.trim"}, value) when is_binary(value),
    do: {:ok, Regex.replace(~r/\A[ \t\r\n\v\f]+|[ \t\r\n\v\f]+\z/, value, "")}

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

  defp collection_sum(values, path, opts) do
    Enum.reduce_while(values, {:ok, Decimal.new(0)}, fn value, {:ok, total} ->
      case fetch_path(value, path, opts) do
        @missing ->
          {:halt, {:error, :missing}}

        item ->
          case decimal(item, opts) do
            {:ok, number} ->
              Budget.arithmetic(total, number, Keyword.fetch!(opts, :rule_budget), :add)

              sum =
                Decimal.Context.with(%Decimal.Context{precision: 8194}, fn ->
                  Decimal.add(total, number)
                end)

              Budget.number(sum, Keyword.fetch!(opts, :rule_budget))
              {:cont, {:ok, sum}}

            :error ->
              {:halt, {:error, :invalid}}
          end
      end
    end)
  end

  defp check_numeric_bounds(total, test, opts) do
    cond do
      exact = test["exact"] ->
        if compare(total, exact.decimal, :eq, opts), do: :ok, else: {:error, :exact}

      minimum = test["min"] ->
        if compare(total, minimum.decimal, :gte, opts),
          do: check_numeric_maximum(total, test["max"], opts),
          else: {:error, :minimum}

      true ->
        check_numeric_maximum(total, test["max"], opts)
    end
  end

  defp check_numeric_maximum(_total, nil, _opts), do: :ok

  defp check_numeric_maximum(total, maximum, opts) do
    if compare(total, maximum.decimal, :lte, opts),
      do: :ok,
      else: {:error, :maximum}
  end

  defp compare(left, right, kind, opts) do
    Budget.arithmetic(left, right, Keyword.fetch!(opts, :rule_budget), :compare)
    comparison = Decimal.compare(left, right)

    case kind do
      :gt -> comparison == :gt
      :gte -> comparison in [:gt, :eq]
      :lt -> comparison == :lt
      :lte -> comparison in [:lt, :eq]
      :eq -> comparison == :eq
    end
  end

  defp compare_related(_value, @missing, _comparison, _opts),
    do: failed(:missing_related_value, "related comparison value is missing")

  defp compare_related(left, right, comparison, opts) when comparison in ["eq", "neq"] do
    same? = equal?(left, right, opts)
    valid = if comparison == "eq", do: same?, else: not same?

    if valid,
      do: :passed,
      else: failed(:related_value_comparison, "value violates its related-field comparison")
  end

  defp compare_related(left, right, comparison, opts) do
    with {:ok, left} <- decimal(left, opts),
         {:ok, right} <- decimal(right, opts) do
      valid =
        case comparison do
          "gt" -> compare(left, right, :gt, opts)
          "gte" -> compare(left, right, :gte, opts)
          "lt" -> compare(left, right, :lt, opts)
          "lte" -> compare(left, right, :lte, opts)
        end

      if valid,
        do: :passed,
        else: failed(:related_value_comparison, "value violates its related-field comparison")
    else
      :error -> failed(:invalid_related_value_type, "related comparison requires exact numbers")
    end
  end

  defp temporal_kind("date"), do: :date
  defp temporal_kind("time"), do: :time
  defp temporal_kind("instant"), do: :instant

  defp temporal(%Date{} = value, :date), do: {:ok, value}

  defp temporal(value, :date) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp temporal(%Time{} = value, :time), do: {:ok, value}

  defp temporal(value, :time) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, time}
      _ -> :error
    end
  end

  defp temporal(%DateTime{} = value, :instant), do: {:ok, value}

  defp temporal(value, :instant) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp temporal(_value, _kind), do: :error

  defp temporal_comparison(left, right, comparison) do
    compared = compare_temporal(left, right)

    valid =
      case comparison do
        "gt" -> compared == :gt
        "gte" -> compared in [:gt, :eq]
        "lt" -> compared == :lt
        "lte" -> compared in [:lt, :eq]
        "eq" -> compared == :eq
        "neq" -> compared != :eq
      end

    if valid,
      do: :passed,
      else: failed(:temporal_comparison, "value violates its temporal comparison")
  end

  defp compare_temporal(%Date{} = left, %Date{} = right), do: Date.compare(left, right)
  defp compare_temporal(%Time{} = left, %Time{} = right), do: Time.compare(left, right)

  defp compare_temporal(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right)

  defp decimal(value, opts) when is_integer(value) do
    Budget.value(value, Keyword.fetch!(opts, :rule_budget))
    {:ok, Decimal.new(value)}
  end

  defp decimal(%Decimal{} = value, opts) do
    Budget.number(value, Keyword.fetch!(opts, :rule_budget))
    {:ok, value}
  end

  defp decimal(value, opts) when is_binary(value) do
    Budget.pattern_text(value, Keyword.fetch!(opts, :rule_budget))

    if Regex.match?(~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/, value) do
      case Decimal.parse(value) do
        {decimal, ""} ->
          Budget.number(decimal, Keyword.fetch!(opts, :rule_budget))
          {:ok, decimal}

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp decimal(_value, _opts), do: :error

  defp equal?(left, right, opts) do
    Budget.value(left, Keyword.fetch!(opts, :rule_budget))
    Budget.value(right, Keyword.fetch!(opts, :rule_budget))
    left == right
  end

  defp fetch_path(value, [], _opts), do: value

  defp fetch_path(map, [segment | rest], opts) when is_map(map) do
    Budget.spend(Keyword.fetch!(opts, :rule_budget), map_size(map) + 1)

    case Enum.find(map, fn {key, _value} -> to_string(key) == segment end) do
      nil -> @missing
      {_key, value} -> fetch_path(value, rest, opts)
    end
  end

  defp fetch_path(_value, _path, opts) do
    Budget.spend(Keyword.fetch!(opts, :rule_budget))
    @missing
  end

  defp put_path(map, [segment], value, opts) when is_map(map) do
    Budget.spend(Keyword.fetch!(opts, :rule_budget), map_size(map) + 1)

    case Enum.find(Map.keys(map), &(to_string(&1) == segment)) do
      nil -> Map.put(map, segment, value)
      key -> Map.put(map, key, value)
    end
  end

  defp put_path(map, [segment | rest], value, opts) when is_map(map) do
    Budget.spend(Keyword.fetch!(opts, :rule_budget), map_size(map) + 1)
    key = Enum.find(Map.keys(map), segment, &(to_string(&1) == segment))
    child = Map.get(map, key, %{})
    Map.put(map, key, put_path(child, rest, value, opts))
  end

  defp put_path(value, _path, _replacement, _opts), do: value

  defp guarded_values(values, opts) do
    Budget.value(values, Keyword.fetch!(opts, :rule_budget))
    :ok
  rescue
    Budget.Limit -> evaluation_limit()
  end

  defp evaluation_limit,
    do: errored(:evaluation_limit, "portable rule evaluation limit exceeded")

  defp failed(code, message, attrs \\ []),
    do: {:failed, attrs |> Map.new() |> Map.merge(%{code: code, message: message})}

  defp errored(code, message, attrs \\ []),
    do: {:error, attrs |> Map.new() |> Map.merge(%{code: code, message: message})}

  defp display_number(number), do: Decimal.to_string(number, :normal)
  defp maybe_string(nil), do: nil
  defp maybe_string(value), do: to_string(value)
end
