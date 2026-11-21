defmodule Selecto.Domain.JoinConditions do
  @moduledoc false

  # Association `conditions` (certification profile engine_join_conditions):
  # comparisons of an owner field with a target field ANDed after the
  # association's key equality wherever the association is joined.
  #
  #     associations: %{price: %{
  #       queryable: :prices, field: :price, owner_key: :product_id,
  #       related_key: :product_id,
  #       conditions: [
  #         %{left: :ordered_on, op: :gte, right: :valid_from},
  #         %{left: :ordered_on, op: :lt, right: :valid_to, open: true}
  #       ]
  #     }}
  #
  # A non-empty list of at most 8 entries with exactly `left`, `op`, `right`
  # and optionally `open`. `left` is a physical, unredacted field of the owner
  # relation, `right` one of the target. `op` is eq, ne, lt, lte, gt or gte
  # (any case). Both sides belong to one type family; ordering operators take
  # numbers, dates, times and date-times only. `open` (a boolean, or 0/1;
  # ordering operators only) also matches a NULL right side. A `through` or
  # `values` association refuses them; owner_key/related_key stay required.

  alias Selecto.Builder.ExactCompare
  alias Selecto.Domain.Contract.Shared.Core

  @limit 8
  @keys ~w(left op right open)
  @ops ~w(eq ne lt lte gt gte)
  @ordering ~w(lt lte gt gte)
  @family %{
    "integer" => :numeric,
    "decimal" => :numeric,
    "string" => :string,
    "text" => :string,
    "date" => :date,
    "time" => :time,
    "utc_datetime" => :datetime,
    "naive_datetime" => :datetime,
    "epoch_datetime" => :epoch_datetime,
    "boolean" => :boolean,
    "uuid" => :uuid,
    # Ecto spellings of the same families (native authoring).
    "id" => :numeric,
    "float" => :numeric,
    "binary_id" => :uuid,
    "utc_datetime_usec" => :datetime,
    "naive_datetime_usec" => :datetime
  }
  @ordered [:numeric, :date, :time, :datetime, :epoch_datetime]
  @sql_ops %{"lt" => " < ", "lte" => " <= ", "gt" => " > ", "gte" => " >= "}

  @doc false
  # The normalized conditions: `[%{left: string, op: string, right: string,
  # open: true}]` (`open` only when true). Assumes a validated list.
  def normalize(conditions) when is_list(conditions) do
    Enum.map(conditions, fn condition ->
      base = %{
        left: to_string(value(condition, :left)),
        op: condition |> value(:op) |> to_string() |> String.downcase(),
        right: to_string(value(condition, :right))
      }

      if open?(value(condition, :open)), do: Map.put(base, :open, true), else: base
    end)
  end

  def normalize(_conditions), do: []

  @doc false
  # Contract errors for every association of the root source and the schemas
  # that declares `conditions`.
  def errors(normalized_domain) do
    source = Map.get(normalized_domain, :source)
    schemas = Map.get(normalized_domain, :schemas) || %{}
    authored = Map.get(normalized_domain, :authored_domain) || %{}
    domain_redacted = List.wrap(Core.map_value(authored, :redact_fields) || [])

    [
      {:source, source, [:source], true}
      | Enum.map(schemas, fn {id, r} -> {id, r, [:schemas, id], false} end)
    ]
    |> Enum.flat_map(fn {_id, relation, path, root?} ->
      relation_errors(relation, path, root?, schemas, domain_redacted)
    end)
  end

  defp relation_errors(relation, path, root?, schemas, domain_redacted) when is_map(relation) do
    case Core.map_value(relation, :associations) do
      associations when is_map(associations) ->
        associations
        |> Enum.sort_by(fn {name, _} -> to_string(name) end)
        |> Enum.flat_map(fn {name, association} ->
          if is_map(association) and Core.has_key?(association, :conditions) do
            target =
              case Core.fetch_key(schemas, Core.map_value(association, :queryable)) do
                {:ok, target} -> target
                :error -> nil
              end

            context = %{
              owner: relation,
              target: target,
              name: name,
              root?: root?,
              domain_redacted: Enum.map(domain_redacted, &to_string/1)
            }

            case problem(Core.map_value(association, :conditions), association, context) do
              nil ->
                []

              {message, details} ->
                [
                  Core.error(
                    :invalid_join_conditions,
                    path ++ [:associations, name, :conditions],
                    "association #{name} conditions #{message}",
                    Map.put(details, :reason, :invalid_join_conditions)
                  )
                ]
            end
          else
            []
          end
        end)

      _ ->
        []
    end
  end

  defp relation_errors(_relation, _path, _root?, _schemas, _domain_redacted), do: []

  # nil, or `{message, details}` for the first rule the list breaks.
  defp problem(conditions, association, context) do
    cond do
      not (is_list(conditions) and conditions != [] and length(conditions) <= @limit) ->
        {"must be a non-empty array of at most #{@limit} entries", %{}}

      Core.has_key?(association, :through) or Core.has_key?(association, :join_through) ->
        {"are not available on a through association", %{}}

      not is_nil(Core.map_value(context.target || %{}, :values)) ->
        {"are not available on a values association", %{}}

      true ->
        conditions
        |> Enum.with_index()
        |> Enum.find_value(fn {condition, index} -> entry_problem(condition, index, context) end)
    end
  end

  defp entry_problem(condition, index, context) when is_map(condition) do
    unknown =
      condition
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in @keys))
      |> Enum.sort()

    with :ok <-
           check(unknown == [], "entries take only left, op, right and open", index,
             keys: unknown
           ),
         :ok <- strings(condition, index),
         op = condition |> value(:op) |> to_string() |> String.downcase(),
         :ok <-
           check(
             op in @ops,
             "operator #{value(condition, :op)} is not one of eq, ne, lt, lte, gt or gte",
             index
           ),
         {:ok, owner_family} <- side(:owner, value(condition, :left), context, index),
         {:ok, target_family} <- side(:target, value(condition, :right), context, index),
         :ok <-
           check(
             owner_family == target_family,
             "compare #{value(condition, :left)} and #{value(condition, :right)} of different types",
             index
           ),
         ordering? = op in @ordering,
         :ok <-
           check(
             not ordering? or owner_family in @ordered,
             "#{op} compares numbers, dates and times only",
             index
           ),
         :ok <- open_problem(condition, ordering?, index) do
      nil
    else
      {:problem, message, details} -> {message, details}
    end
  end

  defp entry_problem(_condition, index, _context),
    do: {"entries must be objects", %{index: index}}

  defp check(ok?, message, index, details \\ [])
  defp check(true, _message, _index, _details), do: :ok

  defp check(false, message, index, details),
    do: {:problem, message, Map.new([{:index, index} | details])}

  defp strings(condition, index) do
    Enum.reduce_while([:left, :op, :right], :ok, fn key, :ok ->
      case value(condition, key) do
        text
        when (is_binary(text) and text != "") or
               (is_atom(text) and not is_nil(text) and not is_boolean(text)) ->
          {:cont, :ok}

        _ ->
          {:halt, {:problem, "entries require a string #{key}", %{index: index}}}
      end
    end)
  end

  defp side(side, field, context, index) do
    relation = if side == :owner, do: context.owner, else: context.target
    fields = Core.map_value(relation || %{}, :fields) || []
    columns = Core.map_value(relation || %{}, :columns) || %{}
    name = to_string(field)

    column =
      Enum.find_value(columns, fn {key, column} -> if to_string(key) == name, do: column end)

    cond do
      not Enum.any?(List.wrap(fields), &(to_string(&1) == name)) or not is_map(column) ->
        {:problem, "#{side} field #{name} is not a field", %{index: index, field: name}}

      Core.has_key?(column, :computed) ->
        {:problem, "#{side} field #{name} is computed", %{index: index, field: name}}

      redacted?(side, name, column, relation, context) ->
        {:problem, "#{side} field #{name} is redacted", %{index: index, field: name}}

      true ->
        case family(Core.map_value(column, :type)) do
          nil ->
            {:problem, "#{side} field #{name} has a type conditions cannot compare",
             %{index: index, field: name}}

          family ->
            {:ok, family}
        end
    end
  end

  defp redacted?(side, name, column, relation, context) do
    domain_name =
      cond do
        side == :target -> "#{context.name}.#{name}"
        context.root? -> name
        true -> nil
      end

    Selecto.Domain.flag(column, :redacted, false) or
      Enum.any?(
        List.wrap(Core.map_value(relation, :redact_fields) || []),
        &(to_string(&1) == name)
      ) or
      (not is_nil(domain_name) and domain_name in context.domain_redacted)
  end

  defp open_problem(condition, ordering?, index) do
    if has_key?(condition, :open) do
      open = value(condition, :open)

      cond do
        open not in [true, false, 0, 1] ->
          {:problem, "open must be a boolean", %{index: index}}

        not ordering? ->
          {:problem, "open is available only with lt, lte, gt and gte", %{index: index}}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  @doc false
  # The type family of a declared column type, or nil.
  def family(type) when is_atom(type) and not is_nil(type),
    do: family(Atom.to_string(type))

  def family(type) when is_binary(type), do: Map.get(@family, String.downcase(type))
  def family(_type), do: nil

  @doc false
  # The SQL of normalized `conditions` between `owner_alias` and
  # `target_alias`: one iodata entry per condition. `target_relation` gives the
  # target's declared column types (exact text eq/ne on MySQL and MariaDB).
  def sql(_selecto, [], _owner_alias, _target_alias, _target_relation), do: []
  def sql(_selecto, nil, _owner_alias, _target_alias, _target_relation), do: []

  def sql(selecto, conditions, owner_alias, target_alias, target_relation) do
    conditions
    |> normalize()
    |> Enum.map(fn %{left: left, op: op, right: right} = condition ->
      left_sql = column(selecto, owner_alias, left)
      right_sql = column(selecto, target_alias, right)

      case op do
        op when op in ["eq", "ne"] ->
          exact =
            ExactCompare.enabled?(selecto) and
              family(column_type(target_relation, right)) == :string

          equal = ExactCompare.eq(left_sql, right_sql, exact)
          if op == "eq", do: equal, else: ["NOT (", equal, ")"]

        _ordering ->
          compare = [left_sql, Map.fetch!(@sql_ops, op), right_sql]

          if Map.get(condition, :open),
            do: ["(", right_sql, " IS NULL OR ", compare, ")"],
            else: compare
      end
    end)
  end

  defp column_type(relation, field) when is_map(relation) do
    columns = Core.map_value(relation, :columns) || %{}

    Enum.find_value(columns, fn {key, column} ->
      if to_string(key) == field and is_map(column), do: Core.map_value(column, :type)
    end)
  end

  defp column_type(_relation, _field), do: nil

  defp column(selecto, alias_name, field),
    do: [
      Selecto.Builder.Sql.Helpers.quote_identifier(selecto, to_string(alias_name)),
      ".",
      selecto.adapter.quote_identifier(field)
    ]

  @doc false
  # The flag reading of `open` (true, 1).
  def open?(open), do: open in [true, 1]

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
