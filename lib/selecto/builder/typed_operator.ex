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
  # varchar, the type itself otherwise), schema-qualified. IN and NOT IN are
  # disjunctions of equalities, BETWEEN a pair of bounds, IN (subquery)
  # = ANY (subquery).
  #
  # An operand whose type is not known here (a computed field, a coalesce, an
  # aggregate) renders the plain form: the adapter's last step
  # (SelectoDBPostgreSQL.Qualify) types it by query scope, or refuses it. It
  # is never defaulted to pg_catalog's operator, which would turn a citext
  # comparison into a text one (R49c). Without loaded types (compile-only
  # SQL, other adapters) every function here renders the plain form,
  # unchanged.

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
      not enabled?(selecto) or op == nil or type == nil ->
        plain(left, operator, operand(selecto, operator, right), opts)

      true ->
        {schema, arg} = type
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

  @doc """
  The {schema, arg} of `column` read through a compile alias: the root
  (`selecto_root`) or a join name, mapped to its relation's table.
  """
  def alias_type(selecto, alias, column) do
    table =
      if to_string(alias) == "selecto_root" do
        selecto |> Map.get(:domain, %{}) |> Map.get(:source, %{}) |> Map.get(:source_table)
      else
        selecto
        |> Map.get(:config, %{})
        |> Map.get(:joins, %{})
        |> Enum.find_value(fn {name, join} ->
          if to_string(name) == to_string(alias), do: Map.get(join, :source)
        end)
      end

    if table, do: column_type(selecto, table, column), else: nil
  end

  @doc """
  A key pairing between two aliases (a join, scope key or tenant pair):
  plain or exact (MySQL) through ExactCompare when `mode` asks for it,
  else each column's own operator types (both citext: citext's operator;
  mixed: pg_catalog's, as native resolution would choose).
  """
  def eq_aliases(
        selecto,
        {left_alias, left_column, left},
        {right_alias, right_column, right},
        mode
      ) do
    if mode in [false, nil] and enabled?(selecto) do
      compare_columns(
        selecto,
        alias_type(selecto, left_alias, left_column),
        left,
        "=",
        alias_type(selecto, right_alias, right_column),
        right
      )
    else
      ExactCompare.eq(left, right, mode)
    end
  end

  @doc "Two typed operands (a join or column-to-column comparison)."
  def compare_columns(selecto, left_type, left, operator, right_type, right) do
    op = normalize(operator)

    if enabled?(selecto) and op != nil and left_type != nil and right_type != nil do
      {left_schema, left_arg} = left_type
      {right_schema, right_arg} = right_type

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
    if enabled?(selecto) and type != nil do
      equalities =
        rights
        |> Enum.map(&compare(selecto, type, left, "=", &1))
        |> Enum.intersperse(" OR ")

      [" ", if(negate?, do: "NOT ", else: ""), "(", equalities, ") "]
    else
      operator = if negate?, do: " NOT IN (", else: " IN ("
      rights = Enum.map(rights, &operand(selecto, "=", &1))
      [" ", left, operator, Enum.intersperse(rights, ", "), ") "]
    end
  end

  @doc """
  left op ANY|ALL (subquery); `fragment` is the parenthesised subquery.
  `plain` is the form rendered without explicit operators.
  """
  def subquery(selecto, type, left, operator, quantifier, fragment, plain) do
    op = normalize(operator)

    if enabled?(selecto) and op != nil and type != nil do
      {schema, arg} = type

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
        typed_fragment(schema, arg, fragment),
        ") "
      ]
    else
      plain
    end
  end

  @doc "left = ANY(array param) / NOT (left = ANY(array param))."
  def any_array(selecto, type, left, param, negate?) do
    if enabled?(selecto) and type != nil do
      {schema, arg} = type
      param = if arg == "pg_catalog.uuid", do: uuid_array(param), else: param
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
    if enabled?(selecto) and type != nil do
      [
        " (",
        compare(selecto, type, left, ">=", low),
        " AND ",
        compare(selecto, type, left, "<=", high),
        ") "
      ]
    else
      [
        " ",
        left,
        " between ",
        operand(selecto, ">=", low),
        " and ",
        operand(selecto, "<=", high),
        " "
      ]
    end
  end

  @equality ["=", "!=", "<>"]
  @range ["<", "<=", ">", ">="]

  @doc false
  # A Decimal param in a comparison Selecto generates, rendered as the
  # adapter compares it exactly for that operator class
  # (comparison_operand/2: MySQL wraps it for range comparisons only, MariaDB
  # for every comparison). Host text and host markers are never touched.
  def operand(selecto, operator, {:param, %Decimal{}} = param) do
    adapter = Map.get(selecto || %{}, :adapter)

    class =
      cond do
        operator in @equality -> :equality
        operator in @range -> :range
        true -> nil
      end

    if class && Selecto.AdapterSupport.callback_available?(adapter, :comparison_operand, 2),
      do: adapter.comparison_operand(param, class),
      else: param
  end

  def operand(_selecto, _operator, right), do: right

  # R50: an operator in an extension's schema (commonly writable) takes
  # operands cast to the member's own type, the subquery's column included,
  # so nothing planted beside it over a domain can be chosen.
  defp typed_fragment("pg_catalog", _arg, fragment), do: fragment

  defp typed_fragment(_schema, arg, fragment),
    do: ["(SELECT CAST(selecto_q.v AS ", arg, ") FROM ", fragment, " AS selecto_q(v))"]

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

  defp cast(operand, "pg_catalog.uuid" = arg),
    do: ["CAST(", uuid_param(operand), " AS ", arg, ")"]

  defp cast(operand, arg), do: ["CAST(", operand, " AS ", arg, ")"]

  defp uuid_array({:param, values}) when is_list(values),
    do: {:param, Enum.map(values, &if(is_binary(&1), do: uuid_value(&1), else: &1))}

  defp uuid_array(param), do: param

  # A uuid parameter is bound as the driver encodes it, whatever the field's
  # declared type: text that is no uuid refuses, typed.
  defp uuid_param({:param, value}) when is_binary(value), do: {:param, uuid_value(value)}
  defp uuid_param([{:param, _value} = param]), do: [uuid_param(param)]
  defp uuid_param(operand), do: operand

  defp uuid_value(value) when byte_size(value) == 16, do: value

  defp uuid_value(value) do
    UUID.string_to_binary!(value)
  rescue
    ArgumentError ->
      raise Selecto.Builder.ScopeRefusal,
        message: "a value compared with a uuid column is not a uuid",
        reason: :invalid_uuid
  end

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
