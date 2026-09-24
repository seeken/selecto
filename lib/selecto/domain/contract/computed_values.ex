defmodule Selecto.Domain.Contract.ComputedValues do
  @moduledoc """
  Validation for governed computed value columns (`computed.kind: :expression`).

  A value expression is a closed, typed AST shared by every Selecto runtime:

      ["field", "site.name"]
      ["literal", 100] / ["literal", 100, "decimal"]
      ["coalesce", value, value, ...]
      ["case", [filter, value], ..., ["else", value]]
      ["add" | "subtract" | "multiply" | "divide", value, value]
      ["cast", value, type]
      ["json_text", field_path, [segment, ...]]
      ["lower" | "upper", value]
      ["concat", value, value, ...]

  `filter` is the portable filter AST used by computed predicates. The AST never
  carries SQL text; the SQL builder binds literals and JSON path segments.
  """

  alias Selecto.Domain.Contract.ComputedPredicates

  @arithmetic ~w(add subtract multiply divide)
  @case_functions ~w(lower upper)
  @cast_types ~w(string integer decimal boolean date utc_datetime)
  @path ~r/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/
  @segment ~r/\A[A-Za-z0-9_]+\z/

  @doc "Validates the shape of a value expression. Returns root-level dependencies."
  def validate(expression) do
    with {:ok, normalized} <- normalize(expression) do
      {:ok, normalized, dependencies(normalized)}
    end
  end

  @doc "Normalizes operator names to strings and infers untyped literal types."
  def normalize([op | arguments]) when is_atom(op) or is_binary(op),
    do: normalize_node(to_string(op), arguments)

  def normalize(_), do: {:error, "value expression must be a non-empty list"}

  defp normalize_node("field", [path]) when is_atom(path) or is_binary(path) do
    path = to_string(path)
    if path =~ @path, do: {:ok, ["field", path]}, else: {:error, "field requires a governed path"}
  end

  defp normalize_node("literal", [value]), do: normalize_node("literal", [value, nil])

  defp normalize_node("literal", [value, type]) do
    cond do
      is_nil(value) ->
        {:error, "literal value must not be null"}

      not (is_binary(value) or is_number(value) or is_boolean(value)) ->
        {:error, "literal value must be a scalar"}

      is_nil(type) ->
        {:ok, ["literal", value, inferred_literal_type(value)]}

      to_string(type) in @cast_types ->
        {:ok, ["literal", value, to_string(type)]}

      true ->
        {:error, "literal type must be one of #{Enum.join(@cast_types, ", ")}"}
    end
  end

  defp normalize_node(op, arguments) when op in ["coalesce", "concat"] do
    if length(arguments) >= 2,
      do: normalize_all(op, arguments),
      else: {:error, "#{op} requires at least two values"}
  end

  defp normalize_node(op, [_left, _right] = arguments) when op in @arithmetic,
    do: normalize_all(op, arguments)

  defp normalize_node(op, _arguments) when op in @arithmetic,
    do: {:error, "#{op} requires exactly two values"}

  defp normalize_node(op, [argument]) when op in @case_functions do
    with {:ok, value} <- normalize(argument), do: {:ok, [op, value]}
  end

  defp normalize_node("cast", [value, type]) do
    if to_string(type) in @cast_types do
      with {:ok, value} <- normalize(value), do: {:ok, ["cast", value, to_string(type)]}
    else
      {:error, "cast type must be one of #{Enum.join(@cast_types, ", ")}"}
    end
  end

  defp normalize_node("json_text", [path, segments])
       when (is_atom(path) or is_binary(path)) and is_list(segments) and segments != [] do
    cond do
      not (to_string(path) =~ @path) ->
        {:error, "json_text requires a governed field path"}

      not Enum.all?(segments, &(is_binary(&1) or is_integer(&1))) or
          not Enum.all?(segments, &(to_string(&1) =~ @segment)) ->
        {:error, "json_text segments must be letters, digits, or underscores"}

      true ->
        {:ok, ["json_text", to_string(path), Enum.map(segments, &to_string/1)]}
    end
  end

  defp normalize_node("case", branches) when is_list(branches) and branches != [] do
    {else_branches, when_branches} =
      Enum.split_with(branches, fn
        [marker, _value] when marker in [:else, "else"] -> true
        _ -> false
      end)

    cond do
      when_branches == [] ->
        {:error, "case requires at least one condition"}

      length(else_branches) > 1 ->
        {:error, "case accepts one else branch"}

      else_branches != [] and List.last(branches) != hd(else_branches) ->
        {:error, "case else must be the last branch"}

      true ->
        with {:ok, whens} <- normalize_whens(when_branches),
             {:ok, else_value} <- normalize_else(else_branches) do
          {:ok, ["case" | whens ++ else_value]}
        end
    end
  end

  defp normalize_node(op, _arguments), do: {:error, "unsupported value expression operator #{op}"}

  defp normalize_all(op, arguments) do
    arguments
    |> Enum.reduce_while({:ok, []}, fn argument, {:ok, acc} ->
      case normalize(argument) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, [op | Enum.reverse(values)]}
      error -> error
    end
  end

  defp normalize_whens(branches) do
    Enum.reduce_while(branches, {:ok, []}, fn
      [condition, value], {:ok, acc} ->
        with :ok <- valid_condition(condition),
             {:ok, value} <- normalize(value) do
          {:cont, {:ok, acc ++ [[condition, value]]}}
        else
          error -> {:halt, error}
        end

      _branch, _acc ->
        {:halt, {:error, "case branches must be [condition, value]"}}
    end)
  end

  defp normalize_else([]), do: {:ok, []}

  defp normalize_else([[_marker, value]]) do
    with {:ok, value} <- normalize(value), do: {:ok, [["else", value]]}
  end

  defp valid_condition(condition) do
    ComputedPredicates.to_filter(condition)
    :ok
  rescue
    _ -> {:error, "case condition is not a valid filter"}
  end

  @doc "Every governed field path the expression reads, including case conditions."
  def dependencies(["field", path]), do: [path]
  def dependencies(["json_text", path, _segments]), do: [path]
  def dependencies(["literal" | _]), do: []
  def dependencies(["cast", value, _type]), do: dependencies(value)

  def dependencies(["case" | branches]) do
    branches
    |> Enum.flat_map(fn
      ["else", value] -> dependencies(value)
      [condition, value] -> filter_fields(condition) ++ dependencies(value)
    end)
    |> Enum.uniq()
  end

  def dependencies([_op | arguments]),
    do: arguments |> Enum.flat_map(&dependencies/1) |> Enum.uniq()

  defp filter_fields([op, operands]) when op in [:and, :or, "and", "or"] and is_list(operands),
    do: Enum.flat_map(operands, &filter_fields/1)

  defp filter_fields([op, operand]) when op in [:not, "not"], do: filter_fields(operand)

  defp filter_fields([_op, field | rest]) when is_atom(field) or is_binary(field) do
    references = for [tag, ref] <- rest, tag in [:field, "field"], do: to_string(ref)
    [to_string(field) | references]
  end

  defp filter_fields(_), do: []

  @doc """
  Infers the result category. `resolve` returns the declared type of a field path
  or `:unknown` when the path cannot be typed here (for example across an
  association); unknown operands are not rejected by inference.
  """
  def infer(expression, resolve) do
    {:ok, infer!(expression, resolve)}
  catch
    {:type_error, message} -> {:error, message}
  end

  defp infer!(["field", path], resolve), do: category(resolve.(path))
  defp infer!(["literal", _value, type], _resolve), do: category(type)

  defp infer!(["coalesce" | values], resolve),
    do: common(Enum.map(values, &infer!(&1, resolve)), "coalesce")

  defp infer!([op, left, right], resolve) when op in @arithmetic do
    categories = [infer!(left, resolve), infer!(right, resolve)]

    Enum.each(categories, fn category ->
      unless category in [:integer, :decimal, :unknown],
        do: throw({:type_error, "#{op} requires numeric operands, found #{category}"})
    end)

    cond do
      op == "divide" -> :decimal
      :decimal in categories -> :decimal
      :unknown in categories -> :unknown
      true -> :integer
    end
  end

  defp infer!([op, value], resolve) when op in @case_functions do
    category = infer!(value, resolve)

    unless category in [:string, :unknown],
      do: throw({:type_error, "#{op} requires a string, found #{category}"})

    :string
  end

  defp infer!(["concat" | values], resolve) do
    Enum.each(values, &infer!(&1, resolve))
    :string
  end

  defp infer!(["cast", value, type], resolve) do
    infer!(value, resolve)
    category(type)
  end

  defp infer!(["json_text", path, _segments], resolve) do
    category = category(resolve.(path))

    unless category in [:json, :unknown],
      do: throw({:type_error, "json_text requires a JSON field, found #{category}"})

    :string
  end

  defp infer!(["case" | branches], resolve) do
    branches
    |> Enum.map(fn
      ["else", value] -> infer!(value, resolve)
      [_condition, value] -> infer!(value, resolve)
    end)
    |> common("case")
  end

  defp common(categories, label) do
    known = categories |> Enum.reject(&(&1 == :unknown)) |> Enum.uniq()

    case known do
      [] ->
        :unknown

      [single] ->
        single

      pair ->
        if Enum.sort(pair) == [:decimal, :integer], do: :decimal, else: mismatch(label, pair)
    end
  end

  defp mismatch(label, categories),
    do:
      throw(
        {:type_error,
         "#{label} values must share one type, found #{Enum.map_join(categories, ", ", &to_string/1)}"}
      )

  @doc "Whether an inferred category satisfies a declared column type."
  def compatible?(_declared, :unknown), do: true

  def compatible?(declared, inferred) do
    expected = category(declared)
    expected == inferred or (expected == :decimal and inferred == :integer)
  end

  @doc "Maps a declared column type onto a value-expression category."
  def category(nil), do: :unknown
  def category(:unknown), do: :unknown

  def category(type) do
    case type |> to_string() |> String.downcase() do
      t when t in ~w(string text varchar char citext uuid) -> :string
      t when t in ~w(integer int bigint smallint) -> :integer
      t when t in ~w(decimal numeric float double real money) -> :decimal
      "boolean" -> :boolean
      "date" -> :date
      t when t in ~w(utc_datetime datetime naive_datetime timestamp timestamptz) -> :datetime
      t when t in ~w(jsonb json) -> :json
      _ -> :other
    end
  end

  defp inferred_literal_type(value) when is_integer(value), do: "integer"
  defp inferred_literal_type(value) when is_float(value), do: "decimal"
  defp inferred_literal_type(value) when is_boolean(value), do: "boolean"

  defp inferred_literal_type(value) when is_binary(value) do
    cond do
      value =~ ~r/\A-?\d+\z/ -> "integer"
      value =~ ~r/\A-?\d+\.\d+\z/ -> "decimal"
      true -> "string"
    end
  end

  @doc "Adapter-owned PostgreSQL cast targets for value-expression types."
  def postgres_type("string"), do: "TEXT"
  def postgres_type("integer"), do: "BIGINT"
  def postgres_type("decimal"), do: "NUMERIC"
  def postgres_type("boolean"), do: "BOOLEAN"
  def postgres_type("date"), do: "DATE"
  def postgres_type("utc_datetime"), do: "TIMESTAMPTZ"
end
