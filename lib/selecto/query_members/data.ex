defmodule Selecto.QueryMembers.Data do
  @moduledoc """
  Named query members declared as portable data.

  A data member's query is rooted at a relation in the domain's own `schemas`
  section and written as data, so the same contract runs in every Selecto
  runtime:

      query_members: %{
        ctes: %{
          usage_totals: %{
            source: :usage_session,
            query: %{select: ["equipment_id", %{as: "sessions", aggregate: "count"}],
                     group_by: ["equipment_id"]},
            join: %{owner_key: :id, related_key: :equipment_id, type: :left}
          },
          category_tree: %{
            kind: :recursive,
            source: :category,
            base: %{select: ["id", "code", %{as: "depth", value: ["literal", 0, "integer"]}],
                    filter: ["is_null", "parent_id"]},
            step: %{select: ["id", "code",
                    %{as: "depth", value: ["add", ["previous", "depth"], ["literal", 1]]}]},
            step_join: %{owner_key: :parent_id, related_key: :id},
            join: %{owner_key: :category_id, related_key: :id, type: :inner}
          }
        },
        laterals: %{
          latest_ticket: %{
            source: :ticket,
            query: %{select: ["summary"], order_by: [["opened_at", "desc"]], limit: 1},
            correlations: %{equipment_id: :id},
            join_type: :left
          }
        }
      }

  `select` entries are field names, `%{as: name, value: VALUE_AST}`, or
  `%{as: name, aggregate: count|sum|avg|min|max, field: field}`; `filter` is the
  portable filter AST. `["previous", column]` is accepted only in a recursive
  `step` and reads the previous level's row.

  `to_runtime/4` rewrites a data member into the function form the named
  member APIs (`Selecto.with_cte/2`, `Selecto.with_lateral/2`) already execute;
  other members pass through unchanged.
  """

  alias Selecto.Domain.Contract.ComputedPredicates
  alias Selecto.Expr, as: X

  @aggregates ~w(count sum avg min max)
  @query_keys ~w(select filter group_by order_by limit)

  @doc "Whether a member spec is written as data."
  def data?(:ctes, spec) when is_map(spec) do
    recursive?(spec) or (is_map(get(spec, :query)) and not is_struct(get(spec, :query)))
  end

  def data?(:laterals, spec) when is_map(spec),
    do: is_map(get(spec, :query)) and not is_struct(get(spec, :query))

  def data?(_kind, _spec), do: false

  @doc "Rewrites a data member into the runtime function form."
  def to_runtime(selecto, kind, member_name, spec) do
    if data?(kind, spec), do: rewrite(selecto, kind, member_name, spec), else: spec
  end

  @doc "Validation errors for a data member (empty when valid)."
  def validation_errors(kind, spec) do
    try do
      case kind do
        :ctes ->
          if recursive?(spec) do
            check_query!(get(spec, :base), false)
            check_query!(get(spec, :step), true)
            check_keys!(get(spec, :step_join), [:owner_key, :related_key])
          else
            check_query!(get(spec, :query), false)
          end

          check_source!(spec)
          check_keys!(get(spec, :join), [:owner_key, :related_key])

        :laterals ->
          check_source!(spec)
          check_query!(get(spec, :query), false)

          unless is_map(get(spec, :correlations)) and map_size(get(spec, :correlations)) > 0,
            do: raise(ArgumentError, "correlations must be a non-empty map")

          unless to_string(get(spec, :join_type) || "left") in ~w(left inner cross),
            do: raise(ArgumentError, "join_type must be left, inner, or cross")
      end

      []
    rescue
      error in ArgumentError -> [Exception.message(error)]
    end
  end

  defp rewrite(selecto, :ctes, member_name, spec) do
    join = spec |> get(:join) |> keyword()

    if recursive?(spec) do
      cte_name = to_string(member_name)
      source = get(spec, :source)
      base = get(spec, :base)
      step = get(spec, :step)
      step_join = get(spec, :step_join)
      columns = get(spec, :columns) || output_columns(base)
      previous_fields = previous_fields(selecto, source, base, columns)

      %{
        type: :recursive,
        columns: columns,
        join: join,
        base_query: fn -> build(selecto, source, base, nil) end,
        recursive_query: fn _cte_ref ->
          selecto
          |> member_selecto(source)
          |> Selecto.join(String.to_atom(cte_name),
            source: cte_name,
            type: :inner,
            owner_key: atom(get(step_join, :owner_key)),
            related_key: atom(get(step_join, :related_key)),
            fields: previous_fields
          )
          |> apply_query(step, cte_name)
        end
      }
    else
      query = get(spec, :query)

      %{
        columns: get(spec, :columns) || output_columns(query),
        join: join,
        query: fn -> build(selecto, get(spec, :source), query, nil) end
      }
    end
  end

  defp rewrite(selecto, :laterals, _member_name, spec) do
    correlations = get(spec, :correlations)

    source = fn _base_query ->
      selecto
      |> member_selecto(get(spec, :source))
      |> apply_query(get(spec, :query), nil)
      |> Selecto.filter(
        Enum.map(correlations, fn {child, parent} ->
          {to_string(child), {:ref, "selecto_root.#{parent}"}}
        end)
      )
    end

    %{
      source: source,
      join_type: atom(get(spec, :join_type) || :left),
      data_columns: output_types(selecto, get(spec, :source), get(spec, :query))
    }
  end

  # Output columns of a member query with their types, for registration.
  defp output_types(selecto, source, query) do
    columns = output_columns(query)

    selecto
    |> previous_fields(source, query, columns)
    |> then(fn types -> Enum.map(columns, &%{name: &1, type: types[atom(&1)].type}) end)
  end

  defp build(selecto, source, query, previous) do
    selecto
    |> member_selecto(source)
    |> apply_query(query, previous)
  end

  # A Selecto rooted at the named relation of the parent domain's schemas.
  defp member_selecto(selecto, source) do
    schemas = Map.get(selecto.domain, :schemas, %{})

    schema =
      Map.get(schemas, source) || Map.get(schemas, to_string(source)) ||
        Map.get(schemas, atom(source)) ||
        raise ArgumentError, "query member source #{inspect(source)} is not a domain schema"

    domain = %{
      name: to_string(source),
      source: Map.put(schema, :associations, %{}),
      schemas: %{},
      joins: %{}
    }

    Selecto.configure(domain, Map.get(selecto, :runtime) || :compile_only,
      adapter: selecto.adapter,
      validate: false
    )
  end

  defp apply_query(selecto, query, previous) do
    selecto
    |> Selecto.select(Enum.map(get(query, :select), &selection(&1, previous)))
    |> maybe(get(query, :filter), &Selecto.filter(&1, filter(&2)))
    |> maybe(get(query, :group_by), &Selecto.group_by(&1, &2))
    |> maybe(get(query, :order_by), fn acc, orders ->
      Selecto.order_by(acc, Enum.map(orders, &order/1))
    end)
    |> maybe(get(query, :limit), &Selecto.limit(&1, &2))
  end

  defp maybe(selecto, nil, _fun), do: selecto
  defp maybe(selecto, value, fun), do: fun.(selecto, value)

  defp selection(field, _previous) when is_binary(field) or is_atom(field), do: to_string(field)

  defp selection(entry, previous) when is_map(entry) do
    as = to_string(get(entry, :as))

    cond do
      not is_nil(get(entry, :value)) ->
        X.as({:computed_value, previous_fields_in(get(entry, :value), previous)}, as)

      to_string(get(entry, :aggregate)) == "count" and is_nil(get(entry, :field)) ->
        X.as(X.count("*"), as)

      to_string(get(entry, :aggregate)) in @aggregates ->
        fun = String.to_existing_atom(to_string(get(entry, :aggregate)))
        X.as(apply(X, fun, [to_string(get(entry, :field))]), as)
    end
  end

  # ["previous", column] reads the recursive CTE's previous level, joined into
  # the step under the CTE's own name.
  defp previous_fields_in(["previous", column], cte_name) when is_binary(cte_name),
    do: ["field", "#{cte_name}.#{column}"]

  defp previous_fields_in(list, cte_name) when is_list(list),
    do: Enum.map(list, &previous_fields_in(&1, cte_name))

  defp previous_fields_in(value, _cte_name), do: value

  defp order([field, direction]),
    do:
      if(to_string(direction) == "desc",
        do: X.desc(to_string(field)),
        else: X.asc(to_string(field))
      )

  defp order(field), do: X.asc(to_string(field))

  defp filter([op | args]) when op in ["and", "or", :and, :or] do
    items =
      if match?([list] when is_list(list) and is_list(hd(list)), args), do: hd(args), else: args

    {atom(op), Enum.map(items, &filter/1)}
  end

  defp filter(["not", operand]), do: {:not, filter(operand)}
  defp filter(ast), do: ComputedPredicates.to_filter(ast)

  # Field types for the CTE columns the recursive step reads, taken from the
  # base selection in the same position.
  defp previous_fields(selecto, source, base, columns) do
    schemas = Map.get(selecto.domain, :schemas, %{})
    schema = Map.get(schemas, source) || Map.get(schemas, to_string(source)) || %{}
    schema_columns = Map.get(schema, :columns, %{})

    base
    |> get(:select)
    |> Enum.zip(columns)
    |> Map.new(fn {entry, column} ->
      type =
        cond do
          is_binary(entry) or is_atom(entry) ->
            column_type(schema_columns, entry)

          match?(["literal", _, _], get(entry, :value)) ->
            entry |> get(:value) |> List.last() |> atom()

          get(entry, :aggregate) in ["count", :count] ->
            :integer

          true ->
            :string
        end

      {atom(column), %{type: type}}
    end)
  end

  defp column_type(columns, field) do
    column =
      Map.get(columns, field) || Map.get(columns, to_string(field)) ||
        Map.get(columns, atom(field)) || %{}

    Map.get(column, :type, :string)
  end

  defp output_columns(query) do
    Enum.map(get(query, :select), fn
      field when is_binary(field) or is_atom(field) -> to_string(field)
      entry -> to_string(get(entry, :as))
    end)
  end

  defp recursive?(spec), do: to_string(get(spec, :kind) || "") == "recursive"

  defp check_source!(spec) do
    source = get(spec, :source)

    unless (is_binary(source) or is_atom(source)) and not is_nil(source),
      do: raise(ArgumentError, "data members require a source schema")
  end

  defp check_keys!(map, keys) do
    unless is_map(map) and Enum.all?(keys, &(not is_nil(get(map, &1)))),
      do: raise(ArgumentError, "expected keys #{inspect(keys)}")
  end

  defp check_query!(query, allow_previous?) do
    unless is_map(query), do: raise(ArgumentError, "member query must be a map")

    unknown = query |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in @query_keys))

    if unknown != [],
      do: raise(ArgumentError, "member query has unsupported keys #{inspect(unknown)}")

    select = get(query, :select)

    unless is_list(select) and select != [],
      do: raise(ArgumentError, "member query select must be a non-empty list")

    Enum.each(select, fn
      field when is_binary(field) or is_atom(field) ->
        :ok

      entry when is_map(entry) ->
        if is_nil(get(entry, :as)), do: raise(ArgumentError, "computed selections need :as")

        cond do
          not is_nil(get(entry, :value)) ->
            if not allow_previous? and contains_previous?(get(entry, :value)),
              do: raise(ArgumentError, "previous is available only in a recursive step")

          to_string(get(entry, :aggregate)) in @aggregates ->
            :ok

          true ->
            raise ArgumentError, "selection needs :value or a supported :aggregate"
        end

      _ ->
        raise ArgumentError, "invalid member selection"
    end)
  end

  defp contains_previous?(["previous" | _]), do: true
  defp contains_previous?(list) when is_list(list), do: Enum.any?(list, &contains_previous?/1)
  defp contains_previous?(_), do: false

  defp keyword(nil), do: nil

  defp keyword(map) when is_map(map),
    do: Enum.map(map, fn {k, v} -> {atom(k), join_value(k, v)} end)

  defp join_value(key, value)
       when key in [:owner_key, :related_key, "owner_key", "related_key", :type, "type"],
       do: atom(value)

  defp join_value(_key, value), do: value

  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp get(_map, _key), do: nil

  defp atom(value) when is_atom(value), do: value
  defp atom(value) when is_binary(value), do: String.to_atom(value)
end
