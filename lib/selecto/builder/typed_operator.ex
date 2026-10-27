defmodule Selecto.Builder.TypedOperator do
  @moduledoc false

  # Explicit operators (ruling R46 FINAL-2). On an adapter that loads the
  # catalog operator types of a read's columns (`:pg_operator_types`, from
  # PostgreSQL's prepare_read/2), every generated comparison and pattern is
  # written as
  #
  #     (CAST(left AS arg) OPERATOR(schema.op) CAST(right AS arg))
  #
  # so no operator or implicit cast is looked up by name: `schema` is
  # pg_catalog for built-in, domain, enum, range, array and composite types,
  # and the type's own schema for an extension or user base type (citext);
  # `arg` is the operator's argument type (a domain's base type, text for
  # varchar, the type itself otherwise), schema-qualified. An operand whose
  # type is not known still names pg_catalog's operator. IN and NOT IN are
  # disjunctions of equalities, BETWEEN a pair of bounds, IN (subquery)
  # = ANY (subquery).
  #
  # Without loaded types (compile-only SQL, other adapters) every function
  # here renders the plain form, unchanged.

  alias Selecto.Builder.ExactCompare

  @operators %{
    "=" => "=",
    "==" => "=",
    "!=" => "<>",
    "<>" => "<>",
    "<" => "<",
    "<=" => "<=",
    ">" => ">",
    ">=" => ">=",
    "like" => "~~",
    "not like" => "!~~",
    "ilike" => "~~*",
    "not ilike" => "!~~*"
  }

  @doc "Whether explicit operators are in effect for this compile."
  def enabled?(selecto), do: is_map(types(selecto))

  @doc "The {schema, arg} of a field's column, or nil."
  def field_type(selecto, conf, field) do
    with %{} = types <- types(selecto),
         true <- is_map(conf),
         false <- computed?(conf),
         table when not is_nil(table) <- ExactCompare.field_relation(selecto, conf),
         {:ok, columns} <- Map.fetch(types, to_string(table)),
         {:ok, type} <- Map.fetch(columns, column_name(conf, field)) do
      type
    else
      _ -> nil
    end
  end

  @doc "The {schema, arg} of a relation's column, or nil."
  def column_type(selecto, table, column) do
    with %{} = types <- types(selecto),
         {:ok, columns} <- Map.fetch(types, to_string(table)),
         {:ok, type} <- Map.fetch(columns, to_string(column)) do
      type
    else
      _ -> nil
    end
  end

  @doc """
  `left op right` for a field. `opts`: `escape:` the LIKE escape character.
  """
  def compare(selecto, type, left, operator, right, opts \\ []) do
    op = normalize(operator)

    cond do
      not enabled?(selecto) or op == nil ->
        plain(left, operator, right, opts)

      true ->
        {schema, arg} = type || {"pg_catalog", nil}
        right = pattern_right(op, right, Keyword.get(opts, :escape))

        [
          " (",
          cast(left, arg),
          " OPERATOR(",
          schema,
          ".",
          op,
          ") ",
          cast(right, arg),
          ") "
        ]
    end
  end

  @doc "Two typed operands (a join or column-to-column comparison)."
  def compare_columns(selecto, left_type, left, operator, right_type, right) do
    op = normalize(operator)

    if enabled?(selecto) and op != nil do
      {left_schema, left_arg} = left_type || {"pg_catalog", nil}
      {right_schema, right_arg} = right_type || {"pg_catalog", nil}

      {schema, left_arg, right_arg} =
        if left_schema == right_schema,
          do: {left_schema, left_arg, right_arg},
          else: {"pg_catalog", left_arg, right_arg}

      [
        " (",
        cast(left, left_arg),
        " OPERATOR(",
        schema,
        ".",
        op,
        ") ",
        cast(right, right_arg),
        ") "
      ]
    else
      [" ", left, " ", operator, " ", right, " "]
    end
  end

  @doc "IN / NOT IN over parameter values (each an iodata right operand)."
  def in_list(selecto, type, left, rights, negate?) do
    if enabled?(selecto) do
      equalities =
        rights
        |> Enum.map(&compare(selecto, type, left, "=", &1))
        |> Enum.intersperse(" OR ")

      [" ", if(negate?, do: "NOT ", else: ""), "(", equalities, ") "]
    else
      operator = if negate?, do: " NOT IN (", else: " IN ("
      [" ", left, operator, Enum.intersperse(rights, ", "), ") "]
    end
  end

  @doc """
  left op ANY|ALL (subquery); `fragment` is the parenthesised subquery.
  `plain` is the form rendered without explicit operators.
  """
  def subquery(selecto, type, left, operator, quantifier, fragment, plain) do
    op = normalize(operator)

    if enabled?(selecto) and op != nil do
      {schema, arg} = type || {"pg_catalog", nil}

      [
        " (",
        cast(left, arg),
        " OPERATOR(",
        schema,
        ".",
        op,
        ") ",
        quantifier,
        " ",
        fragment,
        ") "
      ]
    else
      plain
    end
  end

  @doc "left = ANY(array param) / NOT (left = ANY(array param))."
  def any_array(selecto, type, left, param, negate?) do
    if enabled?(selecto) do
      {schema, arg} = type || {"pg_catalog", nil}
      array = if arg, do: ["CAST(", param, " AS ", arg, "[])"], else: param
      clause = ["(", cast(left, arg), " OPERATOR(", schema, ".=) ANY (", array, "))"]
      if negate?, do: [" NOT ", clause, " "], else: [" ", clause, " "]
    else
      if negate?,
        do: [" NOT (", left, " = ANY(", param, ")) "],
        else: [" ", left, " = ANY(", param, ") "]
    end
  end

  @doc "left BETWEEN low AND high (both inclusive)."
  def between(selecto, type, left, low, high) do
    if enabled?(selecto) do
      [
        " (",
        compare(selecto, type, left, ">=", low),
        " AND ",
        compare(selecto, type, left, "<=", high),
        ") "
      ]
    else
      [" ", left, " between ", low, " and ", high, " "]
    end
  end

  defp plain(left, operator, right, opts) do
    case Keyword.get(opts, :escape) do
      nil -> [" ", left, " ", operator, " ", right, " "]
      escape -> [" ", left, " ", operator, " ", right, " ESCAPE '", escape, "' "]
    end
  end

  # LIKE's ESCAPE clause has no operator form: the pattern is rewritten
  # with pg_catalog.like_escape first.
  defp pattern_right(op, right, escape)
       when op in ["~~", "!~~", "~~*", "!~~*"] and is_binary(escape),
       do: ["pg_catalog.like_escape(CAST(", right, " AS pg_catalog.text), '", escape, "')"]

  defp pattern_right(_op, right, _escape), do: right

  defp cast(operand, nil), do: operand
  defp cast(operand, arg), do: ["CAST(", operand, " AS ", arg, ")"]

  defp normalize(operator),
    do: Map.get(@operators, operator |> to_string() |> String.trim() |> String.downcase())

  defp types(selecto) when is_map(selecto) do
    case Map.get(ExactCompare.storage_set(selecto) || %{}, :pg_operator_types) do
      %{} = types -> types
      _ -> nil
    end
  end

  # No selecto (a builder that only has its operands): the compile's
  # storage context.
  defp types(nil) do
    case Map.get(ExactCompare.storage_set(%{}), :pg_operator_types) do
      %{} = types -> types
      _ -> nil
    end
  end

  defp types(_selecto), do: nil

  defp computed?(conf),
    do:
      match?({tag, _} when tag in [:computed_value, :computed_predicate], Map.get(conf, :select))

  defp column_name(conf, field),
    do: conf |> Map.get(:field) |> Kernel.||(field) |> to_string()
end
