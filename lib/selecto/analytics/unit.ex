defmodule Selecto.Analytics.Unit do
  @moduledoc """
  Portable quantitative column and aggregate units.

  Unit metadata describes stored values. It does not choose graph axes, chart
  colors, or display formatting.
  """

  @kinds ~w(count currency distance duration mass percentage ratio scalar)
  @kind_atoms %{
    "count" => :count,
    "currency" => :currency,
    "distance" => :distance,
    "duration" => :duration,
    "mass" => :mass,
    "percentage" => :percentage,
    "ratio" => :ratio,
    "scalar" => :scalar
  }
  @behaviors ~w(flow stock ratio rate)
  @behavior_atoms %{"flow" => :flow, "stock" => :stock, "ratio" => :ratio, "rate" => :rate}
  @numeric_types ~w(integer int smallint bigint id decimal number numeric float double real)
  @count_aggregates ~w(count count_distinct true_count false_count buckets age_buckets)
  @preserving_aggregates ~w(sum avg min max)

  @spec numeric_type?(term()) :: boolean()
  def numeric_type?(type), do: normalize_text(type) in @numeric_types

  @spec normalize_column(map()) :: {:ok, map()} | {:error, String.t()}
  def normalize_column(column) when is_map(column) do
    type = value(column, :type)
    unit = value(column, :unit)
    behavior = value(column, :behavior)
    text_case = value(column, :text_case)

    cond do
      present?(column, :unit) and is_nil(unit) ->
        {:error, "unit must be a map"}

      present?(column, :behavior) and is_nil(behavior) ->
        {:error, "behavior must be a non-empty string"}

      present?(column, :unit) and not numeric_type?(type) ->
        {:error, "unit is available only for numeric columns"}

      present?(column, :behavior) and not numeric_type?(type) ->
        {:error, "behavior is available only for numeric columns"}

      present?(column, :text_case) and normalize_text(type) != "string" ->
        {:error, "text_case is available only for string columns"}

      present?(column, :text_case) and is_nil(text_case) ->
        {:error, "text_case must be uppercase or lowercase"}

      true ->
        with {:ok, normalized_unit} <- optional_unit(unit),
             {:ok, normalized_behavior} <- optional_behavior(behavior),
             {:ok, normalized_text_case} <- optional_text_case(text_case) do
          {:ok,
           column
           |> maybe_replace(:unit, normalized_unit)
           |> maybe_replace(:behavior, normalized_behavior)
           |> maybe_replace(:text_case, normalized_text_case)}
        end
    end
  end

  def normalize_column(_column), do: {:error, "column must be a map"}

  @spec normalize_unit(map()) :: {:ok, map()} | {:error, String.t()}
  def normalize_unit(unit) when is_map(unit) do
    unknown =
      Map.keys(unit) |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in ~w(kind code scale)))

    kind = normalize_text(value(unit, :kind))

    cond do
      unknown != [] ->
        {:error, "unit contains unsupported properties"}

      kind not in @kinds ->
        {:error, "unit kind is not available"}

      present?(unit, :scale) and kind != "percentage" ->
        {:error, "unit scale is not valid for #{kind}"}

      kind == "currency" ->
        code = value(unit, :code) |> normalize_text() |> String.upcase()

        if String.match?(code, ~r/^[A-Z]{3}$/),
          do: {:ok, %{kind: :currency, code: code}},
          else: {:error, "currency code must be three letters"}

      kind in ~w(distance duration mass) ->
        code = normalize_text(value(unit, :code))

        if String.match?(code, ~r/^[a-z][a-z0-9_]*$/),
          do: {:ok, %{kind: Map.fetch!(@kind_atoms, kind), code: code}},
          else: {:error, "unit code must be an identifier"}

      present?(unit, :code) ->
        {:error, "unit code is not valid for #{kind}"}

      kind == "percentage" ->
        scale =
          if present?(unit, :scale), do: normalize_text(value(unit, :scale)), else: "fraction"

        if scale in ~w(fraction whole),
          do:
            {:ok, %{kind: :percentage, scale: if(scale == "whole", do: :whole, else: :fraction)}},
          else: {:error, "percentage scale must be fraction or whole"}

      present?(unit, :scale) ->
        {:error, "unit scale is not valid for #{kind}"}

      true ->
        {:ok, %{kind: Map.fetch!(@kind_atoms, kind)}}
    end
  end

  def normalize_unit(_unit), do: {:error, "unit must be a map"}

  @spec normalize_behavior(term()) :: {:ok, atom()} | {:error, String.t()}
  def normalize_behavior(behavior) do
    name = normalize_text(behavior)

    if name in @behaviors,
      do: {:ok, Map.fetch!(@behavior_atoms, name)},
      else: {:error, "analytical behavior is not available"}
  end

  @spec column_unit(map()) :: map() | nil
  def column_unit(column) when is_map(column) do
    case value(column, :unit) do
      nil ->
        if numeric_type?(value(column, :type)), do: %{kind: :scalar}

      unit ->
        case normalize_unit(unit) do
          {:ok, normalized} -> normalized
          _ -> nil
        end
    end
  end

  def column_unit(_column), do: nil

  @spec column_behavior(map()) :: atom() | nil
  def column_behavior(column) when is_map(column) do
    case value(column, :behavior) do
      nil ->
        nil

      behavior ->
        case normalize_behavior(behavior) do
          {:ok, normalized} -> normalized
          _ -> nil
        end
    end
  end

  def column_behavior(_column), do: nil

  @spec aggregate_unit(map() | nil, atom() | String.t()) ::
          {:ok, map() | nil} | {:error, String.t()}
  def aggregate_unit(source_unit, aggregate) do
    name = normalize_text(aggregate)

    cond do
      name in @count_aggregates -> {:ok, %{kind: :count}}
      name not in @preserving_aggregates -> {:error, "aggregate result unit is not available"}
      is_nil(source_unit) -> {:ok, nil}
      true -> normalize_unit(source_unit)
    end
  end

  @spec compatible?(map(), map()) :: boolean()
  def compatible?(left, right) do
    with {:ok, left} <- normalize_unit(left),
         {:ok, right} <- normalize_unit(right),
         do: left == right,
         else: (_ -> false)
  end

  @spec signature(map()) :: {:ok, String.t()} | {:error, String.t()}
  def signature(unit) do
    with {:ok, normalized} <- normalize_unit(unit),
         do: {:ok, normalized |> Enum.sort() |> inspect()}
  end

  @spec normalize_domain_columns(map()) :: map()
  def normalize_domain_columns(domain) when is_map(domain) do
    domain
    |> normalize_relation(:source)
    |> normalize_schemas()
  end

  defp normalize_schemas(domain) do
    schemas = value(domain, :schemas)

    if is_map(schemas) do
      put_existing(
        domain,
        :schemas,
        Map.new(schemas, fn {id, relation} ->
          {id, normalize_relation(%{source: relation}, :source) |> Map.fetch!(:source)}
        end)
      )
    else
      domain
    end
  end

  defp normalize_relation(domain, key) do
    relation = value(domain, key)
    columns = if is_map(relation), do: value(relation, :columns)

    if is_map(columns) do
      normalized =
        Map.new(columns, fn {id, column} ->
          {id,
           case normalize_column(column) do
             {:ok, result} -> result
             _ -> column
           end}
        end)

      put_existing(domain, key, put_existing(relation, :columns, normalized))
    else
      domain
    end
  end

  defp optional_unit(nil), do: {:ok, nil}
  defp optional_unit(unit), do: normalize_unit(unit)
  defp optional_behavior(nil), do: {:ok, nil}
  defp optional_behavior(behavior), do: normalize_behavior(behavior)
  defp optional_text_case(nil), do: {:ok, nil}

  defp optional_text_case(value) do
    case normalize_text(value) do
      "uppercase" -> {:ok, :uppercase}
      "lowercase" -> {:ok, :lowercase}
      _ -> {:error, "text_case must be uppercase or lowercase"}
    end
  end

  defp maybe_replace(map, _key, nil), do: map
  defp maybe_replace(map, key, value), do: put_existing(map, key, value)

  defp put_existing(map, key, value) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.put(map, key, value)
      Map.has_key?(map, string_key) -> Map.put(map, string_key, value)
      true -> Map.put(map, key, value)
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp present?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp normalize_text(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.downcase()

  defp normalize_text(value) when is_binary(value), do: String.downcase(value)
  defp normalize_text(_value), do: ""
end
