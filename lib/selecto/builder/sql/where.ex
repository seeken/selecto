defmodule Selecto.Builder.Sql.Where do
  @moduledoc """
  WHERE-clause compiler for Selecto predicate expressions.

  Predicates are translated into iodata fragments plus bind parameters and join
  dependencies. The builder supports nested boolean logic, comparison operators,
  NULL checks, ranges, text search, subqueries, EXISTS clauses, JSON predicates,
  and raw prebuilt filter fragments.
  """

  import Selecto.Builder.Sql.Helpers

  @or_to_membership 64

  alias Selecto.AdapterSQL
  alias Selecto.AdapterSupport
  alias Selecto.Builder.ExactCompare
  alias Selecto.Builder.TypedOperator
  alias Selecto.Builder.Sql.Select
  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation
  alias Selecto.Dialect.Text.Normalization, as: TextNormalization
  alias Selecto.Dialect.Predicate.Comparison
  alias Selecto.Error
  alias Selecto.Json

  # Predicate formats supported:
  #   {SELECTOR} # for boolean fields
  #   {SELECTOR, nil} #is null
  #   {SELECTOR, :not_nil} #is not null
  #   {SELECTOR, SELECTOR} #=
  #   {SELECTOR, [SELECTOR2, ...]}# in ()
  #   {SELECTOR, {comp, SELECTOR2}} #<= etc
  #   {SELECTOR, {:between, SELECTOR2, SELECTOR2}
  #   {:not, PREDICATE}
  #   {:and, [PREDICATES]}
  #   {:or, [PREDICATES]}
  #   {SELECTOR, :in, SUBQUERY}
  #   {SELECTOR, comp, {:subquery, :any, SUBQUERY}}  ## Or :all
  #   {:exists, SUBQUERY}

  # Extract the actual database field name from the field reference or configuration
  defp extract_database_field(field, conf) do
    case field do
      # For joined fields like "category.updated_at"
      field_str when is_binary(field_str) ->
        if String.contains?(field_str, ".") do
          # Extract just the field name from "table.field" format
          String.split(field_str, ".") |> List.last()
        else
          # Use field from conf or fallback to the field string itself
          Map.get(conf, :field, field_str)
        end

      # For atom fields
      field_atom when is_atom(field_atom) ->
        Map.get(conf, :field, Atom.to_string(field_atom))

      # Default case
      _ ->
        Map.get(conf, :field, to_string(field))
    end
  end

  # Every filter of a compile, nested ones too, passes here: the node count
  # a read is bounded by.
  def build(selecto, filter) do
    Selecto.Builder.Provenance.count_filter()
    do_build(selecto, filter)
  end

  # Handle CASE expressions in WHERE clause
  defp do_build(selecto, {field, {:instant_compare, operation, decimal}}) do
    # Revalidate manually constructed tuples as well as Expr helpers. The
    # governed field remains visible to normal policy and join resolution.
    Selecto.Expr.instant_compare(field, operation, decimal)
    conf = field_conf(selecto, field)
    type = Map.get(conf, :type) |> to_string()

    unless type in ~w(utc_datetime timestamptz epoch_datetime) and
             is_nil(Selecto.Temporal.epoch_storage(conf)),
           do:
             raise(
               ArgumentError,
               "Exact comparison requires an instant field with supported storage"
             )

    storage = Map.get(conf, :storage)

    unless storage in [nil, :naive_utc, "naive_utc"],
      do: raise(ArgumentError, "Unsupported instant storage")

    {selector, joins, params} = Select.prep_selector(selecto, field)

    fragment = %Selecto.Dialect.Instant.Comparison{
      operation: operation,
      expression: selector,
      value: {:param, decimal},
      source_type: String.to_existing_atom(type),
      storage: if(is_nil(storage), do: nil, else: :naive_utc)
    }

    case Selecto.DialectSupport.render_instant_comparison(selecto.adapter, fragment, selecto) do
      {:ok, rendered} ->
        {List.wrap(conf.requires_join) ++ List.wrap(joins), [" ", rendered, " "], params}

      {:error, %Error{} = error} ->
        Selecto.Builder.ScopeRefusal.unsupported!(error)

      {:error, _} ->
        raise ArgumentError, "Unsupported exact instant comparison"
    end
  end

  defp do_build(selecto, {:case, when_clauses, else_clause}) when is_list(when_clauses) do
    {case_iodata, joins, params} = build_case_expression(selecto, when_clauses, else_clause)
    {joins, [" ", case_iodata, " "], params}
  end

  defp do_build(selecto, {:case, when_clauses}) when is_list(when_clauses) do
    build(selecto, {:case, when_clauses, nil})
  end

  defp do_build(selecto, {:udf, function_id, args}) when is_list(args) do
    {selector_iodata, joins, params} = Select.build_udf(selecto, function_id, args, :filter)
    {List.wrap(joins), [" ", selector_iodata, " "], params}
  end

  defp do_build(selecto, {fields, {:text_search, value}})
       when is_list(fields) and not is_list(value) do
    build_text_search(selecto, fields, value)
  end

  defp do_build(selecto, {fields, {:text_search, opts}}) when is_list(fields) and is_list(opts) do
    {resolved_fields, value, text_search_opts} = normalize_text_search_spec(fields, opts)
    build_text_search(selecto, resolved_fields, value, text_search_opts)
  end

  defp do_build(selecto, {fields, {:text_search, value, opts}})
       when is_list(fields) and is_list(opts) do
    build_text_search(selecto, fields, value, opts)
  end

  defp do_build(selecto, {field, {:text_search, opts}}) when is_list(opts) do
    {resolved_fields, value, text_search_opts} = normalize_text_search_spec([field], opts)
    build_text_search(selecto, resolved_fields, value, text_search_opts)
  end

  defp do_build(selecto, {field, {:text_search, value}}) when not is_list(value) do
    build_text_search(selecto, [field], value)
  end

  defp do_build(selecto, {field, {:text_search, value, opts}}) when is_list(opts) do
    build_text_search(selecto, [field], value, opts)
  end

  defp do_build(selecto, {field, {:subquery, :in, %Selecto{} = query_selecto}}) do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)
    query_iodata = selecto_subquery_to_iodata(query_selecto)

    {List.wrap(conf.requires_join) ++ List.wrap(join),
     in_subquery_clause(selecto, conf, field, sel, in_subquery_fragment(query_iodata), fn mode ->
       exact_subquery_iodata(query_selecto, mode)
     end), param}
  end

  defp do_build(selecto, {field, {:subquery, :in, query, params}}) do
    Selecto.Builder.Provenance.mark()
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)
    query_iodata = Selecto.SQL.Params.rebind_finalized(query, params, selecto.adapter)

    {List.wrap(conf.requires_join) ++ List.wrap(join),
     in_subquery_clause(selecto, conf, field, sel, in_subquery_fragment(query_iodata), nil),
     param ++ params}
  end

  defp do_build(selecto, {field, {:subquery, :in, query}}) do
    Selecto.Builder.Provenance.mark()
    query = verbatim_fragment(selecto, query)
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)

    {List.wrap(conf.requires_join) ++ List.wrap(join),
     in_subquery_clause(selecto, conf, field, sel, in_subquery_fragment(query), nil), param}
  end

  defp do_build(selecto, {field, comp, {:subquery, agg, %Selecto{} = query_selecto}})
       when agg in [:any, :all] do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)
    query_iodata = selecto_subquery_to_iodata(query_selecto)
    operator = subquery_operator!(comp)

    {List.wrap(conf.requires_join) ++ List.wrap(join),
     TypedOperator.subquery(
       selecto,
       TypedOperator.field_type(selecto, conf, field),
       sel,
       operator,
       to_string(agg),
       ["(", query_iodata, ")"],
       [" ", sel, " ", operator, " ", to_string(agg), " (", query_iodata, ") "]
     ), param}
  end

  defp do_build(selecto, {field, comp, {:subquery, agg, query, params}})
       when agg in [:any, :all] do
    Selecto.Builder.Provenance.mark()
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)
    query_iodata = Selecto.SQL.Params.rebind_finalized(query, params, selecto.adapter)
    operator = subquery_operator!(comp)

    {List.wrap(conf.requires_join) ++ List.wrap(join),
     TypedOperator.subquery(
       selecto,
       TypedOperator.field_type(selecto, conf, field),
       sel,
       operator,
       to_string(agg),
       ["(", query_iodata, ")"],
       [" ", sel, " ", operator, " ", to_string(agg), " (", query_iodata, ") "]
     ), param ++ params}
  end

  defp do_build(selecto, {field, comp, {:subquery, agg, query}}) when agg in [:any, :all] do
    Selecto.Builder.Provenance.mark()
    query = verbatim_fragment(selecto, query)
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)
    operator = subquery_operator!(comp)

    {List.wrap(conf.requires_join) ++ List.wrap(join),
     TypedOperator.subquery(
       selecto,
       TypedOperator.field_type(selecto, conf, field),
       sel,
       operator,
       to_string(agg),
       ["(", query, ")"],
       [" ", sel, " ", operator, " ", to_string(agg), " (", query, ") "]
     ), param}
  end

  defp do_build(_selecto, {:exists, %Selecto{} = query_selecto}) do
    query_iodata = selecto_subquery_to_iodata(query_selecto)
    {[], [" exists (", query_iodata, ") "], []}
  end

  defp do_build(selecto, {:exists, query, params}) do
    Selecto.Builder.Provenance.mark()
    query_iodata = Selecto.SQL.Params.rebind_finalized(query, params, selecto.adapter)
    {[], [" exists (", query_iodata, ") "], params}
  end

  defp do_build(selecto, {:exists, query}) do
    Selecto.Builder.Provenance.mark()
    {[], [" exists (", verbatim_fragment(selecto, query), ") "], []}
  end

  # A scope filter (marked by provenance in Selecto.Builder.Sql): its
  # comparisons, and those of the computed columns it names, compile as
  # scope.
  defp do_build(selecto, {:selecto_scope, filter}),
    do: ExactCompare.in_scope(fn -> build(selecto, filter) end)

  defp do_build(selecto, {:not, filter}) do
    {j, c, p} = build(selecto, filter)
    {j, ["not ( ", c, " ) "], p}
  end

  # Many equalities of one field are one membership: one parameter array, not
  # a term each, for the compiler and every adapter after it.
  defp do_build(selecto, {:or, filters})
       when is_list(filters) and length(filters) >= @or_to_membership do
    case same_field_scalars(filters) do
      {field, values} -> do_build(selecto, {field, values})
      nil -> build_conjunction(selecto, :or, filters)
    end
  end

  defp do_build(selecto, {conj, filters}) when conj in [:and, :or],
    do: build_conjunction(selecto, conj, filters)

  # A filter Selecto built from what it was given (retarget, JSON).
  defp do_build(selecto, {:selecto_generated, tag, filter}) do
    if Selecto.Builder.Provenance.generated_tag?(tag) do
      Selecto.Builder.Provenance.generated(fn -> do_build(selecto, filter) end)
    else
      raise ArgumentError, "selecto_generated is internal to Selecto"
    end
  end

  # Prebuilt SQL filters (used by JSON and other advanced operations).
  defp do_build(_selecto, {:raw_sql_filter, filter_iodata}) do
    Selecto.Builder.Provenance.mark()
    {[], [" ", filter_iodata, " "], []}
  end

  # The step of a depth-bounded recursive CTE stops at max_depth.
  defp do_build(selecto, {:recursion_depth_below, join_id, max_depth})
       when is_atom(join_id) and is_integer(max_depth) and max_depth > 0 do
    {[join_id],
     [
       " ",
       build_join_string(selecto, join_id),
       ".selecto_depth < ",
       Integer.to_string(max_depth),
       " "
     ], []}
  end

  defp do_build(selecto, {field, {:datetime_part, part, predicate}}) do
    build_datetime_predicate(selecto, field, :extract_part, part, predicate)
  end

  defp do_build(selecto, {field, {:datetime_format, format, predicate}}) do
    build_datetime_predicate(selecto, field, :format, nil, predicate, %{format: format})
  end

  defp do_build(selecto, {field, {:text_normalized, options, predicate}}) when is_map(options) do
    conf = field_conf(selecto, field)
    {expression, joins, params} = Select.prep_selector(selecto, field)

    fragment = %TextNormalization{
      expression: expression,
      exclude_articles: Map.get(options, :exclude_articles, []),
      ignore_case: Map.get(options, :ignore_case, true)
    }

    {rendered, dialect_params} = render_text_normalization!(selecto, fragment)

    {List.wrap(conf.requires_join) ++ List.wrap(joins),
     [" ", expression_predicate_sql(selecto, rendered, predicate), " "], params ++ dialect_params}
  end

  # Handle :between with list format [{min, max}]
  # For datetime types, use >= start AND < end for better boundary handling
  defp do_build(selecto, {field, {:between, [min, max]}}) do
    conf = field_conf(selecto, field)
    # Extract actual field name, not display name
    field_name = extract_database_field(field, conf)

    selector = build_selector_string(selecto, conf.requires_join, field_name)

    if identity = identity_between(selecto, conf, field, selector, min, max) do
      {conf.requires_join, identity, []}
    else
      if date_like_type(conf) do
        sel = build_selector_string(selecto, conf.requires_join, field_name)
        type = TypedOperator.field_type(selecto, conf, field)

        {conf.requires_join,
         [
           " (",
           TypedOperator.compare(
             selecto,
             type,
             sel,
             ">=",
             {:param, to_field_value(selecto, conf, min)}
           ),
           " and ",
           TypedOperator.compare(
             selecto,
             type,
             sel,
             "<",
             {:param, to_field_value(selecto, conf, max)}
           ),
           ") "
         ], []}
      else
        # Use standard BETWEEN for non-datetime types
        {conf.requires_join,
         TypedOperator.between(
           selecto,
           TypedOperator.field_type(selecto, conf, field),
           build_selector_string(selecto, conf.requires_join, field_name),
           {:param, to_field_value(selecto, conf, min)},
           {:param, to_field_value(selecto, conf, max)}
         ), []}
      end
    end
  end

  # Handle :between with separate bounds and structured-value dot notation.
  defp do_build(selecto, {field, {:between, min, max}}) when is_binary(field) do
    domain = selecto.config

    case Json.parse_field_reference(field, domain) do
      {:json_path, column, path} ->
        build_json_between(selecto, column, path, min, max)

      {:regular, _} ->
        build_regular_between(selecto, field, min, max)
    end
  end

  # Handle :between with separate min, max parameters
  # For datetime types, use >= start AND < end for better boundary handling
  defp do_build(selecto, {field, {:between, min, max}}) do
    build_regular_between(selecto, field, min, max)
  end

  defp do_build(selecto, {field, {:starts_with, value}}) when is_binary(value) do
    pattern = escape_like_literal(value) <> "%"
    {sel, join, param} = Select.prep_selector(selecto, field)

    {List.wrap(join), like_clause(selecto, field, sel, "LIKE", pattern, " ESCAPE '!'"), param}
  end

  defp do_build(selecto, {field, {:text_contains, value}}) when is_binary(value) do
    pattern = "%" <> escape_like_literal(value) <> "%"
    {sel, join, param} = Select.prep_selector(selecto, field)

    {List.wrap(join), like_clause(selecto, field, sel, "LIKE", pattern, " ESCAPE '!'"), param}
  end

  defp do_build(selecto, {field, {:ends_with, value}}) when is_binary(value) do
    pattern = "%" <> escape_like_literal(value)
    {sel, join, param} = Select.prep_selector(selecto, field)

    {List.wrap(join), like_clause(selecto, field, sel, "LIKE", pattern, " ESCAPE '!'"), param}
  end

  defp do_build(selecto, {field, {:like, value}}) do
    # ### Value must have a % in it to work!
    {sel, join, param} = Select.prep_selector(selecto, field)
    {List.wrap(join), like_clause(selecto, field, sel, "LIKE", value, ""), param}
  end

  defp do_build(selecto, {field, {comp, value}})
       when comp in [:case_insensitive_like, :case_insensitive_not_like] do
    refuse_timestamp_operator(selecto, field, "a case-insensitive pattern")
    {sel, join, params} = Select.prep_selector(selecto, field)

    operation =
      if comp == :case_insensitive_not_like,
        do: :case_insensitive_not_like,
        else: :case_insensitive_like

    if TypedOperator.enabled?(selecto) do
      operator = if operation == :case_insensitive_not_like, do: "NOT ILIKE", else: "ILIKE"
      type = TypedOperator.field_type(selecto, safe_field_conf(selecto, field), field)

      {List.wrap(join), TypedOperator.compare(selecto, type, sel, operator, {:param, value}),
       params}
    else
      fragment = %Comparison{operation: operation, left: sel, right: {:param, value}}

      rendered = render_comparison!(selecto, fragment)
      {List.wrap(join), [" ", rendered, " "], params}
    end
  end

  defp do_build(selecto, {field, {comp, {:ref, ref_field}}})
       when comp in [:=, :!=, :<, :>, :<=, :>=, :gt, :lt, :gte, :lte, :eq, :ne] do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)
    {ref_sel, ref_join, ref_params} = Select.prep_selector(selecto, {:ref, ref_field})

    sql_op =
      case comp do
        :gt -> ">"
        :lt -> "<"
        :gte -> ">="
        :lte -> "<="
        :eq -> "="
        :ne -> "!="
        other -> to_string(other)
      end

    {List.wrap(conf.requires_join) ++ List.wrap(join) ++ List.wrap(ref_join),
     ref_comparison_clause(selecto, {conf, field, sel}, sql_op, {ref_field, ref_sel}),
     param ++ ref_params}
  end

  defp do_build(selecto, {field, {comp, {:ref, ref_field}}}) when comp in ~w[= != < > <= >=] do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)
    {ref_sel, ref_join, ref_params} = Select.prep_selector(selecto, {:ref, ref_field})

    {List.wrap(conf.requires_join) ++ List.wrap(join) ++ List.wrap(ref_join),
     ref_comparison_clause(selecto, {conf, field, sel}, comp, {ref_field, ref_sel}),
     param ++ ref_params}
  end

  defp do_build(selecto, {field, {:not_like, value}}) do
    # NOT LIKE filter - value should already have % wildcards
    {sel, join, param} = Select.prep_selector(selecto, field)
    {List.wrap(join), like_clause(selecto, field, sel, "NOT LIKE", value, ""), param}
  end

  # Structured-value path with comparison operators.
  defp do_build(selecto, {field, {comp, value}})
       when is_binary(field) and
              comp in [:gt, :lt, :gte, :lte, :eq, :ne, :=, :!=, :<, :>, :<=, :>=] do
    domain = selecto.config

    case Json.parse_field_reference(field, domain) do
      {:json_path, column, path} ->
        build_json_comparison(selecto, column, path, comp, value)

      {:regular, _} ->
        build_regular_comparison(selecto, field, comp, value)
    end
  end

  defp do_build(selecto, {field, {comp, value}})
       when comp in [:=, :!=, :<, :>, :<=, :>=, :gt, :lt, :gte, :lte, :eq, :ne] do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)

    # Convert alternative operator names to SQL operators
    sql_op =
      case comp do
        :gt -> ">"
        :lt -> "<"
        :gte -> ">="
        :lte -> "<="
        :eq -> "="
        :ne -> "!="
        other -> to_string(other)
      end

    {List.wrap(conf.requires_join) ++ List.wrap(join),
     comparison_clause(
       selecto,
       conf,
       field,
       sel,
       sql_op,
       {:param, to_field_value(selecto, conf, value)}
     ), param}
  end

  defp do_build(selecto, {field, {comp, value}}) when comp in ~w[= != < > <= >=] do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)

    {List.wrap(conf.requires_join) ++ List.wrap(join),
     comparison_clause(
       selecto,
       conf,
       field,
       sel,
       comp,
       {:param, to_field_value(selecto, conf, value)}
     ), param}
  end

  # Structured-value path with :in operator.
  defp do_build(selecto, {field, {:in, list}}) when is_binary(field) and is_list(list) do
    domain = selecto.config

    case Json.parse_field_reference(field, domain) do
      {:json_path, column, path} ->
        build_json_in(selecto, column, path, list)

      {:regular, _} ->
        conf = field_conf(selecto, field)
        {sel, join, param} = Select.prep_selector(selecto, field)
        typed_values = Enum.map(list, fn i -> to_field_value(selecto, conf, i) end)

        in_clause =
          identity_list(selecto, conf, field, sel, typed_values, false) ||
            build_list_clause(
              selecto,
              sel,
              typed_values,
              false,
              exact?(selecto, conf, field),
              TypedOperator.field_type(selecto, conf, field)
            )

        {List.wrap(conf.requires_join) ++ List.wrap(join), in_clause, param}
    end
  end

  defp do_build(selecto, {field, {:in, list}}) when is_list(list) do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)

    typed_values = Enum.map(list, fn i -> to_field_value(selecto, conf, i) end)

    in_clause =
      identity_list(selecto, conf, field, sel, typed_values, false) ||
        build_list_clause(
          selecto,
          sel,
          typed_values,
          false,
          exact?(selecto, conf, field),
          TypedOperator.field_type(selecto, conf, field)
        )

    {List.wrap(conf.requires_join) ++ List.wrap(join), in_clause, param}
  end

  defp do_build(selecto, {field, {:not_in, list}}) when is_list(list) do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)

    typed_values = Enum.map(list, fn i -> to_field_value(selecto, conf, i) end)

    not_in_clause =
      identity_list(selecto, conf, field, sel, typed_values, true) ||
        build_list_clause(
          selecto,
          sel,
          typed_values,
          true,
          exact?(selecto, conf, field),
          TypedOperator.field_type(selecto, conf, field)
        )

    {List.wrap(conf.requires_join) ++ List.wrap(join), not_in_clause, param}
  end

  defp do_build(selecto, {field, list}) when is_list(list) do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)

    typed_values = Enum.map(list, fn i -> to_field_value(selecto, conf, i) end)

    in_clause =
      identity_list(selecto, conf, field, sel, typed_values, false) ||
        build_list_clause(
          selecto,
          sel,
          typed_values,
          false,
          exact?(selecto, conf, field),
          TypedOperator.field_type(selecto, conf, field)
        )

    {List.wrap(conf.requires_join) ++ List.wrap(join), in_clause, param}
  end

  defp do_build(selecto, {field, {:not, nil}}) do
    # Handle {:not, nil} as "IS NOT NULL"
    build(selecto, {field, :not_null})
  end

  defp do_build(selecto, {field, :not_null}) do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)
    {List.wrap(conf.requires_join) ++ List.wrap(join), [" ", sel, " is not null "], param}
  end

  defp do_build(selecto, {field, value}) when is_nil(value) do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)
    {List.wrap(conf.requires_join) ++ List.wrap(join), [" ", sel, " is null "], param}
  end

  defp do_build(selecto, {field, {:ref, ref_field}}) do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)
    {ref_sel, ref_join, ref_params} = Select.prep_selector(selecto, {:ref, ref_field})

    {List.wrap(conf.requires_join) ++ List.wrap(join) ++ List.wrap(ref_join),
     ref_comparison_clause(selecto, {conf, field, sel}, "=", {ref_field, ref_sel}),
     param ++ ref_params}
  end

  # Handle array filter specifications (must come before generic {field, value})
  defp do_build(selecto, {:array_filter, spec}) do
    {sql, params} = Selecto.Advanced.ArrayOperations.to_sql(spec, [], selecto)
    {[], sql, params}
  end

  # Array contains - checks if array contains all specified elements
  defp do_build(selecto, {:array_contains, field, values}) when is_list(values) do
    {sel, join, param} = Select.prep_selector(selecto, field)

    {sql, array_params} =
      Selecto.Builder.ArrayOperations.build_filter_sql(:array_contains, sel, values, selecto)

    {List.wrap(join), [" ", sql, " "], param ++ array_params}
  end

  # Array contained - checks if array is contained by specified elements
  defp do_build(selecto, {:array_contained, field, values}) when is_list(values) do
    {sel, join, param} = Select.prep_selector(selecto, field)

    {sql, array_params} =
      Selecto.Builder.ArrayOperations.build_filter_sql(:array_contained, sel, values, selecto)

    {List.wrap(join), [" ", sql, " "], param ++ array_params}
  end

  # Array overlap - checks if arrays have any common elements
  defp do_build(selecto, {:array_overlap, field, values}) when is_list(values) do
    {sel, join, param} = Select.prep_selector(selecto, field)

    {sql, array_params} =
      Selecto.Builder.ArrayOperations.build_filter_sql(:array_overlap, sel, values, selecto)

    {List.wrap(join), [" ", sql, " "], param ++ array_params}
  end

  # Array equality - checks if arrays are equal
  defp do_build(selecto, {:array_eq, field, values}) when is_list(values) do
    {sel, join, param} = Select.prep_selector(selecto, field)

    {sql, array_params} =
      Selecto.Builder.ArrayOperations.build_filter_sql(:array_eq, sel, values, selecto)

    {List.wrap(join), [" ", sql, " "], param ++ array_params}
  end

  # ---------------------------------------------------------------------------
  # Structured JSON operations with dot notation.
  # ---------------------------------------------------------------------------

  # JSON containment.
  defp do_build(selecto, {field, {:json_contains, value}})
       when is_map(value) or is_list(value) or is_binary(value) or is_number(value) or
              is_boolean(value) or is_nil(value) do
    domain = selecto.config

    if Json.json_column?(domain, field) do
      contains =
        Json.build_contains(field, value,
          table_alias: get_root_alias(selecto),
          adapter: Map.fetch!(selecto, :adapter)
        )

      {[], [" ", contains, " "], []}
    else
      raise Error.to_exception(
              Error.validation_error("JSON containment requires a JSON column", %{
                field: field,
                unsupported_feature: :json_contains
              })
            )
    end
  end

  # JSON key/path existence.
  defp do_build(selecto, {field, :exists}) do
    domain = selecto.config

    case Json.parse_field_reference(field, domain) do
      {:json_path, column, path} when path != [] ->
        exists_expr =
          Json.build_key_exists(column, path,
            table_alias: get_root_alias(selecto),
            adapter: Map.fetch!(selecto, :adapter)
          )

        {[], [" ", exists_expr, " "], []}

      _ ->
        # A regular field uses ordinary null semantics.
        build(selecto, {field, :not_null})
    end
  end

  # JSON array membership.
  defp do_build(selecto, {field, {:contains, value}}) do
    domain = selecto.config

    case Json.parse_field_reference(field, domain) do
      {:json_path, column, path} ->
        contains_expr =
          Json.build_array_contains(column, path, value,
            table_alias: get_root_alias(selecto),
            adapter: Map.fetch!(selecto, :adapter)
          )

        {[], [" ", contains_expr, " "], []}

      {:regular, _} ->
        # Fallback to array contains for regular array columns
        build(selecto, {:array_contains, field, List.wrap(value)})
    end
  end

  # All-values JSON array membership.
  defp do_build(selecto, {field, {:contains_all, values}}) when is_list(values) do
    domain = selecto.config

    case Json.parse_field_reference(field, domain) do
      {:json_path, column, path} ->
        contains_expr =
          Json.build_array_contains_all(column, path, values,
            table_alias: get_root_alias(selecto),
            adapter: Map.fetch!(selecto, :adapter)
          )

        {[], [" ", contains_expr, " "], []}

      {:regular, _} ->
        # Fallback to array contains for regular array columns
        build(selecto, {:array_contains, field, values})
    end
  end

  # Generic field equality with structured-value dot notation.
  defp do_build(selecto, {field, value}) when is_binary(field) do
    domain = selecto.config

    case Json.parse_field_reference(field, domain) do
      {:json_path, column, path} ->
        build_json_equality(selecto, column, path, value)

      {:regular, _} ->
        conf = field_conf(selecto, field)
        {sel, join, param} = Select.prep_selector(selecto, field)

        {List.wrap(conf.requires_join) ++ List.wrap(join),
         comparison_clause(
           selecto,
           conf,
           field,
           sel,
           "=",
           {:param, to_field_value(selecto, conf, value)}
         ), param}
    end
  end

  defp do_build(selecto, {field, value}) do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)

    {List.wrap(conf.requires_join) ++ List.wrap(join),
     comparison_clause(
       selecto,
       conf,
       field,
       sel,
       "=",
       {:param, to_field_value(selecto, conf, value)}
     ), param}
  end

  defp do_build(_sel, other) do
    require Logger

    # Determine the type safely without logging the actual value (which may contain sensitive data)
    type_name =
      cond do
        is_binary(other) -> "binary"
        is_tuple(other) -> "tuple"
        is_list(other) -> "list"
        is_map(other) -> "map"
        true -> "other"
      end

    # Check if this is a bucket_ranges string that shouldn't be here
    if is_binary(other) && String.match?(other, ~r/^\d+-\d+,\d+\+$|^\d+,\d+-\d+|\d+\+/) do
      Logger.error(
        "WHERE builder received bucket_ranges string as filter (value redacted for security)"
      )

      Logger.error(
        "This likely means aggregate or group_by bucket_ranges are being incorrectly passed as filters"
      )

      raise "WHERE clause builder error: Bucket ranges string was passed as a filter. This should not happen - bucket ranges should be handled by aggregate processing, not WHERE clauses."
    end

    # Log type info only, not the actual value which may contain sensitive data
    Logger.error("WHERE builder received unrecognized filter structure of type: #{type_name}")
    Logger.error("Debug: Enable debug logging with safe inspection for more details")

    raise "WHERE clause builder error: Unrecognized filter structure (type: #{type_name}). This usually means an aggregate or filter configuration is generating an invalid filter format."
  end

  # A tenant/site column on an exact-compare adapter (MySQL, MariaDB) matches
  # its stored bytes, not its collation (Selecto.Builder.ExactCompare).
  defp build_list_clause(_selecto, selector, typed_values, negate?, mode, _type)
       when mode in [true, :bytes, :server] do
    placeholders = Enum.map(typed_values, fn value -> {:param, value} end)
    clause = ExactCompare.in_list(selector, placeholders, mode)

    if negate?, do: [" NOT ", clause, " "], else: [" ", clause, " "]
  end

  defp build_list_clause(selecto, selector, typed_values, negate?, _exact?, type) do
    if AdapterSQL.array_any_comparison?(selecto) do
      TypedOperator.any_array(selecto, type, selector, {:param, typed_values}, negate?)
    else
      TypedOperator.in_list(
        selecto,
        type,
        selector,
        Enum.map(typed_values, fn value -> {:param, value} end),
        negate?
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Structured JSON helper functions.
  # ---------------------------------------------------------------------------

  defp build_json_equality(selecto, column, path, value) do
    domain = selecto.config
    path_schema = Json.get_path_schema(domain, column, path)
    field_type = if path_schema, do: Map.get(path_schema, :type), else: nil
    cast = Json.cast_for_type(field_type)

    extraction =
      Json.build_extraction(column, path,
        as_text: true,
        table_alias: get_root_alias(selecto),
        cast: cast,
        adapter: Map.fetch!(selecto, :adapter)
      )

    # For nil values, check if the key exists and is null vs key doesn't exist
    if is_nil(value) do
      {[], [" (", extraction, " IS NULL) "], []}
    else
      {[], [" ", extraction, " = ", {:param, to_string(value)}, " "], []}
    end
  end

  defp build_json_comparison(selecto, column, path, comp, value) do
    domain = selecto.config
    path_schema = Json.get_path_schema(domain, column, path)
    field_type = if path_schema, do: Map.get(path_schema, :type), else: nil
    cast = Json.cast_for_type(field_type)

    extraction =
      Json.build_extraction(column, path,
        as_text: true,
        table_alias: get_root_alias(selecto),
        cast: cast,
        adapter: Map.fetch!(selecto, :adapter)
      )

    sql_op =
      case comp do
        :gt -> ">"
        :lt -> "<"
        :gte -> ">="
        :lte -> "<="
        :eq -> "="
        :ne -> "!="
        other -> to_string(other)
      end

    # Cast value appropriately for comparison
    param_value =
      case field_type do
        t when t in [:integer, :decimal, :float] -> value
        _ -> to_string(value)
      end

    {[], [" ", extraction, " ", sql_op, " ", {:param, param_value}, " "], []}
  end

  defp build_json_in(selecto, column, path, list) do
    domain = selecto.config
    path_schema = Json.get_path_schema(domain, column, path)
    field_type = if path_schema, do: Map.get(path_schema, :type), else: nil
    cast = Json.cast_for_type(field_type)

    extraction =
      Json.build_extraction(column, path,
        as_text: true,
        table_alias: get_root_alias(selecto),
        cast: cast,
        adapter: Map.fetch!(selecto, :adapter)
      )

    # Convert list values to appropriate types
    typed_list =
      case field_type do
        t when t in [:integer, :decimal, :float] -> list
        _ -> Enum.map(list, &to_string/1)
      end

    placeholders = typed_list |> Enum.map(&{:param, &1}) |> Enum.intersperse(", ")
    {[], [" ", extraction, " IN (", placeholders, ") "], []}
  end

  defp build_json_between(selecto, column, path, min, max) do
    domain = selecto.config
    path_schema = Json.get_path_schema(domain, column, path)
    field_type = if path_schema, do: Map.get(path_schema, :type), else: nil
    cast = Json.cast_for_type(field_type)

    extraction =
      Json.build_extraction(column, path,
        as_text: true,
        table_alias: get_root_alias(selecto),
        cast: cast,
        adapter: Map.fetch!(selecto, :adapter)
      )

    {[], [" ", extraction, " BETWEEN ", {:param, min}, " AND ", {:param, max}, " "], []}
  end

  defp build_regular_comparison(selecto, field, comp, value) do
    conf = field_conf(selecto, field)
    {sel, join, param} = Select.prep_selector(selecto, field)

    sql_op =
      case comp do
        :gt -> ">"
        :lt -> "<"
        :gte -> ">="
        :lte -> "<="
        :eq -> "="
        :ne -> "!="
        other -> to_string(other)
      end

    {List.wrap(conf.requires_join) ++ List.wrap(join),
     comparison_clause(
       selecto,
       conf,
       field,
       sel,
       sql_op,
       {:param, to_field_value(selecto, conf, value)}
     ), param}
  end

  defp get_root_alias(selecto) do
    # Get the table alias for the root table
    Map.get(selecto, :root_alias, "selecto_root")
  end

  # Build CASE expression for WHERE clause
  defp build_case_expression(selecto, when_clauses, else_clause) do
    # Collect joins and params from all parts
    {when_parts, all_joins, all_params} =
      when_clauses
      |> Enum.reduce({[], [], []}, fn {condition, result}, {parts_acc, joins_acc, params_acc} ->
        # Build the condition (could be complex filter)
        {cond_joins, cond_iodata, cond_params} = build(selecto, condition)

        # Build the result (could be a filter expression or boolean)
        {result_joins, result_iodata, result_params} =
          case result do
            true ->
              {[], ["TRUE"], []}

            false ->
              {[], ["FALSE"], []}

            nil ->
              {[], ["NULL"], []}

            result when is_tuple(result) ->
              build(selecto, result)

            result when is_binary(result) or is_number(result) ->
              {[], [{:param, result}], [result]}
          end

        when_part = ["WHEN ", cond_iodata, " THEN ", result_iodata]

        {parts_acc ++ [when_part], joins_acc ++ List.wrap(cond_joins) ++ List.wrap(result_joins),
         params_acc ++ cond_params ++ result_params}
      end)

    # Build ELSE clause
    {else_joins, else_iodata, else_params} =
      case else_clause do
        nil ->
          {[], [], []}

        true ->
          {[], [" ELSE TRUE"], []}

        false ->
          {[], [" ELSE FALSE"], []}

        else_clause when is_tuple(else_clause) ->
          {ej, ei, ep} = build(selecto, else_clause)
          {ej, [" ELSE ", ei], ep}

        else_clause when is_binary(else_clause) or is_number(else_clause) ->
          {[], [" ELSE ", {:param, else_clause}], [else_clause]}
      end

    case_iodata = ["CASE ", Enum.intersperse(when_parts, " ")] ++ else_iodata ++ [" END"]

    {case_iodata, all_joins ++ List.wrap(else_joins), all_params ++ else_params}
  end

  defp build_regular_between(selecto, field, min, max) do
    conf = field_conf(selecto, field)
    # Extract actual field name, not display name
    field_name = extract_database_field(field, conf)
    selector = build_selector_string(selecto, conf.requires_join, field_name)

    # Use half-open interval for datetime types to avoid precision issues
    if identity = identity_between(selecto, conf, field, selector, min, max) do
      {conf.requires_join, identity, []}
    else
      plain_regular_between(selecto, conf, field_name, min, max)
    end
  end

  defp plain_regular_between(selecto, conf, field_name, min, max) do
    sel = build_selector_string(selecto, conf.requires_join, field_name)
    type = TypedOperator.field_type(selecto, conf, field_name)

    if date_like_type(conf) do
      {conf.requires_join,
       [
         " (",
         TypedOperator.compare(
           selecto,
           type,
           sel,
           ">=",
           {:param, to_field_value(selecto, conf, min)}
         ),
         " and ",
         TypedOperator.compare(
           selecto,
           type,
           sel,
           "<",
           {:param, to_field_value(selecto, conf, max)}
         ),
         ") "
       ], []}
    else
      # Use standard BETWEEN for non-datetime types
      {conf.requires_join,
       TypedOperator.between(
         selecto,
         type,
         sel,
         {:param, to_field_value(selecto, conf, min)},
         {:param, to_field_value(selecto, conf, max)}
       ), []}
    end
  end

  defp to_type(:id, value) when is_integer(value) do
    value
  end

  defp to_type(:id, value) when is_bitstring(value) do
    value
    |> String.trim()
    |> String.to_integer()
  end

  defp to_type(type, value) when type in [:uuid, :binary_id] and is_binary(value) do
    UUID.string_to_binary!(value)
  rescue
    ArgumentError -> value
  end

  defp to_type(:integer, value) when is_integer(value) do
    value
  end

  defp to_type(:integer, value) when is_bitstring(value) do
    value
    |> String.trim()
    |> String.to_integer()
  end

  defp to_type(_t, val) do
    val
  end

  defp to_field_value(selecto, conf, value) do
    # R3c2 FINAL: a scope literal is checked as written, before the declared
    # type parses it (" 1", "+1" and "-0" would otherwise become 1 and 0).
    raw_literal!(selecto, conf, value)

    if Selecto.Temporal.epoch_storage(conf) && date_like_type(conf) do
      Selecto.Temporal.coerce_filter_value(conf, value)
    else
      value = Selecto.Temporal.coerce_sql_param_value(conf, value)
      type = Map.get(conf, :type)

      # Adapters that store UUIDs as text (MySQL and MariaDB map :uuid and
      # :binary_id to CHAR(36)) bind the string form; the others bind the
      # 16-byte binary.
      if type in [:uuid, :binary_id] and is_binary(value) and
           Selecto.AdapterSupport.supports_feature?(
             Map.get(selecto, :adapter),
             :uuid_text_storage
           ),
         do: value,
         else: to_type(type, value)
    end
  end

  defp date_like_type(conf), do: Selecto.Temporal.date_like_type(conf)

  defp raw_literal!(selecto, conf, value) when is_binary(value) and is_map(conf) do
    if ExactCompare.in_scope?() and not computed?(conf) and Map.get(conf, :field) do
      ExactCompare.exact_literals!(
        selecto,
        ExactCompare.field_relation(selecto, conf),
        to_string(Map.get(conf, :field)),
        [value]
      )
    end

    :ok
  end

  defp raw_literal!(_selecto, _conf, _value), do: :ok

  defp build_datetime_predicate(selecto, field, operation, part, predicate, options \\ %{}) do
    refuse_timestamp_operator(selecto, field, "a date part or format")
    conf = field_conf(selecto, field)
    {expression, joins, params} = Select.prep_selector(selecto, field)

    fragment = %DateTimeOperation{
      operation: operation,
      clause: :filter,
      expression: expression,
      part: normalize_datetime_part!(part),
      options: Map.put(options, :epoch_storage, Selecto.Temporal.epoch_storage(conf))
    }

    {rendered, dialect_params} = render_datetime_fragment!(selecto, fragment)

    {List.wrap(conf.requires_join) ++ List.wrap(joins),
     [" ", expression_predicate_sql(selecto, rendered, predicate), " "], params ++ dialect_params}
  end

  defp normalize_datetime_part!(nil), do: nil

  defp normalize_datetime_part!(part) do
    case DateTimeOperation.normalize_part(part) do
      {:ok, normalized} ->
        normalized

      {:error, reason} ->
        ExactCompare.refuse(:datetime_part, "invalid datetime part: #{inspect(reason)}")
    end
  end

  defp render_datetime_fragment!(selecto, fragment) do
    case Selecto.DialectSupport.render_datetime_operation(selecto.adapter, fragment, selecto) do
      {:ok, {iodata, params}} ->
        {iodata, List.wrap(params)}

      {:ok, iodata} ->
        {iodata, []}

      {:error, %Error{} = error} ->
        Selecto.Builder.ScopeRefusal.unsupported!(error)

      {:error, reason} ->
        ExactCompare.refuse(:datetime_part, "unsupported datetime predicate: #{inspect(reason)}")
    end
  end

  defp render_text_normalization!(selecto, fragment) do
    case Selecto.DialectSupport.render_text_normalization(selecto.adapter, fragment, selecto) do
      {:ok, {iodata, params}} ->
        {iodata, List.wrap(params)}

      {:ok, iodata} ->
        {iodata, []}

      {:error, %Error{} = error} ->
        Selecto.Builder.ScopeRefusal.unsupported!(error)

      {:error, reason} ->
        raise ArgumentError, "unsupported text normalization: #{inspect(reason)}"
    end
  end

  defp render_comparison!(selecto, fragment) do
    case Selecto.DialectSupport.render_comparison(selecto.adapter, fragment, selecto) do
      {:ok, iodata} ->
        iodata

      {:error, %Error{} = error} ->
        Selecto.Builder.ScopeRefusal.unsupported!(error)

      {:error, reason} ->
        raise ArgumentError, "unsupported case-insensitive comparison: #{inspect(reason)}"
    end
  end

  defp expression_predicate_sql(selecto, expression, {:in, values})
       when is_list(values) and values != [] do
    TypedOperator.in_list(selecto, nil, expression, Enum.map(values, &{:param, &1}), false)
  end

  defp expression_predicate_sql(selecto, expression, {operator, value})
       when operator in [:=, :!=, :<, :>, :<=, :>=] do
    TypedOperator.compare(selecto, nil, expression, Atom.to_string(operator), {:param, value})
  end

  defp expression_predicate_sql(selecto, expression, {operator, value})
       when operator in [:like, :not_like] do
    sql_operator = if operator == :like, do: "LIKE", else: "NOT LIKE"
    TypedOperator.compare(selecto, nil, expression, sql_operator, {:param, value})
  end

  defp expression_predicate_sql(selecto, expression, value),
    do: TypedOperator.compare(selecto, nil, expression, "=", {:param, value})

  # Equality and inequality on a tenant/site column of an exact-compare adapter
  # (MySQL, MariaDB) decide on the stored bytes; every other comparison, and
  # every other adapter, renders exactly as before.
  # A host, trusted, required or tenant comparison on a column stored as
  # TIMESTAMP compiles zone-independently (ExactCompare.storage_kind/4,
  # item 62a); every other comparison renders as before.
  defp comparison_clause(selecto, conf, field, sel, operator, {:param, value} = right) do
    case identity_kind(selecto, conf, field) do
      :duck_text ->
        ExactCompare.bytes_compare(sel, operator, value)

      :timestamp ->
        ExactCompare.unix_compare(sel, operator, value)

      # Character storage compares utf8mb4 bytes under every operator,
      # whatever the declared type (R3, R16, R26: an integer-declared VARCHAR
      # never matches '01' or ' 1').
      :mysql_text ->
        ExactCompare.binary_compare(sel, operator, value)

      :unresolved ->
        unresolved!()

      _plain ->
        exact_literals!(selecto, conf, field, [value])
        plain_comparison_clause(selecto, conf, field, sel, operator, right)
    end
  end

  # R3 clarification 2: a scope comparison that keeps the native compare on
  # a non-text storage type binds only literals the type represents
  # exactly; '1.4' or '1e0' against an INTEGER, or '1.005' against
  # DECIMAL(10,2), would be rounded by the cast and is refused.
  defp exact_literals!(selecto, conf, field, values) do
    conf = if is_map(conf), do: conf, else: %{}

    if host_comparison?(selecto, conf, field) and not computed?(conf) do
      ExactCompare.exact_literals!(
        selecto,
        ExactCompare.field_relation(selecto, conf),
        column_name(conf, field),
        values
      )
    end

    :ok
  end

  # How a host, trusted, required or tenant comparison on `field` must be
  # compiled on the adapter's storage (types loaded by prepare_read/2):
  # - :duck_text, a DuckDB VARCHAR identity column (bytes, every operator);
  # - :timestamp, a MySQL-family TIMESTAMP column (epoch, item 62a);
  # - :mysql_text, a MySQL-family character column (ranges and patterns by
  #   utf8mb4 bytes, R3; equality already compares exactly);
  # - :unresolved, a declared temporal column the lookup did not resolve;
  # - nil, anything else (and every caller-only comparison).
  defp identity_kind(selecto, conf, field) do
    conf = if is_map(conf), do: conf, else: %{}

    cond do
      not host_comparison?(selecto, conf, field) ->
        nil

      computed?(conf) ->
        computed_kind(selecto, conf)

      true ->
        case ExactCompare.storage_kind(
               selecto,
               ExactCompare.field_relation(selecto, conf),
               column_name(conf, field),
               Map.get(conf, :type)
             ) do
          :plain -> nil
          kind -> kind
        end
    end
  end

  defp computed?(conf),
    do:
      match?({tag, _} when tag in [:computed_value, :computed_predicate], Map.get(conf, :select))

  # A computed scope field (R15): a computed predicate compiles through this
  # builder, so its comparisons are handled where they occur; a computed
  # value that reads a TIMESTAMP-stored column as a value (cast, concat, a
  # date part, a coalesce of it, rather than only inside a CASE condition)
  # depends on the session's time_zone and is refused.
  defp computed_kind(selecto, conf) do
    case Map.get(conf, :select) do
      {:computed_value, expression} ->
        if ExactCompare.computed_reads_timestamp?(selecto, expression),
          do:
            ExactCompare.refuse(
              :timestamp_operator,
              "a scope value computed from a TIMESTAMP column depends on the session time zone"
            ),
          else: nil

      _predicate ->
        nil
    end
  end

  # A text, date-part or format operator on a TIMESTAMP scope column is
  # zone-dependent (R4, R15): refused.
  defp refuse_timestamp_operator(selecto, field, what) do
    if identity_kind(selecto, safe_field_conf(selecto, field), field) in [:timestamp, :unresolved],
      do:
        ExactCompare.refuse(
          :timestamp_operator,
          "#{what} on a TIMESTAMP scope column depends on the session time zone"
        )

    :ok
  end

  defp unresolved!,
    do:
      ExactCompare.refuse(
        :column_unresolved,
        "a scope comparison names a temporal column the catalog lookup did not resolve"
      )

  # BETWEEN on an identity column, compiled exactly (or nil).
  defp identity_between(selecto, conf, field, selector, min, max) do
    min = to_field_value(selecto, conf, min)
    max = to_field_value(selecto, conf, max)

    case identity_kind(selecto, conf, field) do
      :duck_text ->
        [
          " (",
          ExactCompare.bytes_compare(selector, ">=", min),
          " and ",
          ExactCompare.bytes_compare(selector, "<=", max),
          ") "
        ]

      :mysql_text ->
        [
          " (",
          ExactCompare.binary_compare(selector, ">=", min),
          " and ",
          ExactCompare.binary_compare(selector, "<=", max),
          ") "
        ]

      :timestamp ->
        upper = if date_like_type(conf), do: "<", else: "<="

        [
          " (",
          ExactCompare.unix_compare(selector, ">=", min),
          " and ",
          ExactCompare.unix_compare(selector, upper, max),
          ") "
        ]

      :unresolved ->
        unresolved!()

      _plain ->
        exact_literals!(selecto, conf, field, [min, max])
        nil
    end
  end

  # LIKE-family operators (R3, R4): on a MySQL-family character scope
  # column they compare utf8mb4 bytes; on a DuckDB VARCHAR scope column they
  # run under COLLATE posix; on a TIMESTAMP scope column they are
  # zone-dependent and refused.
  defp like_clause(selecto, field, sel, operator, pattern, escape) do
    case identity_kind(selecto, safe_field_conf(selecto, field), field) do
      :mysql_text ->
        ExactCompare.binary_like(sel, operator, pattern, escape)

      # An explicit COLLATE posix overrides the column's and the session's
      # collation, so every pattern compares exactly (DuckDB's LIKE,
      # contains() and strpos() otherwise follow COLLATE NOCASE).
      :duck_text ->
        [" (", sel, " COLLATE posix) ", operator, " ", {:param, pattern}, escape, " "]

      :timestamp ->
        ExactCompare.refuse(
          :timestamp_operator,
          "a scope pattern on a TIMESTAMP column depends on the session time zone"
        )

      :unresolved ->
        unresolved!()

      _plain ->
        TypedOperator.compare(
          selecto,
          TypedOperator.field_type(selecto, safe_field_conf(selecto, field), field),
          sel,
          operator,
          {:param, pattern},
          if(escape == "", do: [], else: [escape: "!"])
        )
    end
  end

  # IN lists on identity columns: DuckDB VARCHAR by bytes; a TIMESTAMP
  # scope list as exact epoch equalities (item 62a); nil otherwise.
  defp identity_list(selecto, conf, field, sel, values, negate?) do
    case identity_kind(selecto, conf, field) do
      :duck_text ->
        placeholders =
          values
          |> Enum.map(&["encode(CAST(", {:param, &1}, " AS VARCHAR))"])
          |> Enum.intersperse(", ")

        [" ", if(negate?, do: "NOT ", else: ""), "encode(", sel, ") IN (", placeholders, ") "]

      :mysql_text ->
        placeholders =
          values
          |> Enum.map(&["CAST(", {:param, &1}, " AS BINARY)"])
          |> Enum.intersperse(", ")

        [
          " ",
          if(negate?, do: "NOT ", else: ""),
          "CAST(CONVERT(",
          sel,
          " USING utf8mb4) AS BINARY) IN (",
          placeholders,
          ") "
        ]

      :timestamp ->
        # One exact epoch equality per value (they stay exact under NOT).
        equalities =
          values
          |> Enum.map(&ExactCompare.unix_compare(sel, "=", &1))
          |> Enum.intersperse(" OR ")

        [" ", if(negate?, do: "NOT ", else: ""), "(", equalities, ") "]

      :unresolved ->
        unresolved!()

      _plain ->
        exact_literals!(selecto, conf, field, values)
        nil
    end
  end

  defp host_comparison?(_selecto, _conf, _field), do: ExactCompare.in_scope?()

  defp plain_comparison_clause(selecto, conf, field, sel, operator, right)
       when operator in ["=", "!="] do
    if mode = exact?(selecto, conf, field) do
      exact = ExactCompare.eq(sel, right, mode)
      if operator == "=", do: [" ", exact, " "], else: [" NOT ", exact, " "]
    else
      TypedOperator.compare(
        selecto,
        TypedOperator.field_type(selecto, conf, field),
        sel,
        operator,
        right
      )
    end
  end

  defp plain_comparison_clause(selecto, conf, field, sel, operator, right),
    do:
      TypedOperator.compare(
        selecto,
        TypedOperator.field_type(selecto, conf, field),
        sel,
        operator,
        right
      )

  # A column-vs-column equality or inequality compares exactly when either
  # side is a tenant/site column or the predicate is host-installed, and its
  # mode is the strongest of BOTH sides' modes (ADDENDUM 6): an INT column
  # declared :integer against a VARCHAR column compares by bytes, never
  # numerically ('07', '7 ', '7e0' never equal 7). Other operators and
  # adapters render as before.
  defp ref_comparison_clause(selecto, {conf, field, sel}, operator, {ref_field, ref_sel})
       when operator in ["=", "!="] do
    ref_conf = safe_field_conf(selecto, ref_field)
    domain = Map.get(selecto, :domain)

    mode =
      ExactCompare.enabled?(selecto) and
        (ExactCompare.tenant_name?(domain, column_name(conf, field)) or
           ExactCompare.tenant_name?(domain, column_name(ref_conf, ref_field)) or
           ExactCompare.host_mode(selecto, to_string(field))) and
        ExactCompare.strongest([
          side_mode(domain, conf, field),
          side_mode(domain, ref_conf, ref_field)
        ])

    if mode do
      exact = ExactCompare.eq(sel, ref_sel, mode)
      if operator == "=", do: [" ", exact, " "], else: [" NOT ", exact, " "]
    else
      TypedOperator.compare_columns(
        selecto,
        TypedOperator.field_type(selecto, conf, field),
        sel,
        operator,
        TypedOperator.field_type(selecto, ref_conf, ref_field),
        ref_sel
      )
    end
  end

  defp ref_comparison_clause(selecto, {conf, field, sel}, operator, {ref_field, ref_sel}),
    do:
      TypedOperator.compare_columns(
        selecto,
        TypedOperator.field_type(selecto, conf, field),
        sel,
        operator,
        TypedOperator.field_type(selecto, safe_field_conf(selecto, ref_field), ref_field),
        ref_sel
      )

  # One side's mode: its own declared type, else the name's declarations
  # across the domain, else guarded (:server).
  defp side_mode(_domain, %{type: type}, _field), do: ExactCompare.type_mode(type)

  defp side_mode(domain, conf, field),
    do: ExactCompare.exact_name?(domain, column_name(conf, field)) || :server

  defp safe_field_conf(selecto, field) when is_binary(field) or is_atom(field) do
    field_conf(selecto, to_string(field))
  rescue
    _ -> nil
  end

  defp safe_field_conf(_selecto, _field), do: nil

  # `bytes_fun` builds the subquery selecting its column's utf8mb4 bytes; a
  # prebuilt subquery (nil) compares its own values as bytes, which matches
  # utf8mb4 columns and refuses rows of other character sets (fails closed).
  defp in_subquery_clause(selecto, conf, field, sel, fragment, bytes_fun) do
    if mode = exact?(selecto, conf, field) do
      bytes = if bytes_fun, do: bytes_fun.(mode), else: fragment
      [" ", ExactCompare.in_subquery(sel, fragment, bytes, mode), " "]
    else
      TypedOperator.subquery(
        selecto,
        TypedOperator.field_type(selecto, conf, field),
        sel,
        "=",
        "ANY",
        fragment,
        [" ", sel, " in ", fragment, " "]
      )
    end
  end

  # The exact mode of a tenant/site column: by the field's own declared type
  # when it has one, else by the name's declarations across the domain.
  # A tenant/site column, or a field a host-installed predicate compares
  # (Selecto.Builder.ExactCompare.host_names/1, matched on the field as
  # written, so "person.name" never makes the root "name" exact), compares
  # exactly; the mode comes from the field's own declared type.
  # Exact equality is for scope comparisons only (provenance); the caller's
  # own =, != and IN keep native semantics like its ranges (R12, item 55).
  defp exact?(selecto, conf, field) do
    with true <- ExactCompare.enabled?(selecto),
         true <- ExactCompare.in_scope?(),
         true <-
           ExactCompare.exact_name?(Map.get(selecto, :domain), column_name(conf, field)) != false or
             ExactCompare.host_mode(selecto, to_string(field)) do
      case conf do
        %{type: type} ->
          ExactCompare.type_mode(type)

        _ ->
          ExactCompare.exact_name?(Map.get(selecto, :domain), column_name(conf, field)) || :server
      end
    end
  end

  defp column_name(conf, field) when is_map(conf),
    do: conf |> Map.get(:field) |> Kernel.||(extract_database_field(field, conf)) |> to_string()

  defp column_name(_conf, field), do: to_string(field)

  defp field_conf(selecto, field) do
    case fast_config_column(selecto, field) do
      nil -> Selecto.field(selecto, field)
      conf -> conf
    end
  end

  defp fast_config_column(selecto, field) do
    columns = Map.get(selecto.config, :columns, %{})

    conf =
      Map.get(columns, field) ||
        case safe_existing_atom(field) do
          nil -> nil
          atom_key -> Map.get(columns, atom_key)
        end

    case conf do
      nil ->
        nil

      value ->
        value
        |> Map.put_new(:requires_join, :selecto_root)
        |> Map.put_new(:field, field_name(value, field))
    end
  end

  defp field_name(conf, field) do
    case Map.get(conf, :field) do
      nil -> Map.get(conf, :name, field)
      value -> value
    end
  end

  defp safe_existing_atom(field) when is_binary(field) do
    try do
      String.to_existing_atom(field)
    rescue
      ArgumentError -> nil
    end
  end

  defp safe_existing_atom(_field), do: nil

  defp build_text_search(selecto, fields, value, opts \\ []) when is_list(fields) do
    adapter = Map.get(selecto, :adapter)
    mode = canonical_text_search_mode(Keyword.get(opts, :mode))

    compiled_fields =
      Enum.map(fields, fn field ->
        conf = field_conf(selecto, field)
        field_name = extract_database_field(field, conf)
        {conf, field_name}
      end)

    joins =
      compiled_fields
      |> Enum.flat_map(fn {conf, _field_name} -> List.wrap(conf.requires_join) end)
      |> Enum.uniq()

    selectors =
      Enum.map(compiled_fields, fn {conf, field_name} ->
        build_selector_string(selecto, conf.requires_join, field_name)
      end)

    fragment = %Selecto.Dialect.TextSearch.Predicate{
      fields:
        Enum.map(compiled_fields, fn {conf, field_name} ->
          %{name: to_string(field_name), config: conf}
        end),
      selectors: selectors,
      query: value,
      mode: mode,
      configuration: Keyword.get(opts, :configuration)
    }

    case Selecto.DialectSupport.render_text_search_predicate(adapter, fragment, selecto) do
      {:ok, predicate} ->
        {joins, predicate, []}

      {:error, %Error{} = error} ->
        Selecto.Builder.ScopeRefusal.unsupported!(error)

      {:error, reason} ->
        raise_text_search_error(
          "Adapter could not render text search",
          AdapterSupport.adapter_name(adapter),
          :text_search,
          [{:reason, reason} | fields]
        )
    end
  end

  defp raise_text_search_error(message, adapter_name, unsupported_feature, fields) do
    error =
      Error.validation_error(message, %{
        adapter: adapter_name,
        fields: fields,
        unsupported_feature: unsupported_feature
      })

    Selecto.Builder.ScopeRefusal.unsupported!(error)
  end

  defp normalize_text_search_spec(default_fields, opts) when is_list(opts) do
    {query, remaining_opts} = Keyword.pop(opts, :query)
    fields = Keyword.get(remaining_opts, :fields, default_fields)

    text_search_opts =
      remaining_opts
      |> Keyword.drop([:fields])
      |> Keyword.update(:mode, nil, &canonical_text_search_mode/1)

    if is_nil(query) do
      raise ArgumentError, "text_search config requires a :query option"
    end

    {List.wrap(fields), query, text_search_opts}
  end

  defp canonical_text_search_mode(:web), do: :websearch
  defp canonical_text_search_mode(mode), do: mode

  @doc false
  # A finalized Selecto query rendered as parameter-marked iodata for embedding
  # as a subquery, its root alias renamed so it cannot capture the outer root.
  def subquery_iodata(%Selecto{} = query_selecto), do: selecto_subquery_to_iodata(query_selecto)

  defp selecto_subquery_to_iodata(%Selecto{} = query_selecto) do
    {sql, params} = Selecto.to_sql(query_selecto)

    sql = rewrite_subquery_root_alias(sql, build_subquery_root_alias(query_selecto))
    Selecto.SQL.Params.rebind_finalized(sql, params, query_selecto.adapter)
  end

  @doc false
  # The subquery selecting the utf8mb4 bytes of a single-column Selecto
  # subquery (Selecto.Builder.ExactCompare.bytes_subquery/2).
  def exact_subquery_iodata(%Selecto{} = query_selecto, mode \\ true) do
    {sql, _aliases, params} = Selecto.gen_sql(query_selecto, unique_projection_aliases: true)
    sql = rewrite_subquery_root_alias(sql, build_subquery_root_alias(query_selecto))
    iodata = Selecto.SQL.Params.rebind_finalized(sql, params, query_selecto.adapter)

    ExactCompare.bytes_subquery(
      ["(", iodata, ")"],
      Selecto.Builder.Sql.projection_alias(1),
      mode
    )
  end

  defp build_subquery_root_alias(query_selecto) do
    table_segment =
      query_selecto
      |> Selecto.source_table()
      |> normalize_alias_segment("source")

    "subq_root_#{table_segment}"
  end

  defp normalize_alias_segment(value, fallback) do
    normalized =
      value
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")

    if normalized == "", do: fallback, else: normalized
  end

  defp rewrite_subquery_root_alias(subquery_sql, alias_name) when is_binary(subquery_sql) do
    Regex.replace(~r/\bselecto_root\b/u, subquery_sql, alias_name)
  end

  defp subquery_operator!(operator) do
    normalized =
      case operator do
        value when value in [:eq, :==] -> "="
        value when value in [:neq, :!=] -> "!="
        :gt -> ">"
        :gte -> ">="
        :lt -> "<"
        :lte -> "<="
        value -> to_string(value)
      end

    if normalized in ~w(= != <> < <= > >=) do
      normalized
    else
      error =
        Error.validation_error("Invalid ANY/ALL comparison operator", %{
          operator: operator,
          allowed: ~w(= != <> < <= > >=)
        })

      raise Error.to_exception(error)
    end
  end

  # Ensure `IN` subqueries are wrapped in parentheses.
  # If caller already provides parentheses, keep them as-is.
  # A host fragment given without params is kept as written, once no session
  # mode reads a placeholder in its code (Selecto.SQL.Params.rebind_finalized/3):
  # one would bind a value of the statement around it.
  defp verbatim_fragment(selecto, query) when is_binary(query),
    do: Selecto.SQL.Params.rebind_finalized(query, [], selecto.adapter)

  # Iodata with {:param, value} markers: the markers are its params, so its
  # text may hold no placeholder of its own (one would bind a marker's or the
  # statement's value); the text is checked with each marker as a neutral
  # literal, then kept with its markers.
  defp verbatim_fragment(%{adapter: adapter}, query)
       when is_list(query) and not is_nil(adapter) do
    _text = Selecto.SQL.Params.rebind_finalized(neutral_text(query), [], adapter)
    query
  end

  defp verbatim_fragment(_selecto, query), do: query

  defp neutral_text(query) do
    query
    |> List.wrap()
    |> Enum.map(fn
      {:param, _value} -> " NULL "
      list when is_list(list) -> neutral_text(list)
      text when is_binary(text) -> text
      # Rendered as SQL text the way Selecto.SQL.Params.finalize/2 renders it.
      number when is_integer(number) or is_float(number) -> to_string(number)
      _other -> " NULL "
    end)
    |> IO.iodata_to_binary()
  end

  defp in_subquery_fragment(query) when is_binary(query) do
    trimmed = String.trim(query)

    if String.starts_with?(trimmed, "(") and String.ends_with?(trimmed, ")") do
      trimmed
    else
      ["(", query, ")"]
    end
  end

  defp in_subquery_fragment(query), do: ["(", query, ")"]

  # Literal text for LIKE ... ESCAPE '!': `%` and `_` everywhere, plus `[`,
  # which opens a character class on SQL Server.
  defp escape_like_literal(value),
    do: String.replace(value, ~r/[!%_\[]/u, fn character -> "!" <> character end)

  defp build_conjunction(selecto, conj, filters) do
    # Handle empty filter list - return empty result to avoid empty WHERE clauses
    if Enum.empty?(filters) do
      {[], [], []}
    else
      {joins, clauses, param_chunks} =
        Enum.reduce(filters, {[], [], []}, fn
          f, {joins, clauses, param_chunks} ->
            {j, c, p} = build(selecto, f)
            {[j | joins], [c | clauses], [p | param_chunks]}
        end)

      joins = Enum.reverse(joins)
      clauses = Enum.reverse(clauses)
      params = param_chunks |> Enum.reverse() |> List.flatten()

      clause_parts = Enum.map(clauses, fn c -> ["(", c, ")"] end)
      conj_str = " #{conj} "

      final_clause = [
        "(",
        Enum.intersperse(clause_parts, conj_str),
        ")"
      ]

      {joins, final_clause, params}
    end
  end

  defp same_field_scalars([{field, value} | _] = filters)
       when is_binary(field) and is_binary(value),
       do: same_field_scalars(filters, field, is_binary(value))

  defp same_field_scalars([{field, value} | _] = filters)
       when is_binary(field) and is_number(value),
       do: same_field_scalars(filters, field, false)

  defp same_field_scalars(_filters), do: nil

  defp same_field_scalars(filters, field, binary?) do
    scalar? = fn value -> if binary?, do: is_binary(value), else: is_number(value) end

    if Enum.all?(filters, &(match?({^field, _}, &1) and scalar?.(elem(&1, 1)))),
      do: {field, Enum.map(filters, &elem(&1, 1))},
      else: nil
  end
end
