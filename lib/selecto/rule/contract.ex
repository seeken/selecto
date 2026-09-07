defmodule Selecto.Rule.Contract do
  @moduledoc """
  Compiles the portable `selecto.data_rules.v1` Domain section.

  The compiler is pure: it resolves definitions, normalizers, bindings, stages,
  and feature requirements without reading a database or running host code.
  """

  alias Selecto.Domain
  alias Selecto.Domain.Contract.Shared.Core

  @schema "selecto.data_rules.v1"
  @rules_keys ~w(schema definitions normalizers bindings)
  @definition_keys ~w(version test message)
  @normalizer_keys ~w(version steps)
  @binding_keys ~w(subject operations rule normalizer condition enforcement native_constraint)
  @native_constraint_keys ~w(adapter constraint category)
  @native_constraint_categories ~w(unique_violation foreign_key_violation not_null_violation check_violation)
  @subject_keys ~w(scope path action)
  @message_keys ~w(key default)
  @ref_keys ~w(id version)
  @supported_scopes ~w(input action_input candidate transaction evidence)
  @supported_enforcement ~w(required advisory)
  @supported_normalizers ~w(text.trim text.uppercase text.lowercase text.nfc text.line_endings text.empty_to_null)
  @supported_ops ~w(
    presence.required presence.non_null presence.absent type.is text.nonblank
    text.length text.pattern text.prefix text.suffix text.contains
    number.gt number.gte number.lt number.lte number.range number.integer number.multiple_of
    membership.in membership.not_in collection.count collection.unique_by
    object.shape path.test
    value.eq value.neq value.compare_path
    temporal.date temporal.time temporal.instant temporal.compare_path
    all any not
  )

  @enforce_keys [:definitions, :normalizers, :bindings]
  defstruct schema: @schema,
            definitions: %{},
            normalizers: %{},
            bindings: %{},
            fingerprint: nil,
            required_features: []

  @type t :: %__MODULE__{}

  @doc "Compiles one inline rule test with the same fail-closed v1 rules as a registry definition."
  @spec compile_test(term()) :: {:ok, map()} | {:error, map()}
  def compile_test(test), do: compile_test(test, [:test], 0)

  @spec compile(term()) :: {:ok, t()} | {:error, [map()]}
  def compile(%{domain: %{}, schema_version: _} = normalized), do: compile_normalized(normalized)

  def compile(input) when is_map(input) do
    {:ok, normalized, _diagnostics} = Domain.normalize(input)
    compile_normalized(normalized)
  end

  def compile(_input),
    do: {:error, [error(:invalid_rules_input, [], "rules input must be a Domain map")]}

  @doc false
  @spec compile_normalized(map()) :: {:ok, t()} | {:error, [map()]}
  def compile_normalized(normalized) do
    rules = Map.get(normalized, :rules, %{})

    case compile_rules(rules) do
      {:ok, contract} ->
        case validate_subjects(contract, normalized) do
          :ok -> {:ok, contract}
          {:error, error} -> {:error, [error]}
        end

      {:error, error} when is_map(error) ->
        {:error, [error]}

      {:error, errors} ->
        {:error, errors}
    end
  end

  @doc false
  @spec errors(map()) :: [map()]
  def errors(normalized) do
    case compile_normalized(normalized) do
      {:ok, _contract} -> []
      {:error, errors} -> errors
    end
  end

  @doc """
  Projects a compiled contract into a deterministic consumer artifact.

  The projection contains only bindings for the requested stages and only the
  definitions and normalizers those bindings reference. Evaluation markers are
  descriptive: local evaluation is a user-experience optimization and every
  submitted value still requires authoritative server evaluation.
  """
  @spec project(t(), keyword()) :: map()
  def project(%__MODULE__{} = contract, opts \\ []) do
    stages =
      opts
      |> Keyword.get(:stages, @supported_scopes)
      |> normalize_projected_stages()

    bindings =
      contract.bindings
      |> Enum.filter(fn {_id, binding} -> MapSet.member?(stages, binding.stage) end)
      |> Map.new()

    definition_ids = MapSet.new(bindings, fn {_id, binding} -> binding.rule.id end)

    normalizer_ids =
      bindings
      |> Enum.flat_map(fn
        {_id, %{normalizer: %{id: id}}} -> [id]
        _ -> []
      end)
      |> MapSet.new()

    semantic = %{
      schema: @schema,
      definitions: Map.take(contract.definitions, MapSet.to_list(definition_ids)),
      normalizers: Map.take(contract.normalizers, MapSet.to_list(normalizer_ids)),
      bindings: bindings,
      required_features: required_features(contract, bindings)
    }

    projected = portable(semantic)

    projected
    |> Map.put("fingerprint", semantic_fingerprint(semantic))
    |> Map.put("evaluation", evaluation_markers(bindings))
  end

  defp normalize_projected_stages(:all), do: MapSet.new(@supported_scopes)

  defp normalize_projected_stages(stages) when is_list(stages),
    do: MapSet.new(stages, &to_string/1)

  defp compile_rules(rules) when rules in [nil, %{}] do
    {:ok, finish(%__MODULE__{definitions: %{}, normalizers: %{}, bindings: %{}})}
  end

  defp compile_rules(rules) when is_map(rules) do
    with :ok <- known_keys(rules, @rules_keys, [:rules]),
         :ok <- require_schema(rules),
         {:ok, definitions} <- compile_registry(value(rules, :definitions, %{}), :definition),
         {:ok, normalizers} <- compile_registry(value(rules, :normalizers, %{}), :normalizer),
         {:ok, bindings} <- compile_registry(value(rules, :bindings, %{}), :binding),
         :ok <- validate_bindings(bindings, definitions, normalizers) do
      {:ok,
       finish(%__MODULE__{
         definitions: definitions,
         normalizers: normalizers,
         bindings: bindings
       })}
    end
  end

  defp compile_rules(other) do
    {:error,
     [error(:invalid_rules_section, [:rules], "rules must be a map", actual: kind(other))]}
  end

  defp require_schema(rules) do
    case value(rules, :schema) do
      @schema ->
        :ok

      schema ->
        {:error,
         [
           error(:invalid_rules_schema, [:rules, :schema], "rules schema must be #{@schema}",
             actual: schema
           )
         ]}
    end
  end

  defp compile_registry(registry, entry_kind) when is_map(registry) do
    registry
    |> Enum.sort_by(fn {id, _spec} -> to_string(id) end)
    |> Enum.reduce_while({:ok, %{}}, fn {id, spec}, {:ok, acc} ->
      id = to_string(id)

      result =
        cond do
          id == "" ->
            {:error,
             error(:invalid_rule_id, [:rules, plural(entry_kind)], "rule ids must be non-empty")}

          Map.has_key?(acc, id) ->
            {:error,
             error(
               :duplicate_rule_id,
               [:rules, plural(entry_kind), id],
               "normalized rule ids must be unique"
             )}

          true ->
            compile_entry(entry_kind, id, spec)
        end

      case result do
        {:ok, compiled} -> {:cont, {:ok, Map.put(acc, id, compiled)}}
        {:error, error} -> {:halt, {:error, [error]}}
      end
    end)
  end

  defp compile_registry(other, entry_kind) do
    {:error,
     [
       error(
         :invalid_rule_registry,
         [:rules, plural(entry_kind)],
         "#{plural(entry_kind)} must be a map",
         actual: kind(other)
       )
     ]}
  end

  defp compile_entry(:definition, id, spec) when is_map(spec) do
    path = [:rules, :definitions, id]

    with :ok <- known_keys(spec, @definition_keys, path),
         {:ok, version} <- positive_version(value(spec, :version), path ++ [:version]),
         {:ok, test} <- compile_test(value(spec, :test), path ++ [:test], 0),
         {:ok, message} <- compile_message(value(spec, :message, %{}), path ++ [:message]) do
      {:ok, %{id: id, version: version, test: test, message: message}}
    end
  end

  defp compile_entry(:normalizer, id, spec) when is_map(spec) do
    path = [:rules, :normalizers, id]

    with :ok <- known_keys(spec, @normalizer_keys, path),
         {:ok, version} <- positive_version(value(spec, :version), path ++ [:version]),
         {:ok, steps} <- compile_steps(value(spec, :steps), path ++ [:steps]) do
      {:ok, %{id: id, version: version, steps: steps}}
    end
  end

  defp compile_entry(:binding, id, spec) when is_map(spec) do
    path = [:rules, :bindings, id]

    with :ok <- known_keys(spec, @binding_keys, path),
         {:ok, subject} <- compile_subject(value(spec, :subject), path ++ [:subject]),
         {:ok, rule} <- compile_ref(value(spec, :rule), path ++ [:rule]),
         {:ok, normalizer} <-
           compile_optional_ref(value(spec, :normalizer), path ++ [:normalizer]),
         {:ok, native_constraint} <-
           compile_optional_native_constraint(
             value(spec, :native_constraint),
             path ++ [:native_constraint]
           ),
         {:ok, enforcement} <-
           enum(
             value(spec, :enforcement, "required"),
             @supported_enforcement,
             path ++ [:enforcement]
           ),
         {:ok, operations} <- operations(value(spec, :operations, []), path ++ [:operations]),
         {:ok, condition} <- compile_optional_test(value(spec, :condition), path ++ [:condition]) do
      binding = %{
        id: id,
        subject: subject,
        rule: rule,
        normalizer: normalizer,
        enforcement: enforcement,
        operations: operations,
        condition: condition,
        stage: subject.scope
      }

      {:ok,
       if(native_constraint,
         do: Map.put(binding, :native_constraint, native_constraint),
         else: binding
       )}
    end
  end

  defp compile_entry(kind_name, id, other) do
    {:error,
     error(:invalid_rule_entry, [:rules, plural(kind_name), id], "rule entries must be maps",
       actual: kind(other)
     )}
  end

  defp compile_optional_native_constraint(nil, _path), do: {:ok, nil}

  defp compile_optional_native_constraint(spec, path) when is_map(spec) do
    with :ok <- known_keys(spec, @native_constraint_keys, path),
         {:ok, adapter} <- native_constraint_id(value(spec, :adapter), path ++ [:adapter]),
         {:ok, constraint} <-
           native_constraint_id(value(spec, :constraint), path ++ [:constraint]),
         {:ok, category} <-
           enum(value(spec, :category), @native_constraint_categories, path ++ [:category]) do
      {:ok, %{adapter: adapter, constraint: constraint, category: category}}
    end
  end

  defp compile_optional_native_constraint(_spec, path),
    do:
      {:error,
       error(:invalid_native_constraint, path, "native constraint declarations must be maps")}

  defp compile_message(message, path) when is_map(message) do
    with :ok <- known_keys(message, @message_keys, path) do
      key = value(message, :key)
      default = value(message, :default)

      if Enum.all?([key, default], &(is_nil(&1) or (is_binary(&1) and String.trim(&1) != ""))) do
        {:ok, compact(%{key: key, default: default})}
      else
        {:error,
         error(:invalid_rule_message, path, "rule message values must be non-empty strings")}
      end
    end
  end

  defp compile_message(_message, path),
    do: {:error, error(:invalid_rule_message, path, "rule message must be a map")}

  defp compile_steps(steps, path) when is_list(steps) and steps != [] do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {step, index}, {:ok, acc} ->
      step_path = path ++ [index]
      op = value(step, :op)

      cond do
        not is_map(step) ->
          {:halt,
           {:error, error(:invalid_normalizer, step_path, "normalizer steps must be maps")}}

        op not in @supported_normalizers ->
          {:halt,
           {:error,
            error(:unsupported_normalizer, step_path ++ [:op], "normalizer is unsupported",
              actual: op
            )}}

        true ->
          case compile_step(step, step_path) do
            {:ok, compiled} -> {:cont, {:ok, acc ++ [compiled]}}
            {:error, error} -> {:halt, {:error, error}}
          end
      end
    end)
  end

  defp compile_steps(_steps, path),
    do:
      {:error,
       error(:invalid_normalizer_steps, path, "normalizer steps must be a non-empty list")}

  defp compile_step(step, path) do
    op = value(step, :op)
    profile = value(step, :profile)

    with :ok <- known_keys(step, normalizer_keys(op), path),
         :ok <- valid_normalizer_profile(op, profile, path) do
      {:ok, string_keys(step)}
    end
  end

  defp normalizer_keys(op)
       when op in ["text.trim", "text.uppercase", "text.lowercase", "text.nfc"],
       do: ~w(op profile)

  defp normalizer_keys(_op), do: ~w(op)

  defp valid_normalizer_profile("text.trim", profile, _path)
       when profile in ["ascii_v1", "ascii_whitespace_v1"],
       do: :ok

  defp valid_normalizer_profile(op, "ascii_v1", _path)
       when op in ["text.uppercase", "text.lowercase"],
       do: :ok

  defp valid_normalizer_profile("text.nfc", "unicode_nfc_v1", _path), do: :ok

  defp valid_normalizer_profile(op, nil, _path)
       when op in ["text.line_endings", "text.empty_to_null"],
       do: :ok

  defp valid_normalizer_profile(_op, profile, path) do
    {:error,
     error(:invalid_normalizer_profile, path ++ [:profile], "normalizer profile is unsupported",
       actual: profile
     )}
  end

  defp compile_subject(subject, path) when is_map(subject) do
    with :ok <- known_keys(subject, @subject_keys, path),
         {:ok, scope} <- enum(value(subject, :scope), @supported_scopes, path ++ [:scope]),
         {:ok, segments} <- semantic_path(value(subject, :path), path ++ [:path]) do
      action = value(subject, :action)

      if scope == "action_input" and not non_empty_id?(action) do
        {:error,
         error(
           :missing_rule_action,
           path ++ [:action],
           "action_input subjects must name an action"
         )}
      else
        {:ok, compact(%{scope: scope, path: segments, action: maybe_id(action)})}
      end
    end
  end

  defp compile_subject(_subject, path),
    do: {:error, error(:invalid_rule_subject, path, "rule subject must be a map")}

  defp compile_ref(ref, path) when is_map(ref) do
    with :ok <- known_keys(ref, @ref_keys, path),
         id when is_binary(id) and id != "" <- maybe_id(value(ref, :id)),
         {:ok, version} <- positive_version(value(ref, :version), path ++ [:version]) do
      {:ok, %{id: id, version: version}}
    else
      nil ->
        {:error,
         error(:invalid_rule_reference, path ++ [:id], "rule references need a non-empty id")}

      {:error, _error} = error ->
        error
    end
  end

  defp compile_ref(_ref, path),
    do: {:error, error(:invalid_rule_reference, path, "rule references must be maps")}

  defp compile_optional_ref(nil, _path), do: {:ok, nil}
  defp compile_optional_ref(ref, path), do: compile_ref(ref, path)
  defp compile_optional_test(nil, _path), do: {:ok, nil}
  defp compile_optional_test(test, path), do: compile_test(test, path, 0)

  defp compile_test(_test, path, depth) when depth > 16,
    do: {:error, error(:rule_depth_exceeded, path, "rule AST depth exceeds 16")}

  defp compile_test(test, path, depth) when is_map(test) do
    op = value(test, :op)

    cond do
      op not in @supported_ops ->
        {:error,
         error(:unsupported_rule_operator, path ++ [:op], "rule operator is unsupported",
           actual: op
         )}

      op in ["all", "any"] ->
        children = value(test, :rules)

        if is_list(children) and children != [] do
          children
          |> Enum.with_index()
          |> Enum.reduce_while({:ok, []}, fn {child, index}, {:ok, acc} ->
            case compile_test(child, path ++ [:rules, index], depth + 1) do
              {:ok, compiled} -> {:cont, {:ok, acc ++ [compiled]}}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)
          |> case do
            {:ok, compiled} -> {:ok, %{"op" => op, "rules" => compiled}}
            error -> error
          end
        else
          {:error,
           error(
             :invalid_logical_rule,
             path ++ [:rules],
             "all/any require a non-empty rules list"
           )}
        end

      op == "not" ->
        with {:ok, child} <- compile_test(value(test, :rule), path ++ [:rule], depth + 1) do
          {:ok, %{"op" => op, "rule" => child}}
        end

      op == "text.pattern" ->
        compile_pattern(test, path)

      op == "type.is" ->
        compile_type(test, path)

      op == "text.length" ->
        compile_bounds(test, path, ~w(op min max exact unit), "unicode_scalar")

      op == "collection.count" ->
        compile_bounds(test, path, ~w(op min max exact), nil)

      op in ["number.gt", "number.gte", "number.lt", "number.lte"] ->
        compile_number_bound(test, path)

      op == "number.range" ->
        compile_number_range(test, path)

      op == "number.multiple_of" ->
        compile_number_multiple(test, path)

      op in ["membership.in", "membership.not_in"] ->
        compile_values(test, path)

      op == "collection.unique_by" ->
        compile_unique_by(test, path)

      op == "object.shape" ->
        compile_object_shape(test, path, depth)

      op == "path.test" ->
        compile_path_test(test, path, depth)

      op in ["text.prefix", "text.suffix", "text.contains"] ->
        compile_text_operand(test, path)

      op in ["value.eq", "value.neq"] ->
        compile_literal_operand(test, path)

      op == "value.compare_path" ->
        compile_compare_path(test, path)

      op == "temporal.compare_path" ->
        compile_temporal_compare_path(test, path)

      true ->
        compile_leaf(test, path, ~w(op))
    end
  end

  defp compile_test(_test, path, _depth),
    do: {:error, error(:invalid_rule_test, path, "rule tests must be maps")}

  defp compile_pattern(test, path) do
    with :ok <- known_keys(test, ~w(op profile pattern match flags), path),
         "ascii_v1" <- value(test, :profile),
         pattern when is_binary(pattern) <- value(test, :pattern),
         true <- byte_size(pattern) in 1..256,
         true <- String.printable?(pattern) and ascii?(pattern),
         mode when mode in ["full", "search"] <- value(test, :match),
         flags when flags in [nil, []] <- value(test, :flags, []),
         :ok <- portable_pattern(pattern),
         {:ok, _regex} <- Regex.compile(pattern) do
      {:ok,
       %{
         "op" => "text.pattern",
         "profile" => "ascii_v1",
         "pattern" => pattern,
         "match" => mode,
         "flags" => []
       }}
    else
      {:error, reason} ->
        {:error,
         error(:invalid_text_pattern, path, "text pattern is invalid", reason: inspect(reason))}

      _ ->
        {:error,
         error(
           :invalid_text_pattern,
           path,
           "text.pattern requires bounded ascii_v1 syntax, full/search mode, and no flags"
         )}
    end
  end

  defp compile_type(test, path) do
    supported = ~w(text string integer decimal boolean collection object)

    with :ok <- known_keys(test, ~w(op type), path),
         type when is_binary(type) <- value(test, :type) do
      if type in supported do
        {:ok, %{"op" => "type.is", "type" => type}}
      else
        invalid_type_rule(path, supported)
      end
    else
      _ -> invalid_type_rule(path, supported)
    end
  end

  defp invalid_type_rule(path, supported) do
    {:error,
     error(:invalid_type_rule, path ++ [:type], "type.is requires a supported portable type",
       supported: supported
     )}
  end

  defp compile_bounds(test, path, allowed, default_unit) do
    with :ok <- known_keys(test, allowed, path),
         :ok <- non_negative_optional(value(test, :min), path ++ [:min]),
         :ok <- non_negative_optional(value(test, :max), path ++ [:max]),
         :ok <- non_negative_optional(value(test, :exact), path ++ [:exact]),
         :ok <- valid_bounds(value(test, :min), value(test, :max), value(test, :exact), path) do
      unit = value(test, :unit, default_unit)

      if default_unit && unit != default_unit do
        {:error,
         error(:invalid_rule_length_unit, path ++ [:unit], "v1 text length uses unicode_scalar")}
      else
        {:ok,
         compact(%{
           "op" => value(test, :op),
           "min" => value(test, :min),
           "max" => value(test, :max),
           "exact" => value(test, :exact),
           "unit" => unit
         })}
      end
    end
  end

  defp compile_number_bound(test, path) do
    with :ok <- known_keys(test, ~w(op bound), path),
         {:ok, bound} <- number_literal(value(test, :bound), path ++ [:bound]) do
      {:ok, %{"op" => value(test, :op), "bound" => bound}}
    end
  end

  defp compile_number_range(test, path) do
    with :ok <- known_keys(test, ~w(op min max include_min include_max), path),
         {:ok, minimum} <- number_literal(value(test, :min), path ++ [:min]),
         {:ok, maximum} <- number_literal(value(test, :max), path ++ [:max]),
         true <- is_boolean(value(test, :include_min, true)),
         true <- is_boolean(value(test, :include_max, true)),
         true <- Decimal.compare(minimum.decimal, maximum.decimal) != :gt do
      {:ok,
       %{
         "op" => "number.range",
         "min" => minimum,
         "max" => maximum,
         "include_min" => value(test, :include_min, true),
         "include_max" => value(test, :include_max, true)
       }}
    else
      false ->
        {:error,
         error(:invalid_numeric_range, path, "numeric range minimum must not exceed maximum")}

      {:error, _error} = error ->
        error
    end
  end

  defp compile_number_multiple(test, path) do
    with :ok <- known_keys(test, ~w(op factor), path),
         {:ok, factor} <- number_literal(value(test, :factor), path ++ [:factor]),
         false <- Decimal.equal?(factor.decimal, Decimal.new(0)) do
      {:ok, %{"op" => "number.multiple_of", "factor" => factor}}
    else
      true ->
        {:error,
         error(:invalid_numeric_factor, path ++ [:factor], "multiple_of factor must not be zero")}

      {:error, _error} = error ->
        error
    end
  end

  defp compile_values(test, path) do
    with :ok <- known_keys(test, ~w(op values), path),
         values when is_list(values) and values != [] <- value(test, :values),
         true <- Enum.all?(values, &portable_literal?/1) do
      {:ok, %{"op" => value(test, :op), "values" => values}}
    else
      _ ->
        {:error,
         error(
           :invalid_membership_rule,
           path ++ [:values],
           "membership rules require a non-empty values list"
         )}
    end
  end

  defp compile_unique_by(test, path) do
    with :ok <- known_keys(test, ~w(op paths), path),
         paths when is_list(paths) and paths != [] <- value(test, :paths),
         true <- Enum.all?(paths, &valid_semantic_path?/1) do
      {:ok,
       %{
         "op" => "collection.unique_by",
         "paths" => Enum.map(paths, &Enum.map(&1, fn segment -> to_string(segment) end))
       }}
    else
      _ ->
        {:error,
         error(
           :invalid_unique_rule,
           path ++ [:paths],
           "collection.unique_by requires non-empty semantic paths"
         )}
    end
  end

  defp compile_object_shape(test, path, depth) do
    with :ok <- known_keys(test, ~w(op required properties additional), path),
         required when is_list(required) <- value(test, :required, []),
         true <- Enum.all?(required, &object_key?/1),
         properties when is_map(properties) <- value(test, :properties, %{}),
         false <- is_struct(properties),
         true <- map_size(properties) > 0,
         additional when is_boolean(additional) <- value(test, :additional),
         {:ok, compiled_properties} <- compile_object_properties(properties, path, depth),
         true <- Enum.all?(required, &Map.has_key?(compiled_properties, to_string(&1))) do
      {:ok,
       %{
         "op" => "object.shape",
         "required" => required |> Enum.map(&to_string/1) |> Enum.sort(),
         "properties" => compiled_properties,
         "additional" => additional
       }}
    else
      _ ->
        {:error,
         error(
           :invalid_object_shape_rule,
           path,
           "object.shape requires declared properties, required keys within them, and an explicit additional policy"
         )}
    end
  end

  defp compile_object_properties(properties, path, depth) do
    if map_size(properties) <= 64 and
         Enum.all?(Map.keys(properties), &object_key?/1) and
         Map.keys(properties) |> Enum.map(&to_string/1) |> Enum.uniq() |> length() ==
           map_size(properties) do
      properties
      |> Enum.sort_by(fn {key, _test} -> to_string(key) end)
      |> Enum.reduce_while({:ok, %{}}, fn {key, property_test}, {:ok, acc} ->
        case compile_test(property_test, path ++ [:properties, to_string(key)], depth + 1) do
          {:ok, compiled} -> {:cont, {:ok, Map.put(acc, to_string(key), compiled)}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    else
      {:error,
       error(
         :invalid_object_shape_rule,
         path ++ [:properties],
         "object properties must be at most 64 unique non-empty keys"
       )}
    end
  end

  defp object_key?(value), do: is_atom(value) or (is_binary(value) and String.trim(value) != "")

  defp compile_path_test(test, path, depth) do
    with :ok <- known_keys(test, ~w(op path test), path),
         {:ok, target_path} <- semantic_path(value(test, :path), path ++ [:path]),
         {:ok, nested_test} <- compile_test(value(test, :test), path ++ [:test], depth + 1) do
      {:ok, %{"op" => "path.test", "path" => target_path, "test" => nested_test}}
    else
      _ ->
        {:error,
         error(
           :invalid_path_test_rule,
           path,
           "path.test requires a non-empty semantic path and a valid nested rule test"
         )}
    end
  end

  defp compile_text_operand(test, path) do
    with :ok <- known_keys(test, ~w(op text), path),
         text when is_binary(text) <- value(test, :text) do
      {:ok, %{"op" => value(test, :op), "text" => text}}
    else
      _ -> {:error, error(:invalid_text_rule, path, "text rule requires a string operand")}
    end
  end

  defp compile_literal_operand(test, path) do
    with :ok <- known_keys(test, ~w(op value), path),
         true <- has_key?(test, :value),
         true <- portable_literal?(value(test, :value)) do
      {:ok, %{"op" => value(test, :op), "value" => value(test, :value)}}
    else
      _ -> {:error, error(:invalid_value_rule, path, "value comparison requires a value")}
    end
  end

  defp compile_compare_path(test, path) do
    with :ok <- known_keys(test, ~w(op comparison path), path),
         comparison when comparison in ["gt", "gte", "lt", "lte", "eq", "neq"] <-
           value(test, :comparison),
         {:ok, related_path} <- semantic_path(value(test, :path), path ++ [:path]) do
      {:ok, %{"op" => "value.compare_path", "comparison" => comparison, "path" => related_path}}
    else
      _ ->
        {:error,
         error(
           :invalid_related_value_rule,
           path,
           "value.compare_path requires gt/gte/lt/lte/eq/neq and a non-empty semantic path"
         )}
    end
  end

  defp compile_temporal_compare_path(test, path) do
    with :ok <- known_keys(test, ~w(op kind comparison path), path),
         kind when kind in ["date", "time", "instant"] <- value(test, :kind),
         comparison when comparison in ["gt", "gte", "lt", "lte", "eq", "neq"] <-
           value(test, :comparison),
         {:ok, related_path} <- semantic_path(value(test, :path), path ++ [:path]) do
      {:ok,
       %{
         "op" => "temporal.compare_path",
         "kind" => kind,
         "comparison" => comparison,
         "path" => related_path
       }}
    else
      _ ->
        {:error,
         error(
           :invalid_temporal_comparison_rule,
           path,
           "temporal.compare_path requires date/time/instant, gt/gte/lt/lte/eq/neq, and a semantic path"
         )}
    end
  end

  defp compile_leaf(test, path, allowed) do
    with :ok <- known_keys(test, allowed, path), do: {:ok, %{"op" => value(test, :op)}}
  end

  defp validate_bindings(bindings, definitions, normalizers) do
    Enum.reduce_while(bindings, :ok, fn {id, binding}, :ok ->
      path = [:rules, :bindings, id]
      definition = Map.get(definitions, binding.rule.id)
      normalizer = binding.normalizer && Map.get(normalizers, binding.normalizer.id)

      cond do
        is_nil(definition) or definition.version != binding.rule.version ->
          {:halt,
           {:error,
            [
              error(
                :unresolved_rule_reference,
                path ++ [:rule],
                "binding rule id/version does not resolve"
              )
            ]}}

        binding.normalizer &&
            (is_nil(normalizer) or normalizer.version != binding.normalizer.version) ->
          {:halt,
           {:error,
            [
              error(
                :unresolved_normalizer_reference,
                path ++ [:normalizer],
                "binding normalizer id/version does not resolve"
              )
            ]}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_subjects(contract, normalized) do
    Enum.reduce_while(contract.bindings, :ok, fn {id, binding}, :ok ->
      if known_subject?(binding.subject, normalized) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          error(
            :unresolved_rule_subject,
            [:rules, :bindings, id, :subject],
            "rule subject does not resolve in its declared scope",
            scope: binding.subject.scope,
            path: binding.subject.path,
            action: binding.subject[:action]
          )}}
      end
    end)
  end

  defp known_subject?(%{scope: "action_input", action: action, path: [field | _]}, normalized) do
    normalized
    |> Map.get(:actions, %{})
    |> find_entry(action)
    |> action_input_ids()
    |> MapSet.member?(field)
  end

  defp known_subject?(%{scope: "input", path: [field | _]}, normalized) do
    known_write_subject?(normalized, field)
  end

  defp known_subject?(%{scope: scope, path: [field | _]}, normalized)
       when scope in ["candidate", "transaction", "evidence"] do
    field in Core.relation_fields(Map.get(normalized, :source, %{})) or
      known_relationship_subject?(normalized, field)
  end

  defp known_subject?(_subject, _normalized), do: false

  defp known_write_subject?(normalized, field) do
    writes = Map.get(normalized, :writes, %{})

    field in entry_ids(value(writes, :fields, %{})) or
      field in entry_ids(value(writes, :relationships, %{}))
  end

  defp known_relationship_subject?(normalized, field) do
    normalized
    |> Map.get(:writes, %{})
    |> value(:relationships, %{})
    |> entry_ids()
    |> MapSet.member?(field)
  end

  defp action_input_ids(nil), do: MapSet.new()

  defp action_input_ids(action) do
    direct = action |> value(:inputs, %{}) |> input_ids()

    variant =
      action
      |> value(:variants, [])
      |> List.wrap()
      |> Enum.flat_map(fn variant -> variant |> value(:inputs, %{}) |> input_ids() end)

    MapSet.new(direct ++ variant)
  end

  defp input_ids(inputs) when is_map(inputs), do: inputs |> Map.keys() |> Enum.map(&to_string/1)

  defp input_ids(inputs) when is_list(inputs) do
    Enum.flat_map(inputs, fn
      input when is_map(input) ->
        case value(input, :id, value(input, :name)) do
          id when is_atom(id) or is_binary(id) -> [to_string(id)]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp input_ids(_inputs), do: []

  defp entry_ids(entries) when is_map(entries),
    do: MapSet.new(entries, fn {id, _} -> to_string(id) end)

  defp entry_ids(_entries), do: MapSet.new()

  defp find_entry(entries, id) when is_map(entries) do
    case Enum.find(entries, fn {candidate, _value} -> to_string(candidate) == id end) do
      {_key, value} -> value
      nil -> nil
    end
  end

  defp find_entry(entries, id) when is_list(entries) do
    Enum.find(entries, fn entry -> is_map(entry) and maybe_id(value(entry, :id)) == id end)
  end

  defp find_entry(_entries, _id), do: nil

  defp finish(contract) do
    features = required_features(contract, contract.bindings)

    semantic = %{
      schema: @schema,
      definitions: contract.definitions,
      normalizers: contract.normalizers,
      bindings: contract.bindings,
      required_features: features
    }

    fingerprint = semantic_fingerprint(semantic)

    %{contract | fingerprint: fingerprint, required_features: features}
  end

  defp required_features(contract, bindings) do
    definition_ids = MapSet.new(bindings, fn {_id, binding} -> binding.rule.id end)

    definition_features =
      contract.definitions
      |> Enum.filter(fn {id, _definition} -> MapSet.member?(definition_ids, id) end)
      |> Enum.flat_map(fn {_id, definition} -> test_features(definition.test) end)

    condition_features =
      bindings
      |> Enum.flat_map(fn
        {_id, %{condition: nil}} -> []
        {_id, binding} -> ["rule:condition" | test_features(binding.condition)]
      end)

    normalizer_features =
      bindings
      |> Enum.flat_map(fn
        {_id, %{normalizer: nil}} ->
          []

        {_id, binding} ->
          contract.normalizers
          |> Map.fetch!(binding.normalizer.id)
          |> Map.fetch!(:steps)
          |> Enum.map(&"normalizer:#{&1["op"]}")
      end)

    native_constraint_features =
      bindings
      |> Enum.flat_map(fn
        {_id, %{native_constraint: native}} -> ["native_constraint:#{native.adapter}"]
        _ -> []
      end)

    stage_features =
      Enum.map(bindings, fn {_id, binding} -> "rule_stage:#{binding.stage}" end)

    (definition_features ++
       condition_features ++ normalizer_features ++ native_constraint_features ++ stage_features)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp evaluation_markers(bindings) do
    binding_markers =
      bindings
      |> Enum.sort_by(fn {id, _binding} -> id end)
      |> Enum.map(fn {id, binding} ->
        %{
          "binding" => id,
          "stage" => binding.stage,
          "local_eligible" => binding.stage in ["input", "action_input"],
          "server_required" => true,
          "external_evidence_required" => binding.stage == "evidence"
        }
      end)

    %{
      "client_results_authoritative" => false,
      "server_revalidation_required" => binding_markers != [],
      "bindings" => binding_markers
    }
  end

  defp semantic_fingerprint(value) do
    digest =
      :crypto.hash(:sha256, canonical_json(value))
      |> Base.encode16(case: :lower)

    "sha256:#{digest}"
  end

  defp canonical_json(value),
    do: value |> portable() |> encode_canonical_json() |> IO.iodata_to_binary()

  defp encode_canonical_json(map) when is_map(map) do
    members =
      map
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} ->
        [Jason.encode!(to_string(key)), ?:, encode_canonical_json(value)]
      end)

    [?{, Enum.intersperse(members, ?,), ?}]
  end

  defp encode_canonical_json(list) when is_list(list),
    do: [?[, Enum.intersperse(Enum.map(list, &encode_canonical_json/1), ?,), ?]]

  defp encode_canonical_json(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: Jason.encode!(value)

  defp test_features(%{"op" => op} = test) when op in ["all", "any"],
    do: ["rule:logic"] ++ Enum.flat_map(test["rules"], &test_features/1)

  defp test_features(%{"op" => "not", "rule" => rule}), do: ["rule:logic" | test_features(rule)]
  defp test_features(%{"op" => op}), do: ["rule:#{op}"]

  defp known_keys(map, allowed, path) do
    unknown =
      map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in allowed)) |> Enum.sort()

    if unknown == [],
      do: :ok,
      else:
        {:error,
         error(:unknown_rule_option, path, "rule contains unsupported options", options: unknown)}
  end

  defp positive_version(version, _path) when is_integer(version) and version > 0,
    do: {:ok, version}

  defp positive_version(_version, path),
    do: {:error, error(:invalid_rule_version, path, "rule versions must be positive integers")}

  defp semantic_path(path, error_path) when is_list(path) and path != [] do
    if Enum.all?(path, &non_empty_id?/1) do
      {:ok, Enum.map(path, &to_string/1)}
    else
      {:error,
       error(
         :invalid_rule_path,
         error_path,
         "rule paths must contain non-empty string/atom segments"
       )}
    end
  end

  defp semantic_path(_path, error_path),
    do:
      {:error,
       error(
         :invalid_rule_path,
         error_path,
         "rule paths must be non-empty lists of non-empty string/atom segments"
       )}

  defp valid_semantic_path?(path),
    do: is_list(path) and path != [] and Enum.all?(path, &non_empty_id?/1)

  defp operations(operations, path) when is_list(operations) do
    values = Enum.map(operations, &to_string/1)

    if Enum.all?(values, &(&1 in ~w(insert update delete upsert))),
      do: {:ok, values},
      else:
        {:error,
         error(
           :invalid_rule_operations,
           path,
           "rule operations must be insert, update, delete, or upsert"
         )}
  end

  defp operations(_operations, path),
    do: {:error, error(:invalid_rule_operations, path, "rule operations must be a list")}

  defp enum(value, allowed, path) do
    value = if is_atom(value), do: Atom.to_string(value), else: value

    if value in allowed,
      do: {:ok, value},
      else:
        {:error,
         error(:invalid_rule_enum, path, "rule value is unsupported",
           actual: value,
           allowed: allowed
         )}
  end

  defp non_negative_optional(nil, _path), do: :ok
  defp non_negative_optional(value, _path) when is_integer(value) and value >= 0, do: :ok

  defp non_negative_optional(_value, path),
    do: {:error, error(:invalid_rule_bound, path, "rule bounds must be non-negative integers")}

  defp valid_bounds(minimum, maximum, exact, path) do
    cond do
      is_nil(minimum) and is_nil(maximum) and is_nil(exact) ->
        {:error, error(:missing_rule_bound, path, "rule requires min, max, or exact")}

      not is_nil(exact) and (not is_nil(minimum) or not is_nil(maximum)) ->
        {:error, error(:conflicting_rule_bounds, path, "exact cannot be combined with min/max")}

      is_integer(minimum) and is_integer(maximum) and minimum > maximum ->
        {:error, error(:invalid_rule_bounds, path, "minimum must not exceed maximum")}

      true ->
        :ok
    end
  end

  defp number_literal(%{} = literal, path) do
    type = value(literal, :type)
    raw = value(literal, :value)

    with true <- type in ["integer", :integer, "decimal", :decimal],
         {:ok, decimal} <- decimal(raw) do
      {:ok, %{type: to_string(type), value: to_string(raw), decimal: decimal}}
    else
      _ ->
        {:error,
         error(
           :invalid_number_literal,
           path,
           "numeric literals require integer/decimal type and exact value"
         )}
    end
  end

  defp number_literal(value, path) do
    case decimal(value) do
      {:ok, decimal} ->
        {:ok,
         %{
           type: if(is_integer(value), do: "integer", else: "decimal"),
           value: to_string(value),
           decimal: decimal
         }}

      :error ->
        {:error,
         error(
           :invalid_number_literal,
           path,
           "numeric literals must be exact integers or decimal strings"
         )}
    end
  end

  defp decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp decimal(%Decimal{} = value), do: {:ok, value}
  defp decimal(_value), do: :error

  defp portable_pattern(pattern) do
    cond do
      String.contains?(pattern, ["(?", "\\1", "\\2", "\\3", "^", "$"]) ->
        {:error, :unsupported_regex_feature}

      String.contains?(pattern, ["[[:", ":]]", "&&"]) ->
        {:error, :unsupported_character_class}

      Regex.match?(~r/(?:\*|\+|\?|\})[?+]/, pattern) ->
        {:error, :unsupported_quantifier_mode}

      not portable_escapes?(pattern) ->
        {:error, :unsupported_escape}

      true ->
        :ok
    end
  end

  defp portable_escapes?(pattern) do
    pattern
    |> :binary.bin_to_list()
    |> portable_escape_bytes?()
  end

  defp portable_escape_bytes?([]), do: true
  defp portable_escape_bytes?([?\\]), do: false

  defp portable_escape_bytes?([?\\, escaped | rest]) do
    escaped in ~c"\\.^$|?*+()[]{}-dDsSwWtrn" and portable_escape_bytes?(rest)
  end

  defp portable_escape_bytes?([_byte | rest]), do: portable_escape_bytes?(rest)

  defp ascii?(value), do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 < 128))

  defp portable_literal?(value)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_binary(value),
       do: true

  defp portable_literal?(values) when is_list(values), do: Enum.all?(values, &portable_literal?/1)

  defp portable_literal?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} ->
      (is_atom(key) or is_binary(key)) and portable_literal?(item)
    end)
  end

  defp portable_literal?(_value), do: false

  defp non_empty_id?(value),
    do:
      (is_atom(value) and value not in [nil, true, false]) or
        (is_binary(value) and String.trim(value) != "")

  defp native_constraint_id(value, path) do
    if is_binary(value) and String.match?(value, ~r/\A[A-Za-z][A-Za-z0-9_.-]*\z/) do
      {:ok, value}
    else
      {:error,
       error(
         :invalid_native_constraint,
         path,
         "native constraint adapter and name must start with a letter and use letters, numbers, dots, dashes, or underscores"
       )}
    end
  end

  defp maybe_id(nil), do: nil
  defp maybe_id(value) when is_atom(value), do: Atom.to_string(value)
  defp maybe_id(value) when is_binary(value), do: value
  defp maybe_id(_value), do: nil
  defp plural(:definition), do: :definitions
  defp plural(:normalizer), do: :normalizers
  defp plural(:binding), do: :bindings
  defp kind(value) when is_map(value), do: :map
  defp kind(value) when is_list(value), do: :list
  defp kind(value) when is_binary(value), do: :string
  defp kind(value) when is_integer(value), do: :integer
  defp kind(nil), do: :null
  defp kind(_value), do: :other

  defp value(map, key, default \\ nil) do
    case Core.fetch_map_value(map, key) do
      :__missing__ -> default
      value -> value
    end
  end

  defp has_key?(map, key), do: Core.has_key?(map, key)
  defp string_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp portable(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp portable(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), portable(value)} end)

  defp portable(list) when is_list(list), do: Enum.map(list, &portable/1)
  defp portable(value) when is_boolean(value) or is_nil(value), do: value
  defp portable(value) when is_atom(value), do: Atom.to_string(value)
  defp portable(value), do: value

  defp error(code, path, message, attrs \\ []),
    do: attrs |> Map.new() |> Map.merge(%{code: code, path: path, message: message})
end
