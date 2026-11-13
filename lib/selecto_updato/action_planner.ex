defmodule SelectoUpdato.ActionPlanner do
  @moduledoc """
  Builds non-executing Updato action plans from Selecto domain action metadata.

  The planner is intentionally conservative. Direct writes must name the
  shared `updato` executor and pass the write contract. Event-sourced commands
  must name the `event_stream` executor and preserve their aggregate, stream,
  expected-version, and possible-event contract without producing a SQL
  operation builder.
  """

  alias Selecto.Domain
  alias Selecto.Domain.ActionPreconditions
  alias SelectoUpdato.{ActionPlan, ActionTemplate, DomainContract, Operation, PlannedOperation}
  alias SelectoUpdato.{ActionInputCoercion, CollectionPatch, RuleValidation}

  import SelectoUpdato.ActionPlanner.Support

  @type result :: {:ok, ActionPlan.t()} | {:error, map()}

  @supported_operations ~w(insert update upsert delete)
  @supported_executors ~w(updato event_stream)

  @doc """
  Plans a domain action without executing it.

  The input may be either a Selecto domain map or an existing Updato domain
  contract. Every successful plan includes an opaque
  `%SelectoUpdato.PlannedOperation{}` handle. For a full domain, authorization
  materializes the validated write operation inside the trusted adapter
  callback. Contract-only plans preserve a `nil` materialized operation while
  still requiring registered immutable provenance.
  """
  @spec plan(map(), map(), keyword()) :: result()
  def plan(input, intent, opts \\ [])

  def plan(input, intent, opts) when is_map(intent) do
    with {:ok, contract, diagnostics} <- contract(input),
         {:ok, action} <- validate_and_fetch_action(contract, intent, opts),
         {:ok, runtime} <- action_runtime(contract, action, intent) do
      plan_runtime(input, contract, action, runtime, intent, diagnostics, opts)
    end
  end

  def plan(_input, _intent, _opts) do
    {:error,
     error(
       :invalid_action_intent,
       [:intent],
       "Action planning requires an intent map with an action id."
     )}
  end

  defp plan_runtime(input, contract, action, runtime, intent, diagnostics, opts) do
    case execution_kind(Map.fetch!(runtime, :execution)) do
      "updato" ->
        plan_updato_action(input, contract, action, runtime, intent, diagnostics, opts)

      "event_stream" ->
        plan_event_stream_action(action, runtime, intent, diagnostics, opts)

      other ->
        {:error,
         error(
           :unsupported_action_executor,
           [:actions, id(map_get(action, :id)), :execution, :kind],
           "Action #{inspect(id(map_get(action, :id)))} uses unsupported executor #{inspect(other)}."
         )}
    end
  end

  defp plan_updato_action(input, contract, action, runtime, intent, diagnostics, opts) do
    execution = Map.fetch!(runtime, :execution)

    with {:ok, operation_id} <- execution_operation(execution),
         {:ok, operation_spec} <- operation_spec(contract, operation_id),
         {:ok, changes} <-
           execution_changes(
             execution,
             operation_id,
             Map.fetch!(runtime, :inputs),
             trusted_context(opts)
           ),
         {:ok, preconditions} <- action_preconditions(contract, action, changes),
         :ok <- validate_precondition_fields(contract, preconditions),
         :ok <- validate_precondition_operation(operation_id, preconditions),
         {:ok, collection_operations} <-
           CollectionPatch.operations(contract, Map.fetch!(runtime, :collection_patches)),
         {:ok, target_filters} <- action_filters(contract, intent),
         filters <- target_filters ++ precondition_filters(preconditions),
         :ok <- validate_target_cardinality(action, intent),
         expected_cardinality <- target_cardinality(contract, intent),
         :ok <- enforce_required_filter(operation_spec, filters),
         {:ok, scope} <-
           action_scope(contract, action, operation_id, operation_spec, intent, filters),
         returning <- action_returning(execution, operation_spec),
         operation_intent <-
           operation_intent(
             action,
             intent,
             operation_id,
             scope,
             changes,
             filters,
             returning,
             runtime,
             preconditions,
             collection_operations
           ),
         :ok <- validate_operation_intent(contract, operation_intent, opts),
         {:ok, operation_builder} <-
           operation_builder(
             input,
             action,
             operation_id,
             changes,
             filters,
             returning,
             expected_cardinality,
             execution
           ) do
      plan = %ActionPlan{
        action: id(map_get(action, :id)),
        type: map_get(action, :type),
        label: map_get(action, :label),
        description: map_get(action, :description),
        capability: map_get(action, :capability),
        icon: map_get(action, :icon),
        confirmation: map_get(action, :confirmation),
        audit: map_get(action, :audit),
        presentation: map_get(action, :presentation),
        operation: operation_id,
        scope: scope,
        operation_intent: operation_intent,
        operation_builder: operation_builder,
        transition: map_get(action, :transition),
        preconditions: preconditions,
        execution: execution,
        inputs: Map.fetch!(runtime, :inputs),
        variant: Map.get(runtime, :variant),
        execution_case: Map.get(runtime, :execution_case),
        collection_patches: Map.fetch!(runtime, :collection_patches),
        collection_operations: collection_operations,
        target: map_get(intent, :target),
        filters: filters,
        changes: changes,
        returning: returning,
        expected_cardinality: expected_cardinality,
        diagnostics: diagnostics_summary(diagnostics)
      }

      with {:ok, plan} <- SelectoUpdato.DocumentAction.attach(plan) do
        seal_planned_action(plan, opts)
      end
    end
  end

  defp plan_event_stream_action(action, runtime, intent, diagnostics, opts) do
    execution = Map.fetch!(runtime, :execution)

    with {:ok, []} <- declared_action_preconditions(action) do
      plan = %ActionPlan{
        action: id(map_get(action, :id)),
        type: map_get(action, :type),
        label: map_get(action, :label),
        description: map_get(action, :description),
        capability: map_get(action, :capability),
        icon: map_get(action, :icon),
        confirmation: map_get(action, :confirmation),
        audit: map_get(action, :audit),
        presentation: map_get(action, :presentation),
        operation: nil,
        scope: event_stream_scope(action),
        operation_intent: %{
          executor: "event_stream",
          aggregate: map_get(execution, :aggregate),
          bounded_context: map_get(execution, :bounded_context),
          stream_id: map_get(execution, :stream_id),
          consistency: map_get(execution, :consistency),
          possible_events: list_value(execution, :possible_events)
        },
        operation_builder: nil,
        transition: map_get(action, :transition),
        preconditions: [],
        execution: execution,
        inputs: Map.fetch!(runtime, :inputs),
        variant: Map.get(runtime, :variant),
        execution_case: Map.get(runtime, :execution_case),
        collection_patches: %{},
        collection_operations: %{},
        target: map_get(intent, :target),
        filters: [],
        changes: %{},
        returning: nil,
        expected_cardinality: nil,
        diagnostics: diagnostics_summary(diagnostics)
      }

      seal_planned_action(plan, opts)
    else
      {:ok, _preconditions} ->
        {:error,
         error(
           :action_preconditions_unsupported_executor,
           [:actions, id(map_get(action, :id)), :preconditions],
           "Relational filter preconditions are not supported by event-stream actions."
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  # This private protocol assumes application code in the host BEAM is trusted;
  # it is not a sandbox against a module that can send arbitrary GenServer
  # messages. Keeping registration out of the public API prevents untrusted
  # external plan data from minting provenance without passing this planner.
  defp seal_planned_action(%ActionPlan{} = plan, opts) do
    case Process.whereis(SelectoUpdato.ActionAuthorization) do
      nil ->
        action_authorization_unavailable()

      _pid ->
        requested_ttl = Keyword.get(opts, :planned_operation_ttl)

        try do
          case GenServer.call(
                 SelectoUpdato.ActionAuthorization,
                 {:seal_planned_action, plan, requested_ttl},
                 5_000
               ) do
            {:ok, %PlannedOperation{} = handle} ->
              {:ok, %{plan | operation_builder: handle}}

            {:error, _reason} = error ->
              error
          end
        catch
          :exit, _reason -> action_authorization_unavailable()
        end
    end
  end

  defp action_authorization_unavailable do
    {:error,
     {:validation_error, "Action authorization service is unavailable.",
      %{code: :action_authorization_unavailable}}}
  end

  defp contract(input) do
    if contract_document?(input) do
      {:ok, input, %{errors: [], warnings: []}}
    else
      DomainContract.build(input)
    end
  end

  defp validate_and_fetch_action(contract, intent, opts) do
    case DomainContract.validate_intent(contract, intent, opts) do
      %{valid?: true} ->
        action_spec(contract, map_get(intent, :action))

      validation ->
        {:error,
         validation_error(
           :invalid_action_intent,
           [:intent],
           "The action intent is not valid for this domain.",
           validation
         )}
    end
  end

  defp action_spec(contract, action_id) do
    action_id = id(action_id)

    contract
    |> list_value(:actions)
    |> Enum.find(&(id(map_get(&1, :id)) == action_id))
    |> case do
      nil ->
        {:error,
         error(
           :unknown_action,
           [:action],
           "Action #{inspect(action_id)} is not available in this domain contract."
         )}

      action ->
        {:ok, action}
    end
  end

  defp action_runtime(contract, action, intent) do
    submitted_inputs = submitted_action_inputs(action, intent)
    base_input_specs = list_value(action, :inputs)

    with {:ok, base_inputs} <-
           ActionInputCoercion.normalize_values(
             base_input_specs,
             submitted_inputs,
             [
               :intent,
               :inputs
             ],
             required?: true,
             defaults?: true
           ),
         {:ok, selected_variant, variant_inputs} <-
           select_variant(action, base_inputs, submitted_inputs),
         input_specs = base_input_specs ++ list_value(selected_variant || %{}, :inputs),
         inputs = Map.merge(base_inputs, variant_inputs),
         {:ok, rule_contract} <- compile_action_rules(contract),
         {:ok, inputs} <-
           RuleValidation.validate_action_inputs(
             rule_contract,
             id(map_get(action, :id)),
             inputs
           ),
         {:ok, execution} <- selected_execution(action, selected_variant),
         {:ok, execution_case, execution} <- select_execution_case(execution, inputs),
         {:ok, execution} <- supported_execution(execution, action),
         {:ok, collection_patches} <-
           CollectionPatch.normalize_patches(contract, execution, input_specs, inputs) do
      {:ok,
       %{
         inputs: inputs,
         variant: selected_id(selected_variant),
         execution_case: execution_case,
         execution: execution,
         collection_patches: collection_patches
       }}
    end
  end

  defp compile_action_rules(contract) do
    rules =
      contract
      |> map_get(:rules, %{})
      |> authored_rule_contract()

    case Selecto.Rule.Contract.compile(%{
           source: map_get(contract, :source, %{}),
           schemas: %{},
           actions: map_get(contract, :actions, []),
           rules: rules
         }) do
      {:ok, rule_contract} ->
        {:ok, rule_contract}

      {:error, errors} ->
        {:error,
         error(
           :invalid_data_rules,
           [:rules],
           "The action data-rule contract is invalid.",
           errors: errors
         )}
    end
  end

  # API contracts carry compiled projection metadata for consumers. Action
  # planning recompiles the authored portable members; the derived fingerprint,
  # feature list, and authority markers are never treated as author input.
  defp authored_rule_contract(rules) when is_map(rules) do
    rules
    |> Map.drop([
      "fingerprint",
      "required_features",
      "evaluation",
      :fingerprint,
      :required_features,
      :evaluation
    ])
    |> drop_projected_registry_ids()
  end

  defp authored_rule_contract(_rules), do: %{}

  defp drop_projected_registry_ids(rules) do
    Enum.reduce([:definitions, :normalizers, :bindings], rules, fn registry, current ->
      case map_get(current, registry) do
        entries when is_map(entries) ->
          derived_keys =
            if registry == :bindings, do: ["id", :id, "stage", :stage], else: ["id", :id]

          entries = Map.new(entries, fn {id, entry} -> {id, Map.drop(entry, derived_keys)} end)
          Map.put(current, registry, entries)

        _ ->
          current
      end
    end)
  end

  defp submitted_action_inputs(action, intent) do
    declared_ids =
      action
      |> declared_input_ids()
      |> MapSet.new()

    flat_inputs =
      Enum.reduce(declared_ids, %{}, fn input_id, acc ->
        case fetch_value(intent, input_id) do
          {:ok, value} -> Map.put(acc, input_id, value)
          :error -> acc
        end
      end)

    explicit_inputs =
      case map_get(intent, :inputs, %{}) do
        %{} = inputs ->
          inputs
          |> Enum.map(fn {key, value} -> {id(key), value} end)
          |> Map.new()

        _other ->
          %{}
      end

    Map.merge(flat_inputs, explicit_inputs)
  end

  defp declared_input_ids(action) do
    base_ids = input_ids(list_value(action, :inputs))

    variant_ids =
      action
      |> list_value(:variants)
      |> Enum.flat_map(&input_ids(list_value(&1, :inputs)))

    base_ids ++ variant_ids
  end

  defp input_ids(input_specs) do
    input_specs
    |> Enum.map(&(map_get(&1, :id) |> id()))
    |> Enum.reject(&(&1 == ""))
  end

  defp select_variant(action, base_inputs, submitted_inputs) do
    case list_value(action, :variants) do
      [] ->
        {:ok, nil, %{}}

      variants ->
        matches =
          Enum.filter(variants, fn variant ->
            condition_matches?(map_get(variant, :when, %{}), base_inputs)
          end)

        case matches do
          [variant] ->
            with {:ok, variant_inputs} <-
                   ActionInputCoercion.normalize_values(
                     list_value(variant, :inputs),
                     submitted_inputs,
                     [:intent, :inputs],
                     required?: true,
                     defaults?: true
                   ) do
              {:ok, variant, variant_inputs}
            end

          [] ->
            {:error,
             error(
               :no_matching_action_variant,
               [:intent, :inputs],
               "Action #{inspect(id(map_get(action, :id)))} did not match any input variant."
             )}

          variants ->
            {:error,
             error(
               :ambiguous_action_variant,
               [:intent, :inputs],
               "Action #{inspect(id(map_get(action, :id)))} matched multiple input variants.",
               variants: Enum.map(variants, &selected_id/1)
             )}
        end
    end
  end

  defp selected_execution(action, nil), do: execution_from(action, action)

  defp selected_execution(action, variant) do
    case map_get(variant, :execution) do
      %{} = execution -> {:ok, execution}
      _other -> execution_from(action, action)
    end
  end

  defp execution_from(source, action) do
    case map_get(source, :execution) do
      %{} = execution ->
        {:ok, execution}

      _ ->
        {:error,
         error(
           :missing_action_execution,
           [:actions, id(map_get(action, :id)), :execution],
           "Action #{inspect(id(map_get(action, :id)))} does not declare execution metadata."
         )}
    end
  end

  defp select_execution_case(execution, inputs) do
    case list_value(execution, :cases) do
      [] ->
        {:ok, nil, execution}

      cases ->
        matches =
          Enum.filter(cases, fn case_spec ->
            condition_matches?(map_get(case_spec, :when, %{}), inputs)
          end)

        case matches do
          [case_spec] ->
            {:ok, selected_id(case_spec), merge_execution_case(execution, case_spec)}

          [] ->
            {:error,
             error(
               :no_matching_action_execution_case,
               [:intent, :inputs],
               "Action execution did not match any execution case."
             )}

          cases ->
            {:error,
             error(
               :ambiguous_action_execution_case,
               [:intent, :inputs],
               "Action execution matched multiple execution cases.",
               cases: Enum.map(cases, &selected_id/1)
             )}
        end
    end
  end

  defp merge_execution_case(execution, case_spec) do
    execution
    |> Map.drop([:cases, "cases"])
    |> Map.merge(Map.drop(case_spec, [:raw, "raw", :when, "when", :match, "match"]))
  end

  defp condition_matches?(condition, _inputs) when condition in [nil, %{}, []], do: true

  defp condition_matches?(%{} = condition, inputs) do
    Enum.all?(condition, fn {field, expected} ->
      case fetch_value(inputs, id(field)) do
        {:ok, actual} -> values_match?(actual, expected)
        :error -> false
      end
    end)
  end

  defp condition_matches?(_condition, _inputs), do: false

  defp values_match?(actual, expected) when is_boolean(expected) do
    case ActionInputCoercion.boolean_value(actual) do
      {:ok, value} -> value == expected
      :error -> false
    end
  end

  defp values_match?(actual, expected), do: actual == expected or id(actual) == id(expected)

  defp supported_execution(%{} = execution, action) do
    case execution_kind(execution) do
      kind when kind in @supported_executors ->
        {:ok, execution}

      kind ->
        {:error,
         error(
           :unsupported_action_executor,
           [:actions, id(map_get(action, :id)), :execution, :kind],
           "Action #{inspect(id(map_get(action, :id)))} uses unsupported executor #{inspect(kind)}."
         )}
    end
  end

  defp execution_kind(execution), do: id(map_get(execution, :kind))

  defp event_stream_scope(action) do
    case id(map_get(action, :scope)) do
      "" -> "row"
      scope -> scope
    end
  end

  defp execution_operation(execution) do
    operation_id = id(map_get(execution, :operation))

    cond do
      operation_id in @supported_operations ->
        {:ok, operation_id}

      operation_id == "" ->
        {:error,
         error(
           :missing_action_operation,
           [:execution, :operation],
           "Updato action execution must name an operation."
         )}

      true ->
        {:error,
         error(
           :unsupported_action_operation,
           [:execution, :operation],
           "Updato action execution does not support operation #{inspect(operation_id)} yet."
         )}
    end
  end

  defp operation_spec(contract, operation_id) do
    contract
    |> list_value(:operations)
    |> Enum.find(&(id(map_get(&1, :id)) == operation_id))
    |> case do
      nil ->
        {:error,
         error(
           :unknown_operation,
           [:operations, operation_id],
           "Action execution references operation #{inspect(operation_id)}, but the domain contract does not expose it."
         )}

      %{enabled: false} ->
        {:error,
         error(
           :disabled_operation,
           [:operations, operation_id],
           "Action execution references disabled operation #{inspect(operation_id)}."
         )}

      %{"enabled" => false} ->
        {:error,
         error(
           :disabled_operation,
           [:operations, operation_id],
           "Action execution references disabled operation #{inspect(operation_id)}."
         )}

      operation ->
        {:ok, operation}
    end
  end

  defp execution_changes(execution, "delete", inputs, trusted_context) do
    changes = map_get(execution, :set, %{})

    if is_map(changes) do
      ActionTemplate.resolve(changes, inputs, trusted_context, [:execution, :set])
    else
      {:error,
       error(
         :invalid_action_changes,
         [:execution, :set],
         "Action execution set must be a map when present."
       )}
    end
  end

  defp execution_changes(%{document: document} = execution, "update", inputs, trusted_context)
       when is_map(document) do
    ActionTemplate.resolve(map_get(execution, :set, %{}), inputs, trusted_context, [
      :execution,
      :set
    ])
  end

  defp execution_changes(execution, _operation_id, inputs, trusted_context) do
    case map_get(execution, :set) do
      %{} = changes ->
        ActionTemplate.resolve(changes, inputs, trusted_context, [:execution, :set])

      nil ->
        {:error,
         error(
           :missing_action_changes,
           [:execution, :set],
           "Updato action execution must declare the field changes it will apply."
         )}

      _ ->
        {:error,
         error(
           :invalid_action_changes,
           [:execution, :set],
           "Action execution set must be a map."
         )}
    end
  end

  defp action_preconditions(contract, action, changes) do
    with {:ok, declared} <- declared_action_preconditions(action) do
      case map_get(action, :transition) do
        nil ->
          {:ok, declared}

        transition when transition == %{} ->
          {:ok, declared}

        %{} = transition ->
          with {:ok, transition} <- normalize_action_transition(transition),
               :ok <- validate_transition_change(transition, changes),
               :ok <- validate_transition_contract(contract, transition) do
            {:ok, declared ++ [transition_precondition(transition)]}
          end

        _transition ->
          {:error,
           error(
             :invalid_action_transition,
             [:actions, id(map_get(action, :id)), :transition],
             "Action transition must be a map."
           )}
      end
    end
  end

  defp declared_action_preconditions(action) do
    case ActionPreconditions.normalize(map_get(action, :preconditions)) do
      {:ok, preconditions} ->
        {:ok,
         Enum.map(preconditions, fn precondition ->
           precondition
           |> Map.put(:type, :filter)
           |> Map.put(:reason, :action_precondition)
         end)}

      {:error, reason} ->
        {:error,
         error(
           reason.code,
           [:actions, id(map_get(action, :id)), :preconditions] ++ reason.path,
           reason.message
         )}
    end
  end

  defp validate_precondition_fields(contract, preconditions) do
    columns = contract |> map_get(:source, %{}) |> map_get(:columns, %{})

    Enum.reduce_while(preconditions, :ok, fn
      %{type: :filter, field: field}, :ok ->
        if not String.contains?(field, ".") and has_key?(columns, field) do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            error(
              :action_precondition_field_not_found,
              [:preconditions, field],
              "Action precondition fields must name direct source columns."
            )}}
        end

      _transition, :ok ->
        {:cont, :ok}
    end)
  end

  defp validate_precondition_operation(operation, preconditions)
       when operation in ["update", "delete"] or preconditions == [],
       do: :ok

  defp validate_precondition_operation(operation, _preconditions) do
    {:error,
     error(
       :action_preconditions_unsupported_operation,
       [:execution, :operation],
       "Action precondition filters are supported only for update and delete operations.",
       operation: operation
     )}
  end

  defp normalize_action_transition(transition) do
    normalized = %{
      field: field_id_or_nil(map_get(transition, :field)),
      from: field_id_or_nil(map_get(transition, :from)),
      to: field_id_or_nil(map_get(transition, :to))
    }

    missing =
      normalized
      |> Enum.filter(fn {_key, value} -> is_nil(value) end)
      |> Enum.map(fn {key, _value} -> key end)

    if missing == [] do
      {:ok, normalized}
    else
      {:error,
       error(
         :invalid_action_transition,
         [:transition],
         "Action transition requires field, from, and to values.",
         missing: missing
       )}
    end
  end

  defp validate_transition_change(%{field: field, to: to}, changes) do
    case fetch_value(changes, field) do
      {:ok, value} ->
        if id(value) == to do
          :ok
        else
          {:error,
           error(
             :action_transition_change_mismatch,
             [:execution, :set, field],
             "Action transition target must match the planned field change.",
             field: field,
             expected: to,
             value: value
           )}
        end

      :error ->
        {:error,
         error(
           :action_transition_missing_change,
           [:execution, :set, field],
           "Action transition requires a planned change for its transition field.",
           field: field,
           expected: to
         )}
    end
  end

  defp validate_transition_contract(contract, %{field: field, from: from, to: to}) do
    case transition_entry(contract, field) do
      nil ->
        :ok

      transition_entry ->
        if transition_allows?(transition_entry, from, to) do
          :ok
        else
          {:error,
           error(
             :action_transition_not_allowed,
             [:transition],
             "Action transition is not allowed by writes.transitions.",
             field: field,
             from: from,
             to: to
           )}
        end
    end
  end

  defp transition_entry(contract, field) do
    contract
    |> list_value(:transitions)
    |> Enum.find(&(id(map_get(&1, :field)) == field))
  end

  defp transition_allows?(transition_entry, from, to) do
    transition_entry
    |> list_value(:transitions)
    |> Enum.any?(fn transition ->
      id(map_get(transition, :from)) == from and
        to in Enum.map(list_value(transition, :to), &id/1)
    end)
  end

  defp transition_precondition(%{field: field, from: from, to: to}) do
    %{
      type: :field_equals,
      field: field,
      value: from,
      reason: :transition_from,
      transition: %{field: field, from: from, to: to}
    }
  end

  defp action_filters(contract, intent) do
    with {:ok, explicit_filters} <- normalize_filters(map_get(intent, :filters, [])),
         {:ok, target_filters} <- target_filters(contract, map_get(intent, :target)) do
      {:ok, explicit_filters ++ target_filters}
    end
  end

  defp normalize_filters(nil), do: {:ok, []}

  defp normalize_filters(filters) when is_list(filters) do
    Enum.reduce_while(filters, {:ok, []}, fn filter, {:ok, acc} ->
      case normalize_filter(filter) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_filters(filter) do
    case normalize_filter(filter) do
      {:ok, normalized} -> {:ok, [normalized]}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_filter({field, value}), do: {:ok, {field_name(field), value}}

  defp normalize_filter({field, comparator, value}),
    do: {:ok, {field_name(field), comparator, value}}

  defp normalize_filter(%{} = filter) do
    field = map_get(filter, :field)

    comparator =
      map_get(filter, :comparator) || map_get(filter, :op) || map_get(filter, :operator) || "eq"

    cond do
      is_nil(field) ->
        {:error,
         error(
           :invalid_action_filter,
           [:intent, :filters],
           "Action filters must include a field."
         )}

      comparator in ["eq", "=", :eq] ->
        {:ok, {field_name(field), map_get(filter, :value)}}

      true ->
        {:ok, {field_name(field), comparator, map_get(filter, :value)}}
    end
  end

  defp normalize_filter(_filter) do
    {:error,
     error(
       :invalid_action_filter,
       [:intent, :filters],
       "Action filters must be maps or filter tuples."
     )}
  end

  defp target_filters(_contract, nil), do: {:ok, []}

  defp target_filters(contract, target) do
    primary_key = primary_key(contract)

    case target_ids(target) do
      {:ok, ids} ->
        with :ok <- validate_target_ids(ids),
             {:ok, ids} <- normalize_target_values(contract, primary_key, ids) do
          {:ok, [{primary_key, :in, ids}]}
        end

      :missing ->
        case target_value(target, primary_key) do
          {:ok, value} ->
            with {:ok, value} <- normalize_target_value(contract, primary_key, value) do
              {:ok, [{primary_key, value}]}
            end

          :missing ->
            {:error,
             error(
               :invalid_action_target,
               [:intent, :target],
               "Action target must include primary key #{inspect(primary_key)} or a non-empty ids list."
             )}
        end
    end
  end

  defp target_ids(%{} = target) do
    cond do
      Map.has_key?(target, "ids") -> {:ok, Map.fetch!(target, "ids")}
      Map.has_key?(target, :ids) -> {:ok, Map.fetch!(target, :ids)}
      true -> :missing
    end
  end

  defp target_ids(_target), do: :missing

  defp validate_target_ids(ids) when not is_list(ids) or ids == [] do
    {:error,
     error(
       :invalid_action_target,
       [:intent, :target, :ids],
       "Bulk action target ids must be a non-empty list."
     )}
  end

  defp validate_target_ids(ids) do
    if length(Enum.uniq(ids)) == length(ids) do
      :ok
    else
      {:error,
       error(
         :invalid_action_target,
         [:intent, :target, :ids],
         "Bulk action target ids must not contain duplicates."
       )}
    end
  end

  defp normalize_target_values(contract, primary_key, values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case normalize_target_value(contract, primary_key, value) do
        {:ok, value} -> {:cont, {:ok, normalized ++ [value]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_target_value(contract, primary_key, value) do
    field_spec = contract_entry(contract, :fields, primary_key)
    columns = contract |> map_get(:source, %{}) |> map_get(:columns, %{})

    source_field_spec =
      Map.get(columns, primary_key) ||
        if(atom_key = existing_atom(primary_key), do: Map.get(columns, atom_key), else: nil)

    field_type = id(map_get(field_spec, :type) || map_get(source_field_spec, :type))

    case {field_type, value} do
      {"object_id", value} ->
        if Selecto.Document.ObjectId.valid?(value),
          do: {:ok, value},
          else: invalid_target_value(primary_key, value, field_type)

      {"integer", integer} when is_integer(integer) ->
        {:ok, integer}

      {"integer", string} when is_binary(string) ->
        case Integer.parse(string) do
          {integer, ""} -> {:ok, integer}
          _other -> invalid_target_value(primary_key, value, field_type)
        end

      {_type, value} ->
        {:ok, value}
    end
  end

  defp invalid_target_value(primary_key, value, field_type) do
    {:error,
     error(
       :invalid_action_target,
       [:intent, :target],
       "Action target #{inspect(primary_key)} must be a valid #{field_type} value.",
       value: value,
       type: field_type
     )}
  end

  defp target_value(%{} = target, primary_key) do
    cond do
      Map.has_key?(target, primary_key) ->
        {:ok, Map.fetch!(target, primary_key)}

      not is_nil(existing_atom(primary_key)) and Map.has_key?(target, existing_atom(primary_key)) ->
        {:ok, Map.fetch!(target, existing_atom(primary_key))}

      primary_key != "id" and Map.has_key?(target, "id") ->
        {:ok, Map.fetch!(target, "id")}

      primary_key != "id" and Map.has_key?(target, :id) ->
        {:ok, Map.fetch!(target, :id)}

      true ->
        :missing
    end
  end

  defp target_value(value, _primary_key), do: {:ok, value}

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp precondition_filters(preconditions) do
    Enum.flat_map(preconditions, fn
      %{type: :filter, field: field, comparator: :eq, value: value} ->
        [{field_name(field), value}]

      %{type: :filter, field: field, comparator: comparator, value: value} ->
        [{field_name(field), comparator, value}]

      %{type: :field_equals, field: field, value: value} ->
        [{field_name(field), value}]

      %{"type" => "field_equals", "field" => field, "value" => value} ->
        [{field_name(field), value}]

      _precondition ->
        []
    end)
  end

  defp target_cardinality(contract, intent) do
    target = map_get(intent, :target)

    case target_ids(target) do
      {:ok, ids} when is_list(ids) and ids != [] ->
        {:exactly, length(ids)}

      :missing ->
        case target_value(target, primary_key(contract)) do
          {:ok, _value} -> {:exactly, 1}
          :missing -> nil
        end

      _other ->
        nil
    end
  end

  defp validate_target_cardinality(action, intent) do
    selection = map_get(action, :selection, %{})
    minimum = map_get(selection, :min_rows, 1)
    maximum = map_get(selection, :max_rows)

    case target_ids(map_get(intent, :target)) do
      {:ok, ids} when is_list(ids) ->
        count = length(ids)

        cond do
          is_integer(minimum) and count < minimum ->
            {:error,
             error(
               :action_cardinality_mismatch,
               [:intent, :target, :ids],
               "Action target does not meet the minimum row count.",
               minimum: minimum,
               actual: count
             )}

          is_integer(maximum) and count > maximum ->
            {:error,
             error(
               :action_cardinality_mismatch,
               [:intent, :target, :ids],
               "Action target exceeds the maximum row count.",
               maximum: maximum,
               actual: count
             )}

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp primary_key(contract) do
    contract
    |> map_get(:source, %{})
    |> map_get(:primary_key, "id")
    |> field_name()
  end

  defp enforce_required_filter(operation_spec, filters) do
    if truthy?(map_get(operation_spec, :require_filter)) and filters == [] do
      {:error,
       error(
         :missing_required_filter,
         [:intent, :filters],
         "This action requires a target or filter scope before it can be planned."
       )}
    else
      :ok
    end
  end

  defp action_scope(contract, action, operation_id, operation_spec, intent, filters) do
    declared_scope = declared_action_scope(action)
    planned_scope = planned_action_scope(contract, intent, filters)

    cond do
      declared_scope == "row" and planned_scope != "row" and
          not (planned_scope == "bulk" and bulk_action_enabled?(action)) ->
        {:error,
         error(
           :action_scope_mismatch,
           [:intent, :filters],
           "This action is row-scoped and requires a concrete target or primary-key filter scope.",
           declared_scope: declared_scope,
           planned_scope: planned_scope
         )}

      planned_scope == "bulk" and not truthy?(map_get(operation_spec, :bulk)) ->
        {:error,
         error(
           :bulk_action_operation_not_enabled,
           [:operations, operation_id, :bulk],
           "Bulk action planning requires the referenced write operation to declare bulk: true.",
           operation: operation_id
         )}

      true ->
        {:ok, planned_scope}
    end
  end

  defp declared_action_scope(action) do
    case id(map_get(action, :scope)) do
      scope when scope in ["row", "bulk", "global", "scheduled", "view"] ->
        scope

      _ ->
        case id(map_get(action, :type)) do
          type when type in ["detail_action", "row_action", "transition"] -> "row"
          "bulk_action" -> "bulk"
          _type -> nil
        end
    end
  end

  defp bulk_action_enabled?(action) do
    bulk = map_get(action, :bulk) || action |> map_get(:raw, %{}) |> map_get(:bulk)

    case bulk do
      bulk when is_map(bulk) -> truthy?(map_get(bulk, :enabled))
      value -> truthy?(value)
    end
  end

  defp planned_action_scope(contract, intent, filters) do
    cond do
      match?({:ok, _ids}, target_ids(map_get(intent, :target))) ->
        "bulk"

      not is_nil(map_get(intent, :target)) ->
        "row"

      primary_key_filter?(filters, primary_key(contract)) ->
        "row"

      filters == [] ->
        "global"

      true ->
        "bulk"
    end
  end

  defp primary_key_filter?(filters, primary_key) do
    Enum.any?(filters, fn
      {field, _value} ->
        field_name(field) == primary_key

      {field, comparator, _value} ->
        field_name(field) == primary_key and comparator in ["eq", "=", :eq]

      _filter ->
        false
    end)
  end

  defp action_returning(execution, operation_spec) do
    case map_get(execution, :returning) do
      nil -> map_get(operation_spec, :returning)
      returning -> returning
    end
  end

  defp operation_intent(
         action,
         intent,
         operation_id,
         scope,
         changes,
         filters,
         returning,
         runtime,
         preconditions,
         collection_operations
       ) do
    %{
      action: id(map_get(action, :id)),
      operation: operation_id,
      scope: scope,
      filters: Enum.map(filters, &filter_intent/1)
    }
    |> maybe_put(:inputs, Map.get(runtime, :inputs))
    |> maybe_put(:variant, Map.get(runtime, :variant))
    |> maybe_put(:execution_case, Map.get(runtime, :execution_case))
    |> maybe_put(:preconditions, preconditions)
    |> maybe_put(:collection_patches, Map.get(runtime, :collection_patches))
    |> maybe_put(:collection_operations, collection_operations)
    |> maybe_put(:target, map_get(intent, :target))
    |> maybe_put(:conflict_target, map_get(Map.fetch!(runtime, :execution), :conflict_target))
    |> put_changes(operation_id, changes)
    |> maybe_put(:returning, returning)
  end

  defp put_changes(intent, operation_id, changes) when operation_id in ["insert", "upsert"] do
    Map.put(intent, :attrs, changes)
  end

  defp put_changes(intent, "update", changes) do
    Map.put(intent, :changes, changes)
  end

  defp put_changes(intent, _operation_id, _changes), do: intent

  defp filter_intent({field, value}) do
    %{field: field_name(field), comparator: "eq", value: value}
  end

  defp filter_intent({field, comparator, value}) do
    %{field: field_name(field), comparator: comparator, value: value}
  end

  defp filter_intent(filter), do: filter

  defp validate_operation_intent(contract, operation_intent, opts) do
    case DomainContract.validate_intent(contract, operation_intent, opts) do
      %{valid?: true} ->
        :ok

      validation ->
        {:error,
         validation_error(
           :invalid_action_operation_intent,
           [:operation_intent],
           "The action produces an operation intent that is not valid for this domain.",
           validation
         )}
    end
  end

  defp operation_builder(
         input,
         action,
         operation_id,
         changes,
         filters,
         returning,
         expected_cardinality,
         execution
       ) do
    case operation_domain(input) do
      :contract_only ->
        {:ok, nil}

      {:ok, domain} ->
        base_operation =
          domain
          |> SelectoUpdato.new()
          |> apply_filters(filters)
          |> enforce_input_query(input)

        with {:ok, operation} <- apply_operation(base_operation, operation_id, changes),
             {:ok, operation} <-
               operation
               |> maybe_conflict_target(map_get(execution, :conflict_target))
               |> SelectoUpdato.Upsert.apply_domain_conflict_policy() do
          {:ok,
           operation
           |> maybe_returning(returning)
           |> maybe_expected_cardinality(expected_cardinality)
           |> Operation.put_action_policy(%{
             action: id(map_get(action, :id)),
             capability: map_get(action, :capability),
             operation: operation.type,
             returning: returning_value(returning),
             expected_cardinality: expected_cardinality
           })}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # A scoped Selecto is host-owned eligibility evidence, just as it is for
  # enforce_query/2 on ordinary writes. Capture it before the plan is sealed
  # so the single-use action grant binds the same predicate that executes.
  defp enforce_input_query(operation, %Selecto{} = input) do
    if Selecto.query_filters(input) == [],
      do: operation,
      else: SelectoUpdato.enforce_query(operation, input)
  end

  defp enforce_input_query(operation, _input), do: operation

  defp maybe_conflict_target(%Operation{type: :upsert} = operation, target) when is_list(target),
    do: SelectoUpdato.conflict_target(operation, target)

  defp maybe_conflict_target(operation, _target), do: operation

  defp operation_domain(input) do
    cond do
      contract_document?(input) ->
        :contract_only

      is_struct(input, Selecto) ->
        normalize_operation_domain(input.domain)

      is_map(input) ->
        normalize_operation_domain(input)

      true ->
        :contract_only
    end
  end

  defp normalize_operation_domain(domain) do
    case Domain.normalize(domain) do
      {:ok, normalized, _diagnostics} ->
        {:ok, normalized}

      {:error, reason} ->
        {:error,
         error(
           :invalid_action_domain,
           [:domain],
           "Action planning could not normalize the source domain.",
           reason: reason
         )}
    end
  end

  defp apply_filters(operation, filters) do
    Enum.reduce(filters, operation, fn filter, acc -> SelectoUpdato.filter(acc, filter) end)
  end

  defp apply_operation(operation, "insert", changes),
    do: {:ok, SelectoUpdato.insert(operation, changes)}

  defp apply_operation(operation, "update", changes),
    do: {:ok, SelectoUpdato.update(operation, changes)}

  defp apply_operation(operation, "upsert", changes),
    do: {:ok, SelectoUpdato.upsert(operation, changes)}

  defp apply_operation(operation, "delete", _changes), do: {:ok, SelectoUpdato.delete(operation)}

  defp apply_operation(_operation, operation_id, _changes) do
    {:error,
     error(
       :unsupported_action_operation,
       [:execution, :operation],
       "Updato action execution does not support operation #{inspect(operation_id)} yet."
     )}
  end

  defp maybe_returning(operation, nil), do: operation
  defp maybe_returning(operation, []), do: SelectoUpdato.returning(operation, [])

  defp maybe_returning(operation, returning),
    do: SelectoUpdato.returning(operation, returning_value(returning))

  defp maybe_expected_cardinality(operation, nil), do: operation

  defp maybe_expected_cardinality(operation, expected),
    do: SelectoUpdato.expected_cardinality(operation, expected)

  # Domain actions describe their API result shape as record(s) or count. The
  # portable command is lower-level and accepts only SQL-style returning values.
  defp returning_value(value) when value in ["record", :record, "records", :records], do: :all

  defp returning_value(value) when value in [false, :minimal, "minimal", "count", :count],
    do: :none

  defp returning_value(value) when value in [true, "all"], do: :all
  defp returning_value(value) when value in ["none", :none, nil], do: :none
  defp returning_value(value), do: value

  defp contract_document?(%{} = input) do
    map_get(input, :projection) in ["updato_write_contract", :updato_write_contract]
  end

  defp contract_document?(_input), do: false

  defp diagnostics_summary(%{errors: errors, warnings: warnings}) do
    %{errors: errors, warnings: warnings}
  end

  defp selected_id(nil), do: nil

  defp selected_id(spec) do
    case map_get(spec, :id) do
      nil -> nil
      "" -> nil
      value -> id(value)
    end
  end

  defp trusted_context(opts) do
    case Keyword.get(opts, :trusted_context, %{}) do
      %{} = context ->
        context

      context when is_list(context) ->
        if Keyword.keyword?(context) do
          context
          |> Enum.map(fn {key, value} -> {id(key), value} end)
          |> Map.new()
        else
          %{}
        end

      _context ->
        %{}
    end
  end

  defp validation_error(code, path, message, validation) do
    error(code, path, message, validation: validation)
  end
end
