defmodule Selecto.Rule.Pattern do
  @moduledoc false

  alias Selecto.Rule.Budget

  defmodule Invalid do
    @moduledoc false
    defexception message: "invalid portable ASCII pattern"
  end

  @states 512
  @escaped ~c"\\.[]{}()|?*+-^$"
  defstruct [:states, :start, :finish]

  def compile(source) when is_binary(source) and byte_size(source) in 1..256 do
    try do
      if not Enum.all?(:binary.bin_to_list(source), &(&1 < 128)), do: invalid()
      {ast, []} = alternate(:binary.bin_to_list(source), 0)
      {{start, finish}, {states, _count}} = build(ast, {%{}, 0})
      {:ok, %__MODULE__{states: states, start: start, finish: finish}}
    rescue
      Budget.Limit -> {:error, :evaluation_limit}
      _error in [Invalid, MatchError] -> {:error, :invalid_text_pattern}
    end
  end

  def compile(_source), do: {:error, :invalid_text_pattern}

  def matches?(pattern, text, mode, budget) when mode in ["full", "search"] do
    Budget.pattern_text(text, budget)
    Budget.spend(budget, map_size(pattern.states))
    current = closure(pattern, MapSet.new([pattern.start]), budget)
    search? = mode == "search"

    if search? and MapSet.member?(current, pattern.finish) do
      true
    else
      advance(pattern, String.to_charlist(text), current, search?, budget)
    end
  end

  defp advance(pattern, [], current, _search?, _budget),
    do: MapSet.member?(current, pattern.finish)

  defp advance(pattern, [scalar | tail], current, search?, budget) do
    Budget.spend(budget)

    current =
      if search?,
        do: closure(pattern, MapSet.put(current, pattern.start), budget),
        else: current

    next =
      Enum.reduce(current, MapSet.new(), fn index, next ->
        {predicate, edges} = Map.fetch!(pattern.states, index)
        Budget.spend(budget)

        if predicate != nil and accepts?(predicate, scalar, budget),
          do: Enum.reduce(edges, next, &MapSet.put(&2, &1)),
          else: next
      end)
      |> then(&closure(pattern, &1, budget))

    if search? and MapSet.member?(next, pattern.finish),
      do: true,
      else: advance(pattern, tail, next, search?, budget)
  end

  defp closure(pattern, input, budget),
    do: closure(pattern, MapSet.to_list(input), input, budget)

  defp closure(_pattern, [], visited, _budget), do: visited

  defp closure(pattern, [index | tail], visited, budget) do
    Budget.spend(budget)
    {predicate, edges} = Map.fetch!(pattern.states, index)

    {pending, visited} =
      if predicate == nil do
        Enum.reduce(edges, {tail, visited}, fn target, {pending, visited} ->
          if MapSet.member?(visited, target),
            do: {pending, visited},
            else: {[target | pending], MapSet.put(visited, target)}
        end)
      else
        {tail, visited}
      end

    closure(pattern, pending, visited, budget)
  end

  defp accepts?({:literal, expected}, scalar, budget) do
    Budget.spend(budget)
    scalar == expected
  end

  defp accepts?(:dot, scalar, budget) do
    Budget.spend(budget)
    scalar != ?\n
  end

  defp accepts?({:class, negate?, parts}, scalar, budget) do
    # Charge every class part before matching, including an early successful
    # member. Cost cannot depend on a short-circuit that skips the work meter.
    Budget.spend(budget, length(parts))
    negate? != Enum.any?(parts, &class_member?(&1, scalar))
  end

  defp class_member?({:range, left, right}, scalar), do: scalar in left..right
  defp class_member?({:literal, value}, scalar), do: scalar == value
  defp class_member?({:set, kind, negate?}, scalar), do: negate? != set_member?(kind, scalar)
  defp set_member?(:digit, scalar), do: scalar in ?0..?9

  defp set_member?(:word, scalar),
    do: scalar in ?a..?z or scalar in ?A..?Z or scalar in ?0..?9 or scalar == ?_

  defp set_member?(:space, scalar), do: scalar == ?\s or scalar in ?\t..?\r

  defp alternate(bytes, depth) do
    if depth > 16, do: Budget.refuse()
    {first, rest} = sequence(bytes, depth, [])
    choices(rest, depth, [first])
  end

  defp choices([?| | tail], depth, choices) do
    {child, rest} = sequence(tail, depth, [])
    choices(rest, depth, [child | choices])
  end

  defp choices(rest, _depth, [single]), do: {single, rest}
  defp choices(rest, _depth, choices), do: {{:alternate, Enum.reverse(choices)}, rest}

  defp sequence([head | _] = rest, _depth, nodes) when head in [?), ?|],
    do: {{:sequence, Enum.reverse(nodes)}, rest}

  defp sequence([], _depth, nodes), do: {{:sequence, Enum.reverse(nodes)}, []}

  defp sequence(bytes, depth, nodes) do
    {node, rest} = atom(bytes, depth)
    {node, rest} = repeat(node, rest)
    sequence(rest, depth, [node | nodes])
  end

  defp atom([?( | rest], depth) do
    {node, tail} = alternate(rest, depth + 1)

    case tail do
      [?) | rest] -> {node, rest}
      _ -> invalid()
    end
  end

  defp atom([?[ | rest], _depth) do
    {negate?, rest} = if match?([?^ | _], rest), do: {true, tl(rest)}, else: {false, rest}
    {parts, rest} = character_class(rest, [], true)
    {{:char, {:class, negate?, parts}}, rest}
  end

  defp atom([?\\ | rest], _depth) do
    {predicate, rest} = escape(rest)
    {{:char, {:class, false, [predicate]}}, rest}
  end

  defp atom([?. | rest], _depth), do: {{:char, :dot}, rest}

  defp atom([literal | rest], _depth) do
    if literal in ~c"^$?*+{}])", do: invalid()
    {{:char, {:literal, literal}}, rest}
  end

  defp atom([], _depth), do: invalid()

  defp repeat(node, [quantifier | rest]) when quantifier in [?*, ?+, ??],
    do:
      {{:repeat, node, if(quantifier == ?+, do: 1, else: 0),
        if(quantifier == ??, do: 1, else: :infinity)}, rest}

  defp repeat(node, [?{ | rest]) do
    {minimum, rest} = integer(rest, 0, false)

    {maximum, rest} =
      case rest do
        [?,, ?} | _] -> {:infinity, tl(rest)}
        [?, | rest] -> integer(rest, 0, false)
        _ -> {minimum, rest}
      end

    case rest do
      [?} | rest] ->
        if maximum != :infinity and maximum < minimum, do: invalid()
        {{:repeat, node, minimum, maximum}, rest}

      _ ->
        invalid()
    end
  end

  defp repeat(node, rest), do: {node, rest}

  defp integer([digit | tail], current, _seen?) when digit in ?0..?9 do
    current = current * 10 + digit - ?0
    if current > @states, do: Budget.refuse()
    integer(tail, current, true)
  end

  defp integer(rest, current, true), do: {current, rest}
  defp integer(_rest, _current, false), do: invalid()

  defp character_class([?] | tail], parts, false) when parts != [],
    do: {Enum.reverse(parts), tail}

  defp character_class(bytes, parts, _first?) do
    if bytes == [] or match?([?&, ?& | _], bytes), do: invalid()
    {part, rest} = class_part(bytes)

    {part, rest} =
      case {part, rest} do
        {{:literal, left}, [?-, right | tail]} when right != ?] ->
          {last, tail} = class_part([right | tail])

          case last do
            {:literal, right} when right >= left -> {{:range, left, right}, tail}
            _ -> invalid()
          end

        {{:set, _kind, _negate?}, [?-, right | _]} when right != ?] ->
          invalid()

        _ ->
          {part, rest}
      end

    character_class(rest, [part | parts], false)
  end

  defp class_part([?[, ?: | _]), do: invalid()
  defp class_part([?\\ | rest]), do: escape(rest)
  defp class_part([literal | rest]), do: {{:literal, literal}, rest}
  defp class_part([]), do: invalid()

  defp escape([escaped | rest]) when escaped in @escaped, do: {{:literal, escaped}, rest}
  defp escape([?t | rest]), do: {{:literal, ?\t}, rest}
  defp escape([?r | rest]), do: {{:literal, ?\r}, rest}
  defp escape([?n | rest]), do: {{:literal, ?\n}, rest}

  defp escape([escaped | rest]) when escaped in ~c"dDsSwW" do
    kind =
      cond do
        escaped in ~c"dD" -> :digit
        escaped in ~c"sS" -> :space
        true -> :word
      end

    {{:set, kind, escaped in ~c"DSW"}, rest}
  end

  defp escape(_rest), do: invalid()

  defp build({:char, predicate}, state) do
    {start, state} = add_state(predicate, state)
    {finish, state} = add_state(nil, state)
    {{start, finish}, edge(state, start, finish)}
  end

  defp build({:sequence, nodes}, state), do: build_sequence(nodes, empty(state))

  defp build({:alternate, nodes}, state) do
    {{start, finish}, state} = empty(state, false)

    state =
      Enum.reduce(nodes, state, fn node, state ->
        {{left, right}, state} = build(node, state)
        state |> edge(start, left) |> edge(right, finish)
      end)

    {{start, finish}, state}
  end

  defp build({:repeat, node, minimum, maximum}, state) do
    {fragment, state} = repeat_required(node, minimum, empty(state))

    if maximum == :infinity do
      {child, state} = build(node, state)
      {{left, right}, state} = optional(child, state)
      state = edge(state, elem(child, 1), elem(child, 0))
      concatenate(fragment, {left, right}, state)
    else
      repeat_optional(node, maximum - minimum, {fragment, state})
    end
  end

  defp repeat_required(_node, 0, result), do: result

  defp repeat_required(node, count, {fragment, state}) do
    {child, state} = build(node, state)
    repeat_required(node, count - 1, concatenate(fragment, child, state))
  end

  defp repeat_optional(_node, 0, result), do: result

  defp repeat_optional(node, count, {fragment, state}) do
    {child, state} = build(node, state)
    {child, state} = optional(child, state)
    repeat_optional(node, count - 1, concatenate(fragment, child, state))
  end

  defp build_sequence([], result), do: result

  defp build_sequence([node | rest], {fragment, state}) do
    {child, state} = build(node, state)
    build_sequence(rest, concatenate(fragment, child, state))
  end

  defp empty(state, join? \\ true) do
    {start, state} = add_state(nil, state)
    {finish, state} = add_state(nil, state)
    {{start, finish}, if(join?, do: edge(state, start, finish), else: state)}
  end

  defp optional({left, right}, state) do
    {{start, finish}, state} = empty(state)
    {{start, finish}, state |> edge(start, left) |> edge(right, finish)}
  end

  defp concatenate({start, left}, {right, finish}, state),
    do: {{start, finish}, edge(state, left, right)}

  defp add_state(predicate, {states, count}) do
    if count == @states, do: Budget.refuse()
    {count, {Map.put(states, count, {predicate, []}), count + 1}}
  end

  defp edge({states, count}, from, to) do
    {predicate, edges} = Map.fetch!(states, from)
    {Map.put(states, from, {predicate, [to | edges]}), count}
  end

  defp invalid, do: raise(Invalid)
end
