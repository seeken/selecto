defmodule Selecto.Domain.Shorthand.Computed do
  @moduledoc """
  Computed-column shorthand: `temporal_delta` and `bucket`.

  Two common computed columns are written as a short declaration on a root
  column and replaced, when the domain is normalized or configured, by the
  `expression` computed column they stand for. After that the column is an
  ordinary read-only value expression (`Selecto.Domain.Contract.ComputedValues`):
  selectable, filterable, groupable and orderable, and the normalized domain
  carries the expansion, never the shorthand.

  ## temporal_delta

      lead_days: %{
        type: :integer,
        computed: %{kind: :temporal_delta, from: "purchased_at", to: "event.starts_on"}
      }

  expands to `["days_between", ["field", from], ["field", to]]`: the whole
  calendar days from `from` to `to` (the difference of the two dates, whatever
  the times of day), negative when `to` is the earlier date and `nil` when
  either is `nil`. `unit` may be given and must be `day`. Both fields must be
  dates or datetimes; declare the column `:integer`.

  ## bucket

      lead_bucket: %{
        type: :string,
        computed: %{
          kind: :bucket,
          field: "lead_days",
          otherwise: "Unknown",
          buckets: [
            %{label: "After the start", max: -1},
            %{label: "0-6 days", min: 0, max: 6},
            %{label: "30+ days", min: 30}
          ]
        }
      }

  expands to a `case` expression with one branch per bucket in the order
  written. Bounds are inclusive numbers (`min`, `max` or both); buckets may not
  share a value; labels are distinct non-blank strings; at most 50 buckets.
  A value outside every bucket, and `nil`, give `nil` unless `otherwise` names
  a label for them. The source field must be numeric and may itself be a
  computed column. Labels are plain strings, so ordering by the column sorts
  them as text. Declare the column `:string`.

  An invalid declaration is a domain error (`:invalid_computed_value`).
  """

  alias Selecto.Domain.Contract.ComputedValues
  alias Selecto.Domain.Shared.Map, as: MapHelpers

  @kinds ["temporal_delta", "bucket"]
  @max_buckets 50
  @path ~r/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/

  @doc "The shorthand computed kinds, as strings."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Whether a computed column declaration uses a shorthand kind."
  @spec shorthand?(term()) :: boolean()
  def shorthand?(computed) when is_map(computed), do: kind(computed) in @kinds
  def shorthand?(_computed), do: false

  @doc """
  Replaces each root shorthand computed column with the expression column it
  stands for. A declaration that does not expand is left as written and
  reported, so the caller can refuse the domain.
  """
  @spec expand(map()) :: {map(), [map()]}
  def expand(domain) when is_map(domain) do
    with source when is_map(source) <- MapHelpers.section(domain, :source),
         columns when is_map(columns) <- MapHelpers.map_value(source, :columns),
         true <- Enum.any?(columns, fn {_field, column} -> shorthand_column?(column) end) do
      type_of = &field_type(domain, source, &1)

      {columns, errors} =
        Enum.reduce(columns, {%{}, []}, fn {field, column}, {acc, errors} ->
          if shorthand_column?(column) do
            computed = MapHelpers.map_value(column, :computed)

            case expression(computed, type_of) do
              {:ok, expression} ->
                {Map.put(acc, field, put_expression(column, computed, expression)), errors}

              {:error, message} ->
                {Map.put(acc, field, column), [error(field, message) | errors]}
            end
          else
            {Map.put(acc, field, column), errors}
          end
        end)

      source = MapHelpers.put_map_value(source, :columns, columns)
      {MapHelpers.put_section(domain, :source, source), Enum.reverse(errors)}
    else
      _ -> {domain, []}
    end
  end

  def expand(domain), do: {domain, []}

  @doc """
  The value expression a shorthand declaration stands for.

  `type_of` returns a field path's declared type, or `nil` when it cannot be
  told here; a `bucket` source of a known non-numeric type is refused.
  """
  @spec expression(map(), (String.t() -> term())) :: {:ok, list()} | {:error, String.t()}
  def expression(computed, type_of \\ fn _path -> nil end) when is_map(computed) do
    case kind(computed) do
      "temporal_delta" -> temporal_delta(computed)
      "bucket" -> bucket(computed, type_of)
      other -> {:error, "unsupported shorthand kind #{inspect(other)}"}
    end
  end

  defp temporal_delta(computed) do
    with :ok <- only(computed, ~w(kind from to unit)),
         :ok <- unit(MapHelpers.map_value(computed, :unit)),
         {:ok, from} <- path(MapHelpers.map_value(computed, :from), "temporal_delta from"),
         {:ok, to} <- path(MapHelpers.map_value(computed, :to), "temporal_delta to") do
      {:ok, ["days_between", ["field", from], ["field", to]]}
    end
  end

  defp unit(nil), do: :ok
  defp unit(unit) when unit in [:day, "day"], do: :ok
  defp unit(_unit), do: {:error, "temporal_delta unit must be day"}

  defp bucket(computed, type_of) do
    with :ok <- only(computed, ~w(kind field buckets otherwise)),
         {:ok, source} <- path(MapHelpers.map_value(computed, :field), "bucket field"),
         :ok <- numeric_source(source, type_of.(source)),
         {:ok, buckets} <- bucket_list(MapHelpers.map_value(computed, :buckets)),
         {:ok, ranges} <- ranges(buckets),
         :ok <- disjoint(ranges),
         {:ok, otherwise} <- otherwise(MapHelpers.map_value(computed, :otherwise), ranges) do
      branches = Enum.map(ranges, &branch(source, &1))
      {:ok, ["case" | branches ++ otherwise]}
    end
  end

  defp numeric_source(_source, nil), do: :ok

  defp numeric_source(source, type) do
    if ComputedValues.category(type) in [:integer, :decimal],
      do: :ok,
      else: {:error, "bucket field #{source} must be numeric"}
  end

  defp bucket_list(buckets) when is_list(buckets) and buckets != [] do
    if length(buckets) <= @max_buckets,
      do: {:ok, buckets},
      else: {:error, "buckets must be a list of 1 to #{@max_buckets} ranges"}
  end

  defp bucket_list(_buckets),
    do: {:error, "buckets must be a list of 1 to #{@max_buckets} ranges"}

  defp ranges(buckets) do
    buckets
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn bucket, {:ok, acc, labels} ->
      case range(bucket, labels) do
        {:ok, {_min, _max, label} = range} ->
          {:cont, {:ok, [range | acc], MapSet.put(labels, label)}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, ranges, _labels} -> {:ok, Enum.reverse(ranges)}
      error -> error
    end
  end

  defp range(bucket, labels) when is_map(bucket) do
    with :ok <- only(bucket, ~w(label min max), "a bucket is %{label: ..., min: ..., max: ...}"),
         {:ok, label} <- label(MapHelpers.map_value(bucket, :label), labels),
         {:ok, min} <- bound(MapHelpers.map_value(bucket, :min), "min"),
         {:ok, max} <- bound(MapHelpers.map_value(bucket, :max), "max") do
      cond do
        is_nil(min) and is_nil(max) ->
          {:error, "bucket #{label} needs a min, a max, or both"}

        not is_nil(min) and not is_nil(max) and min > max ->
          {:error, "bucket #{label} has min above max"}

        true ->
          {:ok, {min, max, label}}
      end
    end
  end

  defp range(_bucket, _labels), do: {:error, "a bucket is %{label: ..., min: ..., max: ...}"}

  defp label(label, labels) when is_binary(label) do
    if String.trim(label) != "" and not MapSet.member?(labels, label),
      do: {:ok, label},
      else: {:error, "bucket labels must be distinct non-blank strings"}
  end

  defp label(_label, _labels), do: {:error, "bucket labels must be distinct non-blank strings"}

  defp bound(nil, _key), do: {:ok, nil}
  defp bound(value, _key) when is_integer(value) or is_float(value), do: {:ok, value}

  defp bound(value, key) when is_binary(value) do
    if Regex.match?(~r/\A-?[0-9]+(?:\.[0-9]+)?\z/, value) do
      if String.contains?(value, ".") do
        case Float.parse(value) do
          {number, ""} -> {:ok, number}
          _ -> {:error, "bucket #{key} must be a number"}
        end
      else
        {:ok, String.to_integer(value)}
      end
    else
      {:error, "bucket #{key} must be a number"}
    end
  end

  defp bound(_value, key), do: {:error, "bucket #{key} must be a number"}

  # Both bounds are inclusive, so two buckets may not share a value: a row has
  # at most one label whatever order the buckets are written in. Sorted by
  # lower bound, any overlap shows between neighbours.
  defp disjoint(ranges) do
    ranges
    |> Enum.sort_by(fn {min, _max, _label} -> min end, &lower_first?/2)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [{_, previous_max, _}, {next_min, _, _}] ->
      is_nil(previous_max) or is_nil(next_min) or next_min <= previous_max
    end)
    |> case do
      nil -> :ok
      [{_, _, first}, {_, _, second}] -> {:error, "buckets #{first} and #{second} overlap"}
    end
  end

  defp lower_first?(nil, _other), do: true
  defp lower_first?(_min, nil), do: false
  defp lower_first?(left, right), do: left <= right

  defp otherwise(nil, _ranges), do: {:ok, []}

  defp otherwise(label, ranges) when is_binary(label) do
    if String.trim(label) != "" and not Enum.any?(ranges, &(elem(&1, 2) == label)),
      do: {:ok, [["else", ["literal", label, "string"]]]},
      else: otherwise_error()
  end

  defp otherwise(_label, _ranges), do: otherwise_error()

  defp otherwise_error,
    do: {:error, "bucket otherwise must be a non-blank label distinct from the buckets"}

  defp branch(source, {min, max, label}) do
    condition =
      case {min, max} do
        {min, nil} -> ["gte", source, min]
        {nil, max} -> ["lte", source, max]
        {min, max} -> ["and", ["gte", source, min], ["lte", source, max]]
      end

    [condition, ["literal", label, "string"]]
  end

  defp only(map, allowed, message \\ nil) do
    case map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in allowed)) do
      [] ->
        :ok

      unknown ->
        {:error, message || "unsupported keys #{unknown |> Enum.sort() |> Enum.join(", ")}"}
    end
  end

  defp path(value, label) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: path(Atom.to_string(value), label)

  defp path(value, label) when is_binary(value) do
    if value =~ @path, do: {:ok, value}, else: {:error, "#{label} must be a field path"}
  end

  defp path(_value, label), do: {:error, "#{label} must be a field path"}

  defp put_expression(column, computed, expression) do
    expanded =
      if Map.has_key?(computed, :kind),
        do: %{kind: :expression, expression: expression},
        else: %{"kind" => "expression", "expression" => expression}

    MapHelpers.put_map_value(column, :computed, expanded)
  end

  defp shorthand_column?(column) when is_map(column),
    do: shorthand?(MapHelpers.map_value(column, :computed))

  defp shorthand_column?(_column), do: false

  defp kind(computed) do
    case MapHelpers.map_value(computed, :kind) do
      kind when is_atom(kind) and not is_nil(kind) -> Atom.to_string(kind)
      kind -> kind
    end
  end

  # The declared type of a root field or of a field one association away;
  # deeper paths are left to the query.
  defp field_type(domain, source, path) do
    case String.split(path, ".") do
      [name] ->
        column_type(source, name)

      [association, name] ->
        with spec when is_map(spec) <- MapHelpers.relation_association(source, association),
             queryable when not is_nil(queryable) <- MapHelpers.map_value(spec, :queryable),
             schemas when is_map(schemas) <- MapHelpers.section(domain, :schemas),
             schema when is_map(schema) <- registry_value(schemas, queryable) do
          column_type(schema, name)
        else
          _ -> nil
        end

      _deeper ->
        nil
    end
  end

  defp column_type(relation, name) do
    with columns when is_map(columns) <- MapHelpers.map_value(relation, :columns),
         column when is_map(column) <- registry_value(columns, name) do
      MapHelpers.map_value(column, :type)
    else
      _ -> nil
    end
  end

  defp registry_value(registry, key) do
    key = to_string(key)
    Enum.find_value(registry, fn {id, value} -> if to_string(id) == key, do: value end)
  end

  defp error(field, message) do
    field = MapHelpers.field_id(field)

    %{
      code: :invalid_computed_value,
      path: [:source, :columns, field, :computed],
      field: field,
      message: "computed column #{field}: #{message}"
    }
  end
end
