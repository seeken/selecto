defmodule Selecto.Verification.BoundedTraceModel do
  @moduledoc """
  Deterministic bounded checking over a finite event-transition system.

  `check/5` explores reachable states breadth-first, applies events in their
  declared order, and checks every invariant when a state is first reached.
  Equivalent states are reduced with a caller-supplied `:state_key` function;
  the default key is the complete state.

  The exploration is exhaustive only within the declared initial states,
  events, state equivalence, and `:max_depth`. History needed by an invariant
  must therefore be represented in the state (and its state key).

  Event callbacks return one of:

  - `:disabled` when the event cannot occur in the current state;
  - `{:next, next_state}` for an enabled transition;
  - `{:next, next_state, event_data}` to record portable explanatory data;
  - `{:error, reason}` to report a transition-system counterexample.

  Invariants use the same return contract as
  `Selecto.Verification.BoundedModel`: `:ok` or `true` succeeds;
  `{:error, reason}`, `false`, exceptions, and throws are counterexamples.
  """

  alias Selecto.Verification.PortableTerm

  @type event_name :: String.t() | atom()
  @type event_result ::
          :disabled
          | {:next, term()}
          | {:next, term(), term()}
          | {:error, term()}
  @type event :: {event_name(), (term() -> event_result())}
  @type invariant ::
          {String.t() | atom(), (term() -> :ok | true | {:error, term()} | false)}

  @type report :: %{
          optional(:trace_coverage) => [[String.t()]],
          format: String.t(),
          format_version: pos_integer(),
          proof_level: :bounded_exhaustive,
          model: String.t(),
          state_count: non_neg_integer(),
          invariant_count: non_neg_integer(),
          check_count: non_neg_integer(),
          proved?: boolean(),
          counterexamples: [map()],
          initial_state_count: non_neg_integer(),
          event_count: non_neg_integer(),
          transition_count: non_neg_integer(),
          revisited_state_count: non_neg_integer(),
          disabled_event_count: non_neg_integer(),
          max_depth: non_neg_integer(),
          reached_depth: non_neg_integer()
        }

  @doc """
  Checks all reachable states in a finite event model up to `:max_depth`.

  Options:

  - `:max_depth` - required non-negative maximum number of events in a trace;
  - `:state_key` - optional one-arity state-equivalence function. It defaults
    to the complete state;
  - `:trace_state` - optional one-arity function that selects the state snapshot
    stored after each event. It defaults to the complete state and does not
    affect state equivalence or invariant checking.
  - `:include_trace_coverage` - when `true`, includes the distinct successful
    event-name sequences encountered while expanding unique states, including
    transitions that revisit an equivalent state. It defaults to `false`.
  """
  @spec check(String.t() | atom(), Enumerable.t(), [event()], [invariant()], keyword()) ::
          report()
  def check(model, initial_states, events, invariants, opts)
      when is_list(events) and is_list(invariants) and is_list(opts) do
    max_depth = max_depth!(opts)
    state_key = state_key!(opts)
    trace_state = trace_state!(opts)
    include_trace_coverage = include_trace_coverage!(opts)
    validate_callbacks!(events, invariants)

    context = %{
      events: events,
      invariants: invariants,
      max_depth: max_depth,
      state_key: state_key,
      trace_state: trace_state,
      include_trace_coverage: include_trace_coverage,
      trace_coverage: [],
      trace_coverage_set: MapSet.new(),
      queue: :queue.new(),
      visited: MapSet.new(),
      states: [],
      invariant_counterexamples: [],
      transition_counterexamples: [],
      transition_count: 0,
      revisited_state_count: 0,
      disabled_event_count: 0,
      reached_depth: 0
    }

    context =
      initial_states
      |> Enum.to_list()
      |> Enum.reduce(context, &enqueue_initial_state/2)
      |> explore()

    states = Enum.reverse(context.states)
    invariant_counterexamples = Enum.reverse(context.invariant_counterexamples)
    transition_counterexamples = Enum.reverse(context.transition_counterexamples)
    counterexamples = invariant_counterexamples ++ transition_counterexamples

    report = %{
      format: "selecto.formal_verification",
      format_version: 1,
      proof_level: :bounded_exhaustive,
      model: to_string(model),
      state_count: length(states),
      invariant_count: length(invariants),
      check_count: length(states) * length(invariants),
      proved?: counterexamples == [],
      counterexamples: counterexamples,
      initial_state_count: Enum.count(states, &(&1.depth == 0)),
      event_count: length(events),
      transition_count: context.transition_count,
      revisited_state_count: context.revisited_state_count,
      disabled_event_count: context.disabled_event_count,
      max_depth: max_depth,
      reached_depth: context.reached_depth
    }

    if include_trace_coverage do
      Map.put(report, :trace_coverage, Enum.reverse(context.trace_coverage))
    else
      report
    end
  end

  def check(_model, _initial_states, _events, _invariants, _opts) do
    raise ArgumentError, "events, invariants, and options must be lists"
  end

  defp enqueue_initial_state(state, context) do
    key = context.state_key.(state)
    context = record_trace_coverage(context, [])

    if MapSet.member?(context.visited, key) do
      %{context | revisited_state_count: context.revisited_state_count + 1}
    else
      node = node(state, 0, [])

      context
      |> put_in([:visited], MapSet.put(context.visited, key))
      |> put_in([:queue], :queue.in(node, context.queue))
      |> record_state(node)
    end
  end

  defp explore(context) do
    case :queue.out(context.queue) do
      {:empty, _queue} ->
        context

      {{:value, node}, queue} ->
        context = %{context | queue: queue}

        context =
          if node.depth < context.max_depth do
            explore_events(node, context)
          else
            context
          end

        explore(context)
    end
  end

  defp explore_events(node, context) do
    context.events
    |> Enum.with_index()
    |> Enum.reduce(context, fn {{event_name, event}, event_index}, acc ->
      apply_event(node, event_name, event, event_index, acc)
    end)
  end

  defp apply_event(node, event_name, event, event_index, context) do
    case invoke(event, node.state) do
      :disabled ->
        %{context | disabled_event_count: context.disabled_event_count + 1}

      {:next, next_state} ->
        transition(node, event_name, event_index, next_state, nil, context)

      {:next, next_state, event_data} ->
        transition(node, event_name, event_index, next_state, event_data, context)

      {:error, reason} ->
        record_transition_counterexample(
          node,
          event_name,
          event_index,
          reason,
          context
        )

      {:exception, _module, _message} = reason ->
        record_transition_counterexample(node, event_name, event_index, reason, context)

      {:caught, _kind, _value} = reason ->
        record_transition_counterexample(node, event_name, event_index, reason, context)

      other ->
        record_transition_counterexample(
          node,
          event_name,
          event_index,
          {:invalid_event_result, other},
          context
        )
    end
  end

  defp transition(node, event_name, event_index, next_state, event_data, context) do
    trace_entry =
      trace_entry(
        event_name,
        event_index,
        context.trace_state.(next_state),
        event_data
      )

    next_node = node(next_state, node.depth + 1, node.trace ++ [trace_entry])
    key = context.state_key.(next_state)

    context =
      context
      |> Map.update!(:transition_count, &(&1 + 1))
      |> record_trace_coverage(next_node.trace)

    if MapSet.member?(context.visited, key) do
      %{context | revisited_state_count: context.revisited_state_count + 1}
    else
      context
      |> put_in([:visited], MapSet.put(context.visited, key))
      |> put_in([:queue], :queue.in(next_node, context.queue))
      |> record_state(next_node)
    end
  end

  defp record_state(context, node) do
    counterexamples = check_invariants(node, length(context.states), context.invariants)

    %{
      context
      | states: [node | context.states],
        invariant_counterexamples:
          Enum.reverse(counterexamples, context.invariant_counterexamples),
        reached_depth: max(context.reached_depth, node.depth)
    }
  end

  defp record_trace_coverage(%{include_trace_coverage: false} = context, _trace), do: context

  defp record_trace_coverage(context, trace) do
    signature = Enum.map(trace, & &1.event)

    if MapSet.member?(context.trace_coverage_set, signature) do
      context
    else
      %{
        context
        | trace_coverage: [signature | context.trace_coverage],
          trace_coverage_set: MapSet.put(context.trace_coverage_set, signature)
      }
    end
  end

  defp check_invariants(node, state_index, invariants) do
    invariants
    |> Enum.with_index()
    |> Enum.flat_map(fn {{name, invariant}, invariant_index} ->
      case invoke(invariant, node.state) do
        :ok ->
          []

        true ->
          []

        {:error, reason} ->
          [invariant_counterexample(node, state_index, name, invariant_index, reason)]

        {:exception, _module, _message} = reason ->
          [invariant_counterexample(node, state_index, name, invariant_index, reason)]

        {:caught, _kind, _value} = reason ->
          [invariant_counterexample(node, state_index, name, invariant_index, reason)]

        false ->
          [invariant_counterexample(node, state_index, name, invariant_index, :returned_false)]

        other ->
          [
            invariant_counterexample(
              node,
              state_index,
              name,
              invariant_index,
              {:invalid_invariant_result, other}
            )
          ]
      end
    end)
  end

  defp invariant_counterexample(node, state_index, name, invariant_index, reason) do
    %{
      type: :invariant,
      invariant: to_string(name),
      invariant_index: invariant_index,
      state_index: state_index,
      depth: node.depth,
      state: PortableTerm.encode(node.state),
      trace: node.trace,
      reason: PortableTerm.encode(reason)
    }
  end

  defp record_transition_counterexample(node, event_name, event_index, reason, context) do
    attempted_event = %{
      event: to_string(event_name),
      event_index: event_index,
      outcome: :error,
      reason: PortableTerm.encode(reason)
    }

    counterexample = %{
      type: :transition,
      event: to_string(event_name),
      event_index: event_index,
      state_index: state_index(context, node),
      depth: node.depth,
      state: PortableTerm.encode(node.state),
      trace: node.trace ++ [attempted_event],
      reason: PortableTerm.encode(reason)
    }

    %{
      context
      | transition_counterexamples: [counterexample | context.transition_counterexamples]
    }
  end

  defp state_index(context, node) do
    context.states
    |> Enum.reverse()
    |> Enum.find_index(&(&1 === node))
  end

  defp node(state, depth, trace), do: %{state: state, depth: depth, trace: trace}

  defp trace_entry(event_name, event_index, next_state, event_data) do
    entry = %{
      event: to_string(event_name),
      event_index: event_index,
      state: PortableTerm.encode(next_state)
    }

    if is_nil(event_data),
      do: entry,
      else: Map.put(entry, :data, PortableTerm.encode(event_data))
  end

  defp invoke(callback, state) do
    callback.(state)
  rescue
    exception -> {:exception, exception.__struct__, Exception.message(exception)}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp max_depth!(opts) do
    case Keyword.fetch(opts, :max_depth) do
      {:ok, max_depth} when is_integer(max_depth) and max_depth >= 0 ->
        max_depth

      {:ok, other} ->
        raise ArgumentError, ":max_depth must be a non-negative integer, got: #{inspect(other)}"

      :error ->
        raise ArgumentError, "missing required :max_depth option"
    end
  end

  defp state_key!(opts) do
    case Keyword.get(opts, :state_key, &Function.identity/1) do
      state_key when is_function(state_key, 1) ->
        state_key

      other ->
        raise ArgumentError, ":state_key must be a one-arity function, got: #{inspect(other)}"
    end
  end

  defp trace_state!(opts) do
    case Keyword.get(opts, :trace_state, &Function.identity/1) do
      trace_state when is_function(trace_state, 1) ->
        trace_state

      other ->
        raise ArgumentError, ":trace_state must be a one-arity function, got: #{inspect(other)}"
    end
  end

  defp include_trace_coverage!(opts) do
    case Keyword.get(opts, :include_trace_coverage, false) do
      value when is_boolean(value) ->
        value

      other ->
        raise ArgumentError,
              ":include_trace_coverage must be a boolean, got: #{inspect(other)}"
    end
  end

  defp validate_callbacks!(events, invariants) do
    unless Enum.all?(events, &valid_callback_entry?/1) do
      raise ArgumentError, "events must be {name, one-arity function} pairs"
    end

    unless Enum.all?(invariants, &valid_callback_entry?/1) do
      raise ArgumentError, "invariants must be {name, one-arity function} pairs"
    end
  end

  defp valid_callback_entry?({name, callback})
       when (is_atom(name) or is_binary(name)) and is_function(callback, 1),
       do: true

  defp valid_callback_entry?(_entry), do: false
end
