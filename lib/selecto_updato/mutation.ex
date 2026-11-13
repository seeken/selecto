defmodule SelectoUpdato.Mutation do
  @moduledoc """
  Closed, portable write expressions. Operands are bound data, never SQL.

  Expressions may read declared root fields on updates. Inserts and upserts
  may use literal expressions only. Trees have at most 32 levels, 256 nodes,
  and 16 coalesce operands. The governed compiler validates types and ownership.
  """

  alias Selecto.Domain.Contract.Shared.Core
  alias SelectoUpdato.Error

  @enforce_keys [:node]
  defstruct [:node]

  def null(type), do: %__MODULE__{node: {:null, type}}

  def literal(value) do
    if literal_type(value, :string) == :unsupported,
      do: raise(ArgumentError, "Mutation literals must be scalar data"),
      else: %__MODULE__{node: {:literal, value}}
  end

  def field(name), do: %__MODULE__{node: {:field, name}}
  def add(left, right), do: binary(:add, left, right)
  def subtract(left, right), do: binary(:subtract, left, right)
  def multiply(left, right), do: binary(:multiply, left, right)
  def divide(left, right), do: binary(:divide, left, right)
  def increment(name, amount \\ 1), do: add(field(name), amount)
  def decrement(name, amount \\ 1), do: subtract(field(name), amount)
  def coalesce(values), do: %__MODULE__{node: {:coalesce, Enum.map(values, &operand/1)}}

  def expression?(%__MODULE__{}), do: true
  def expression?(%{"$mutation" => _}), do: true
  def expression?(_), do: false

  @doc false
  def input(%__MODULE__{node: {:literal, value}})
      when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value),
      do: value

  def input(%__MODULE__{node: {:literal, %Decimal{} = value}}), do: value

  def input(%{"$mutation" => "literal", "value" => value} = node)
      when map_size(node) == 2 and
             (is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value)),
      do: value

  def input(value), do: value

  @doc false
  def assignment(value, operation, contract, target) do
    if expression?(value) do
      fields = Core.relation_fields(contract.source)
      columns = Core.map_value(contract.source, :columns) || %{}

      types =
        Map.new(columns, fn {field, spec} ->
          {to_string(field), category(Core.map_value(spec, :type))}
        end)

      target_type = Map.get(types, target, :unsupported)

      with {:ok, ast, type, _count} <- parse(value, operation, fields, types, target_type, 0, 0),
           true <- compatible?(type, target_type) do
        case ast do
          {:literal, literal, _type} when not is_nil(literal) -> {:ok, {:literal, literal}}
          _ -> {:ok, {:mutation, ast}}
        end
      else
        {:error, _} = error -> error
        _ -> invalid("Mutation result does not match its target field type")
      end
    else
      {:ok, {:literal, value}}
    end
  end

  @doc false
  def input_value({:literal, value}), do: value
  def input_value({:mutation, ast}), do: %__MODULE__{node: untyped(ast)}

  defp binary(kind, left, right), do: %__MODULE__{node: {kind, [operand(left), operand(right)]}}
  defp operand(%__MODULE__{} = value), do: value
  defp operand(%{"$mutation" => _} = value), do: value
  defp operand(value), do: literal(value)

  defp parse(_node, _operation, _fields, _types, _target, depth, count)
       when depth >= 32 or count >= 256,
       do: invalid("Mutation expression exceeds its depth or node bound")

  defp parse(%__MODULE__{node: node}, operation, fields, types, target, depth, count),
    do: parse_node(node, operation, fields, types, target, depth, count + 1)

  defp parse(%{"$mutation" => kind} = map, operation, fields, types, target, depth, count) do
    node =
      case {kind, Map.keys(map) |> Enum.sort()} do
        {"literal", ["$mutation", "value"]} -> {:literal, map["value"]}
        {"field", ["$mutation", "name"]} -> {:field, map["name"]}
        {kind, ["$mutation", "args"]} -> {operator(kind), map["args"]}
        _ -> :invalid
      end

    parse_node(node, operation, fields, types, target, depth, count + 1)
  end

  defp parse(value, operation, fields, types, target, depth, count),
    do: parse_node({:literal, value}, operation, fields, types, target, depth, count + 1)

  defp parse_node({:null, declared}, _operation, _fields, _types, _target, _depth, count) do
    type = category(declared)

    if type == :unsupported,
      do: invalid("Typed NULL requires a supported scalar type"),
      else: {:ok, {:literal, nil, type}, type, count}
  end

  defp parse_node({:literal, value}, _operation, _fields, _types, target, _depth, count) do
    type = literal_type(value, target)

    if type == :unsupported,
      do: invalid("Mutation literals must be scalar data"),
      else: {:ok, {:literal, value, type}, type, count}
  end

  defp parse_node({:field, name}, operation, fields, types, _target, _depth, count) do
    cond do
      not (is_atom(name) or is_binary(name)) ->
        invalid("Mutation field must be a root identifier")

      not Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, to_string(name)) ->
        invalid("Mutation field must be a root identifier")

      to_string(name) not in fields ->
        {:error,
         Error.new(:unknown_field, "Mutation source field is not declared",
           details: %{field: name}
         )}

      operation != :update ->
        invalid("Mutation field references require an update")

      Map.get(types, to_string(name), :unsupported) == :unsupported ->
        invalid("Mutation source field has an unsupported type")

      true ->
        type = Map.fetch!(types, to_string(name))
        {:ok, {:field, to_string(name), type}, type, count}
    end
  end

  defp parse_node({kind, args}, operation, fields, types, target, depth, count)
       when kind in [:add, :subtract, :multiply, :divide, :coalesce] and is_list(args) do
    valid_size = if kind == :coalesce, do: length(args) in 2..16, else: length(args) == 2

    if valid_size do
      Enum.reduce_while(args, {:ok, [], [], count}, fn value, {:ok, asts, categories, next} ->
        case parse(value, operation, fields, types, target, depth + 1, next) do
          {:ok, ast, type, nodes} -> {:cont, {:ok, asts ++ [ast], categories ++ [type], nodes}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, asts, categories, nodes} ->
          type = common(categories)

          if type != :unsupported and (kind == :coalesce or type in [:integer, :decimal]),
            do: {:ok, {kind, asts, type}, type, nodes},
            else: invalid("Mutation operands have incompatible types")

        error ->
          error
      end
    else
      invalid("Mutation operator has invalid operand count")
    end
  end

  defp parse_node(_node, _operation, _fields, _types, _target, _depth, _count),
    do: invalid("Unsupported mutation operator; DEFAULT and SQL fragments are unavailable")

  defp operator("add"), do: :add
  defp operator("subtract"), do: :subtract
  defp operator("multiply"), do: :multiply
  defp operator("divide"), do: :divide
  defp operator("coalesce"), do: :coalesce
  defp operator(_), do: :invalid

  defp untyped({kind, value, _type}) when kind in [:literal, :field], do: {kind, value}
  defp untyped({kind, args, _type}), do: {kind, Enum.map(args, &%__MODULE__{node: untyped(&1)})}

  defp literal_type(nil, type), do: type
  defp literal_type(value, _) when is_integer(value), do: :integer
  defp literal_type(value, _) when is_float(value), do: :decimal
  defp literal_type(%Decimal{}, _), do: :decimal
  defp literal_type(value, _) when is_binary(value), do: :string
  defp literal_type(value, _) when is_boolean(value), do: :boolean
  defp literal_type(_, _), do: :unsupported

  defp category(type) when type in [:integer, "integer", :id, "id", :bigint, "bigint"],
    do: :integer

  defp category(type) when type in [:decimal, "decimal", :float, "float", :numeric, "numeric"],
    do: :decimal

  defp category(type) when type in [:string, "string", :text, "text", :uuid, "uuid"], do: :string
  defp category(type) when type in [:boolean, "boolean"], do: :boolean
  defp category(_), do: :unsupported

  defp common(types) do
    cond do
      Enum.all?(types, &(&1 == hd(types))) -> hd(types)
      Enum.all?(types, &(&1 in [:integer, :decimal])) -> :decimal
      true -> :unsupported
    end
  end

  defp compatible?(type, target),
    do: type == target or (type in [:integer, :decimal] and target in [:integer, :decimal])

  defp invalid(message),
    do: {:error, Error.new(:invalid_write, message, details: %{code: :invalid_write})}
end
