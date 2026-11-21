defmodule Selecto.GroupingSets do
  @moduledoc """
  The grouping modes of a grouped query: plain `GROUP BY`, `ROLLUP`, `CUBE`
  and `GROUPING SETS`.

  A grouped query's subtotal rows come from a list of *grouping sets* over its
  *dimensions*:

  | mode | dimensions | sets |
  |---|---|---|
  | plain `group_by([d, ...])` | the fields | one set, all of them |
  | `rollup([d, ...])` | the fields | every leading run, longest first, ending with `[]` |
  | `cube([d, ...])` | the fields | every subset |
  | `grouping_sets([[d, ...], ...])` | distinct members, in first-appearance order | the sets as given |

  `positions/1` reports each set as positions into the dimension list. A
  cube's sets come most detailed first, then by bit mask descending with the
  first dimension most significant: `cube(["region", "channel", "tier"])`
  gives `[[0, 1, 2], [0, 1], [0, 2], [1, 2], [0], [1], [2], []]`. A declared
  set keeps the order it was written in.

  `{:grouping, [d, ...]}` selects SQL `GROUPING(...)`: one bit per argument,
  the first argument most significant, set when that dimension is grouped
  away in the row's set. It tells a subtotal row from a row whose real key is
  `NULL`.

  ## Limits and refusals

  `Selecto.group_by/2` raises `ArgumentError` for a malformed cube or set
  list while the query is built: a cube takes 1 to #{8} dimensions; grouping
  sets are 1 to #{64} lists, which may include `[]` but not only `[]`, with
  no dimension repeated inside a set and no two sets holding the same
  members; and a cube or grouping sets must be the query's only grouping.

  When the query is compiled, before any SQL is sent:

  - an adapter that does not support the mode (`supports?(:cube)`,
    `supports?(:grouping_sets)`) refuses with a `Selecto.Error` whose details
    carry `unsupported_feature: :cube | :grouping_sets`;
  - every `order_by` term must name a selected expression, its alias, or a
    selected position; anything else refuses with a `:validation_error` whose
    details carry `reason: :ordering_not_selected`.

  PostgreSQL and DuckDB compile the native clauses; SQLite emulates them with
  one `UNION ALL` branch per set (as it does rollups); MySQL and MariaDB have
  `WITH ROLLUP` only and refuse.
  """

  alias Selecto.Builder.ScopeRefusal

  @max_cube_dimensions 8
  @max_grouping_sets 64
  @modes [:cube, :grouping_sets]
  @directions [
    :asc,
    :desc,
    :asc_nulls_first,
    :asc_nulls_last,
    :desc_nulls_first,
    :desc_nulls_last
  ]

  @typedoc "A grouping mode."
  @type mode :: :plain | :rollup | :cube | :grouping_sets

  @typedoc "Dimensions, and each grouping set as positions into them."
  @type expansion :: %{dimensions: [term()], sets: [[non_neg_integer()]]}

  @doc "The most dimensions a cube takes."
  def max_cube_dimensions, do: @max_cube_dimensions

  @doc "The most sets `grouping_sets` takes."
  def max_grouping_sets, do: @max_grouping_sets

  @doc """
  The grouping mode of a query (or of a `group_by` list): `:plain` (including
  no grouping), `:rollup`, `:cube` or `:grouping_sets`.
  """
  @spec mode(Selecto.Types.t() | list()) :: mode()
  def mode(%{set: set}), do: set |> Map.get(:group_by, []) |> mode()

  def mode(group_by) when is_list(group_by) do
    cond do
      Enum.any?(group_by, &match?({:grouping_sets, _}, &1)) -> :grouping_sets
      Enum.any?(group_by, &match?({:cube, _}, &1)) -> :cube
      Enum.any?(group_by, &match?({:rollup, _}, &1)) -> :rollup
      true -> :plain
    end
  end

  def mode(_group_by), do: :plain

  @doc """
  The query's dimensions and grouping sets, each set as positions into the
  dimensions. A plain grouping is one set holding every dimension; no
  grouping is one empty set. Several grouping elements (`group_by(["a"])`
  then `group_by(rollup(["b"]))`) combine as SQL combines them: every set of
  one with every set of the next.
  """
  @spec positions(Selecto.Types.t() | list()) :: expansion()
  def positions(%{set: set}), do: set |> Map.get(:group_by, []) |> positions()

  def positions(group_by) when is_list(group_by) do
    {dimensions, _index, sets} =
      Enum.reduce(group_by, {[], %{}, [[]]}, fn element, {dimensions, index, sets} ->
        {members, element_sets} = element(element)

        {dimensions, index, global} =
          Enum.reduce(members, {dimensions, index, []}, fn member, {dims, idx, global} ->
            key = key(member)

            case idx do
              %{^key => position} ->
                {dims, idx, global ++ [position]}

              _ ->
                position = length(dims)
                {dims ++ [member], Map.put(idx, key, position), global ++ [position]}
            end
          end)

        global = List.to_tuple(global)

        sets =
          for set <- sets, element_set <- element_sets do
            Enum.uniq(set ++ Enum.map(element_set, &elem(global, &1)))
          end

        {dimensions, index, sets}
      end)

    %{dimensions: dimensions, sets: sets}
  end

  # One grouping element: its members and its sets as positions into them.
  defp element({:rollup, levels}) when is_list(levels) do
    levels = Enum.map(levels, &level_members/1)
    members = levels |> List.flatten() |> Enum.uniq_by(&key/1)
    index = members |> Enum.map(&key/1) |> Enum.with_index() |> Map.new()

    sets =
      for retained <- length(levels)..0//-1 do
        levels
        |> Enum.take(retained)
        |> List.flatten()
        |> Enum.map(&Map.fetch!(index, key(&1)))
        |> Enum.uniq()
      end

    {members, sets}
  end

  defp element({:cube, dimensions}) when is_list(dimensions),
    do: {dimensions, cube_sets(length(dimensions))}

  defp element({:grouping_sets, sets}) when is_list(sets) do
    members = sets |> Enum.concat() |> Enum.uniq_by(&key/1)
    index = members |> Enum.map(&key/1) |> Enum.with_index() |> Map.new()
    {members, Enum.map(sets, fn set -> Enum.map(set, &Map.fetch!(index, key(&1))) end)}
  end

  defp element({:grouping_set, members}) when is_list(members),
    do: {members, [Enum.to_list(0..(length(members) - 1)//1)]}

  defp element(dimension), do: {[dimension], [[0]]}

  defp level_members({:grouping_set, members}) when is_list(members), do: members
  defp level_members(member), do: [member]

  # Every subset of `count` dimensions, most detailed first, then by mask
  # descending (first dimension most significant).
  defp cube_sets(count) do
    0..(Bitwise.bsl(1, count) - 1)//1
    |> Enum.sort_by(fn mask -> {-bit_count(mask), -mask} end)
    |> Enum.map(fn mask ->
      for position <- 0..(count - 1)//1,
          Bitwise.band(mask, Bitwise.bsl(1, count - 1 - position)) != 0,
          do: position
    end)
  end

  defp bit_count(0), do: 0
  defp bit_count(mask), do: Bitwise.band(mask, 1) + bit_count(Bitwise.bsr(mask, 1))

  @doc false
  # The identity of a dimension: a field named by string or atom is one
  # dimension either way.
  def key(dimension)
      when is_atom(dimension) and not is_nil(dimension) and not is_boolean(dimension),
      do: Atom.to_string(dimension)

  def key({:field, dimension}), do: key(dimension)
  def key(dimension), do: dimension

  @doc false
  # Build-time shape check for group_by/2: `existing` is the query's grouping
  # so far, `added` the normalized entries being appended. Raises
  # ArgumentError.
  def validate_group_by!(existing, added) do
    added = if is_list(added), do: added, else: [added]
    combined = List.wrap(existing) ++ added

    if Enum.any?(combined, &mode_entry?/1) and length(combined) > 1 do
      invalid!("a cube or grouping sets must be the query's only grouping")
    end

    Enum.each(added, &validate_entry!/1)
    :ok
  end

  defp mode_entry?({mode, _}) when mode in @modes, do: true
  defp mode_entry?(_entry), do: false

  defp validate_entry!({:cube, dimensions}) do
    unless is_list(dimensions) and dimensions != [] and
             length(dimensions) <= @max_cube_dimensions do
      invalid!("a cube takes 1 to #{@max_cube_dimensions} dimensions")
    end

    if repeated?(dimensions), do: invalid!("a cube names a dimension twice")
    :ok
  end

  defp validate_entry!({:grouping_sets, sets}) do
    unless is_list(sets) and sets != [] and length(sets) <= @max_grouping_sets and
             Enum.all?(sets, &is_list/1) do
      invalid!("grouping sets must be 1 to #{@max_grouping_sets} lists of dimensions")
    end

    if Enum.all?(sets, &(&1 == [])),
      do: invalid!("grouping sets must name at least one dimension")

    if Enum.any?(sets, &repeated?/1), do: invalid!("a grouping set names a dimension twice")

    if sets |> Enum.map(&(&1 |> Enum.map(fn d -> key(d) end) |> Enum.sort())) |> repeated?(),
      do: invalid!("grouping sets must be distinct")

    :ok
  end

  defp validate_entry!(_entry), do: :ok

  defp repeated?(list), do: length(Enum.uniq_by(list, &key/1)) != length(list)

  defp invalid!(message), do: raise(ArgumentError, message)

  @doc false
  # Compile-time check of a CUBE or GROUPING SETS query, before any SQL is
  # sent (the executor calls it before the adapter's prepare_read/2): the
  # adapter must support the mode, and every ordering must name a selected
  # output. Raises Selecto.Builder.ScopeRefusal, which every execute entry
  # point returns as a typed Selecto.Error.
  def check!(selecto) do
    mode = mode(selecto)

    if mode in @modes do
      require_mode!(selecto, mode)
      _ = order_positions!(selecto)
    end

    :ok
  end

  defp require_mode!(selecto, mode) do
    adapter = Selecto.AdapterSQL.adapter(selecto)

    unless Selecto.AdapterSupport.supports_feature?(adapter, mode) do
      name = if mode == :cube, do: "CUBE", else: "GROUPING SETS"

      ScopeRefusal.unsupported!(
        Selecto.Error.validation_error("adapter #{inspect(adapter)} does not support #{name}", %{
          unsupported_feature: mode
        })
      )
    end
  end

  @doc false
  # The query with its orderings as `{{:literal_position, n}, direction}`,
  # each naming a selected output; refuses an ordering that names none.
  def with_position_orders!(selecto) do
    check!(selecto)
    put_in(selecto.set.order_by, order_positions!(selecto))
  end

  defp order_positions!(selecto) do
    selected = Map.get(selecto.set, :selected, [])

    Enum.map(Map.get(selecto.set, :order_by, []), fn order ->
      {target, direction} = order_parts(order)
      {{:literal_position, position!(target, selected)}, direction}
    end)
  end

  defp order_parts({direction, target}) when direction in @directions, do: {target, direction}
  defp order_parts({target, direction}) when direction in @directions, do: {target, direction}
  defp order_parts(target), do: {target, :asc_nulls_first}

  defp position!({:literal_position, position}, selected)
       when is_integer(position) and position > 0 do
    if position <= length(selected),
      do: position,
      else: not_selected!({:literal_position, position})
  end

  defp position!(target, selected) do
    index =
      Enum.find_index(selected, fn item ->
        same?(target, item) or same?(target, unalias(item)) or
          (is_binary(target) and alias_of(item) == target)
      end)

    if index, do: index + 1, else: not_selected!(target)
  end

  defp same?(left, right), do: left == right or key(left) == key(right)

  defp unalias({:field, expression, _alias}), do: expression
  defp unalias(expression), do: expression

  defp alias_of({:field, _expression, alias_name}), do: to_string(alias_name)
  defp alias_of(_item), do: nil

  defp not_selected!(target) do
    ScopeRefusal.unsupported!(
      Selecto.Error.validation_error(
        "an ordering of a cube or grouping sets query must name a selected output",
        %{reason: :ordering_not_selected, order: inspect(target)}
      )
    )
  end
end
