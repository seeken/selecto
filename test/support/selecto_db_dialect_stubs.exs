defmodule Selecto.TestDialect.PostgreSQL do
  alias Selecto.Dialect.TextSearch.{Predicate, Rank}
  alias Selecto.Dialect.Collection.Operation, as: CollectionOperation
  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation
  alias Selecto.Dialect.Predicate.Comparison
  alias Selecto.Dialect.Hierarchy.{Adjacency, MaterializedPath}
  alias Selecto.Dialect.TableFunction.Join, as: TableFunctionJoin
  alias Selecto.Dialect.Window.FrameBoundary
  alias Selecto.Dialect.View.{Definition, Index, Refresh}

  def render_json_extraction(fragment, _selecto),
    do: Selecto.TestDialect.Json.extraction(:postgresql, fragment)

  def render_json_contains(fragment, _selecto),
    do: Selecto.TestDialect.Json.contains(:postgresql, fragment)

  def render_json_key_exists(fragment, _selecto),
    do: Selecto.TestDialect.Json.key_exists(:postgresql, fragment)

  def render_json_array_contains(fragment, _selecto),
    do: Selecto.TestDialect.Json.array_contains(:postgresql, fragment)

  def render_json_array_contains_all(fragment, _selecto),
    do: Selecto.TestDialect.Json.array_contains_all(:postgresql, fragment)

  def render_json_operation(fragment, _selecto),
    do: Selecto.TestDialect.Json.operation(:postgresql, fragment)

  def render_comparison(%Comparison{} = comparison, _selecto) do
    operator =
      if comparison.operation == :case_insensitive_not_like, do: "NOT ILIKE", else: "ILIKE"

    {:ok, [comparison.left, " ", operator, " ", comparison.right]}
  end

  def render_datetime_operation(%DateTimeOperation{} = operation, _selecto) do
    expression = test_datetime_expression(operation)

    case operation.operation do
      :current_timestamp ->
        {:ok, "NOW()"}

      :truncate ->
        {:ok, ["DATE_TRUNC('", Atom.to_string(operation.part), "', ", expression, ")"]}

      :age when is_nil(operation.second_expression) ->
        {:ok, ["AGE(", expression, ")"]}

      :age ->
        {:ok, ["AGE(", expression, ", ", operation.second_expression, ")"]}

      :extract_part when operation.part == :weekday_sunday_one ->
        {:ok, ["CAST(TO_CHAR(", expression, ", 'D') AS INTEGER)"]}

      :extract_part ->
        {:ok, ["DATE_PART('", Atom.to_string(operation.part), "', ", expression, ")"]}

      :format ->
        {:ok, ["TO_CHAR(", expression, ", '", Map.fetch!(operation.options, :format), "')"]}

      :elapsed_days ->
        {:ok, ["CURRENT_DATE - DATE(", expression, ")"]}

      :temporal_cutoff ->
        amount = Map.fetch!(operation.options, :amount)

        clock =
          case Map.fetch!(operation.options, :clock) do
            :current_date -> "CURRENT_DATE"
            :current_timestamp -> "NOW()"
          end

        {:ok,
         {[
            operation.expression,
            " > (",
            clock,
            " - (",
            {:param, amount},
            " * INTERVAL '1 ",
            Atom.to_string(operation.part),
            "'))"
          ], [amount]}}
    end
  end

  defp test_datetime_expression(operation) do
    case Map.get(operation.options, :epoch_storage) do
      :unix_seconds -> ["TO_TIMESTAMP(", operation.expression, ")"]
      :unix_milliseconds -> ["TO_TIMESTAMP((", operation.expression, ") / 1000.0)"]
      _ -> operation.expression
    end
  end

  def render_collection_operation(%CollectionOperation{} = operation, _selecto) do
    case operation.operation do
      kind when kind in [:array_agg, :array_agg_distinct] ->
        distinct = if operation.distinct, do: "DISTINCT ", else: ""
        {:ok, ["ARRAY_AGG(", distinct, operation.column, order_by(operation.order_by), ")"]}

      :string_agg ->
        delimiter = Map.get(operation.options, :delimiter, ",")
        distinct = if operation.distinct, do: "DISTINCT ", else: ""

        {:ok,
         {[
            "STRING_AGG(",
            distinct,
            operation.column,
            ", ",
            {:param, delimiter},
            order_by(operation.order_by),
            ")"
          ], [delimiter]}}

      kind when kind in [:array_contains, :array_contained, :array_overlap, :array_eq] ->
        {:ok,
         {[operation.column, " ", collection_operator(kind), " ", {:param, operation.value}],
          [operation.value]}}

      :array_length ->
        {:ok,
         ["ARRAY_LENGTH(", operation.column, ", ", Integer.to_string(operation.dimension), ")"]}

      :cardinality ->
        {:ok, ["CARDINALITY(", operation.column, ")"]}

      kind when kind in [:array_ndims, :array_dims] ->
        {:ok, [kind |> Atom.to_string() |> String.upcase(), "(", operation.column, ")"]}

      :array ->
        values = operation.value || []
        {:ok, {["ARRAY[", Enum.intersperse(Enum.map(values, &{:param, &1}), ", "), "]"], values}}

      :array_constructor ->
        {:ok, ["ARRAY[", operation.value || [], "]"]}

      :array_fill ->
        dimensions = Map.get(operation.options, :dimensions)

        {:ok,
         {["ARRAY_FILL(", {:param, operation.value}, ", ", {:param, dimensions}, ")"],
          [operation.value, dimensions]}}

      :array_append ->
        one_param("ARRAY_APPEND", operation.column, operation.value)

      :array_prepend ->
        {:ok,
         {["ARRAY_PREPEND(", {:param, operation.value}, ", ", operation.column, ")"],
          [operation.value]}}

      :array_cat ->
        case Map.fetch(operation.options, :value_expression) do
          {:ok, value_expression} ->
            {:ok, ["ARRAY_CAT(", operation.column, ", ", value_expression, ")"]}

          :error ->
            one_param("ARRAY_CAT", operation.column, operation.value)
        end

      :array_position ->
        case Map.fetch(operation.options, :start) do
          {:ok, start} ->
            {:ok,
             {[
                "ARRAY_POSITION(",
                operation.column,
                ", ",
                {:param, operation.value},
                ", ",
                {:param, start},
                ")"
              ], [operation.value, start]}}

          :error ->
            one_param("ARRAY_POSITION", operation.column, operation.value)
        end

      :array_positions ->
        one_param("ARRAY_POSITIONS", operation.column, operation.value)

      :array_remove ->
        one_param("ARRAY_REMOVE", operation.column, operation.value)

      :array_replace ->
        new_value = Map.get(operation.options, :new_value)

        {:ok,
         {[
            "ARRAY_REPLACE(",
            operation.column,
            ", ",
            {:param, operation.value},
            ", ",
            {:param, new_value},
            ")"
          ], [operation.value, new_value]}}

      :unnest ->
        suffix = if Map.get(operation.options, :with_ordinality), do: " WITH ORDINALITY", else: ""
        {:ok, ["UNNEST(", operation.column, ")", suffix]}

      :array_to_string ->
        transform("ARRAY_TO_STRING", operation)

      :string_to_array ->
        transform("STRING_TO_ARRAY", operation)

      kind when kind in [:array_union, :array_intersect, :array_except] ->
        one_param(kind |> Atom.to_string() |> String.upcase(), operation.column, operation.value)
    end
  end

  def render_hierarchy_adjacency(%Adjacency{} = hierarchy, _selecto) do
    {:ok,
     [
       hierarchy.cte_name,
       " AS (",
       "SELECT #{hierarchy.id_field}, #{hierarchy.name_field}, #{hierarchy.parent_field}, 0 as level, ",
       "CAST(#{hierarchy.id_field} AS TEXT) as path, ARRAY[#{hierarchy.id_field}] as path_array ",
       "FROM #{hierarchy.source_table} WHERE #{hierarchy.parent_field} IS NULL",
       " UNION ALL ",
       "SELECT c.#{hierarchy.id_field}, c.#{hierarchy.name_field}, c.#{hierarchy.parent_field}, h.level + 1, ",
       "h.path || '/' || CAST(c.#{hierarchy.id_field} AS TEXT), h.path_array || c.#{hierarchy.id_field} ",
       "FROM #{hierarchy.source_table} c JOIN #{hierarchy.cte_name} h ON c.#{hierarchy.parent_field} = h.#{hierarchy.id_field} ",
       "WHERE h.level < ",
       {:param, hierarchy.depth_limit},
       ")"
     ]}
  end

  def render_hierarchy_materialized_path(%MaterializedPath{} = hierarchy, _selecto) do
    {:ok,
     [
       hierarchy.query_name,
       " AS (",
       "SELECT *, ",
       "(length(#{hierarchy.path_field}) - length(replace(#{hierarchy.path_field}, '#{hierarchy.path_separator}', ''))) as depth, ",
       "string_to_array(#{hierarchy.path_field}, '#{hierarchy.path_separator}') as path_array ",
       "FROM #{hierarchy.source_table} ",
       "WHERE #{hierarchy.path_field} LIKE ",
       {:param, hierarchy.path_pattern},
       ")"
     ]}
  end

  def render_table_function_join(%TableFunctionJoin{} = join, _selecto) do
    alias_sql = portable_alias(join.alias)

    source =
      case join.ordinality_alias do
        nil ->
          [join.source_sql, " AS ", alias_sql]

        ordinality_alias ->
          [
            join.source_sql,
            " WITH ORDINALITY AS ",
            alias_sql,
            "(",
            portable_alias("value"),
            ", ",
            portable_alias(ordinality_alias),
            ")"
          ]
      end

    join_sql = join.join_type |> Atom.to_string() |> String.upcase()

    if join.join_type == :cross,
      do: {:ok, [join_sql, " JOIN LATERAL ", source]},
      else: {:ok, [join_sql, " JOIN LATERAL ", source, " ON true"]}
  end

  def render_window_frame_boundary(%FrameBoundary{} = boundary, _selecto) do
    {:ok,
     [
       "INTERVAL '",
       boundary.amount,
       " ",
       Atom.to_string(boundary.unit),
       "' ",
       boundary.direction |> Atom.to_string() |> String.upcase()
     ]}
  end

  defp portable_alias(identifier) do
    identifier = to_string(identifier)

    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, identifier),
      do: identifier,
      else: SelectoDBPostgreSQL.Adapter.quote_identifier(identifier)
  end

  def render_view_definition(%Definition{} = definition, _context) do
    create = if definition.kind == :view, do: "CREATE VIEW", else: "CREATE MATERIALIZED VIEW"

    {:ok,
     [
       create,
       " ",
       Selecto.SQL.QualifiedIdentifier.quote!(
         definition.database_name,
         SelectoDBPostgreSQL.Adapter
       ),
       " AS\n",
       definition.query_sql,
       ";"
     ]}
  end

  def render_view_refresh(%Refresh{} = refresh, _context) do
    concurrently = if refresh.concurrently, do: " CONCURRENTLY", else: ""

    {:ok,
     [
       "REFRESH MATERIALIZED VIEW",
       concurrently,
       " ",
       Selecto.SQL.QualifiedIdentifier.quote!(refresh.database_name, SelectoDBPostgreSQL.Adapter),
       ";"
     ]}
  end

  def render_view_index(%Index{} = index, _context) do
    create = if index.unique, do: "CREATE UNIQUE INDEX", else: "CREATE INDEX"
    concurrently = if index.concurrently, do: " CONCURRENTLY", else: ""

    columns =
      index.columns
      |> Enum.map(&SelectoDBPostgreSQL.Adapter.quote_identifier/1)
      |> Enum.intersperse(", ")

    {:ok,
     [
       create,
       concurrently,
       " ",
       SelectoDBPostgreSQL.Adapter.quote_identifier(index.index_name),
       " ON ",
       Selecto.SQL.QualifiedIdentifier.quote!(index.database_name, SelectoDBPostgreSQL.Adapter),
       " (",
       columns,
       ");"
     ]}
  end

  defp collection_operator(:array_contains), do: "@>"
  defp collection_operator(:array_contained), do: "<@"
  defp collection_operator(:array_overlap), do: "&&"
  defp collection_operator(:array_eq), do: "="

  defp order_by([]), do: []

  defp order_by(order_by) do
    [
      " ORDER BY ",
      order_by
      |> Enum.map(fn {column, direction} ->
        [column, " ", direction |> Atom.to_string() |> String.upcase()]
      end)
      |> Enum.intersperse(", ")
    ]
  end

  defp one_param(function, column, value),
    do: {:ok, {[function, "(", column, ", ", {:param, value}, ")"], [value]}}

  defp transform(function, operation) do
    delimiter = operation.value || ","

    case Map.get(operation.options, :null_string) do
      nil ->
        {:ok, {[function, "(", operation.column, ", ", {:param, delimiter}, ")"], [delimiter]}}

      null_string ->
        {:ok,
         {[
            function,
            "(",
            operation.column,
            ", ",
            {:param, delimiter},
            ", ",
            {:param, null_string},
            ")"
          ], [delimiter, null_string]}}
    end
  end

  def render_interval(%Selecto.Dialect.Interval{amount: amount, unit: unit}, _selecto) do
    {:ok, ["interval '", Integer.to_string(amount), " ", Atom.to_string(unit), "'"]}
  end

  def render_text_search_predicate(%Predicate{selectors: [selector]} = predicate, _selecto) do
    case predicate.mode do
      mode when mode in [nil, :websearch] ->
        predicate(selector, "websearch_to_tsquery", predicate.query)

      mode when mode in [:plain, :natural] ->
        predicate(selector, "plainto_tsquery", predicate.query)

      :phrase ->
        predicate(selector, "phraseto_tsquery", predicate.query)

      :boolean ->
        predicate(selector, "to_tsquery", predicate.query)

      _mode ->
        {:error,
         Selecto.Error.validation_error(
           "Adapter does not support this text search mode",
           %{}
         )}
    end
  end

  def render_text_search_rank(%Rank{fields: [field], query: query, weights: []} = rank, selecto)
      when not is_nil(query) do
    conf = column_conf(selecto, field)
    field_ref = Map.get(conf, :field, field)

    function =
      case rank.mode do
        mode when mode in [nil, :websearch] -> :websearch_to_tsquery
        mode when mode in [:plain, :natural] -> :plainto_tsquery
        :phrase -> :phraseto_tsquery
        :boolean -> :to_tsquery
      end

    {:ok,
     {:field, {:func, :ts_rank, [to_string(field_ref), {:func, function, [{:literal, query}]}]},
      rank.alias}}
  end

  def render_text_search_rank(%Rank{query: nil}, _selecto),
    do: error("PostgreSQL text_search_rank/3 requires a :query option")

  defp column_conf(selecto, field) do
    columns = selecto |> Map.get(:config, %{}) |> Map.get(:columns, %{})
    Map.get(columns, field) || Map.get(columns, String.to_existing_atom(field))
  end

  defp predicate(selector, function, query) do
    {:ok, [" ", selector, " @@ ", function, "(", {:param, query}, ") "]}
  end

  defp error(message), do: {:error, Selecto.Error.validation_error(message, %{})}
end

defmodule Selecto.TestDialect.MySQL do
  alias Selecto.Dialect.TextSearch.{Predicate, Rank}
  alias Selecto.Dialect.Window.FrameBoundary

  def render_json_extraction(fragment, _selecto),
    do: Selecto.TestDialect.Json.extraction(:mysql, fragment)

  def render_json_contains(fragment, _selecto),
    do: Selecto.TestDialect.Json.contains(:mysql, fragment)

  def render_json_key_exists(fragment, _selecto),
    do: Selecto.TestDialect.Json.key_exists(:mysql, fragment)

  def render_json_array_contains(fragment, _selecto),
    do: Selecto.TestDialect.Json.array_contains(:mysql, fragment)

  def render_json_array_contains_all(fragment, _selecto),
    do: Selecto.TestDialect.Json.array_contains_all(:mysql, fragment)

  def render_json_operation(fragment, _selecto),
    do: Selecto.TestDialect.Json.operation(:mysql, fragment)

  def render_collection_operation(fragment, _selecto),
    do: Selecto.TestDialect.Collection.render(:mysql, fragment)

  def render_window_frame_boundary(%FrameBoundary{} = boundary, _selecto) do
    {:ok,
     [
       "INTERVAL ",
       boundary.amount,
       " ",
       boundary.unit |> Atom.to_string() |> String.upcase(),
       " ",
       boundary.direction |> Atom.to_string() |> String.upcase()
     ]}
  end

  def render_text_search_predicate(%Predicate{} = predicate, _selecto) do
    {:ok,
     [
       " MATCH(",
       Enum.intersperse(predicate.selectors, ", "),
       ") AGAINST (",
       {:param, predicate.query},
       mode_sql(predicate.mode),
       ") "
     ]}
  end

  def render_text_search_rank(%Rank{query: nil}, _selecto),
    do:
      {:error,
       Selecto.Error.validation_error("MySQL text_search_rank/3 requires a :query option", %{})}

  def render_text_search_rank(%Rank{} = rank, selecto) do
    columns = selecto |> Map.get(:config, %{}) |> Map.get(:columns, %{})

    missing =
      Enum.reject(rank.fields, fn field ->
        atom = safe_existing_atom(field)
        Map.has_key?(columns, field) or (not is_nil(atom) and Map.has_key?(columns, atom))
      end)

    if missing != [] do
      {:error,
       Selecto.Error.validation_error("MySQL text_search_rank/3 field not found", %{
         fields: missing
       })}
    else
      refs =
        rank.fields
        |> Enum.map(fn field ->
          [
            Selecto.Builder.Sql.Helpers.quote_identifier(selecto, "selecto_root"),
            ".",
            Selecto.Builder.Sql.Helpers.quote_identifier(selecto, field)
          ]
        end)
        |> Enum.intersperse(", ")

      {:ok,
       {:custom_sql,
        [
          "MATCH(",
          refs,
          ") AGAINST (",
          {:param, rank.query},
          mode_sql(rank.mode),
          ") AS ",
          Selecto.Builder.Sql.Helpers.force_quote_identifier(selecto, rank.alias)
        ], %{}}}
    end
  end

  defp mode_sql(mode) when mode in [nil, :natural, :websearch, :plain],
    do: " IN NATURAL LANGUAGE MODE"

  defp mode_sql(:boolean), do: " IN BOOLEAN MODE"
  defp mode_sql(:query_expansion), do: " IN NATURAL LANGUAGE MODE WITH QUERY EXPANSION"

  defp safe_existing_atom(field) do
    try do
      String.to_existing_atom(field)
    rescue
      ArgumentError -> nil
    end
  end
end

defmodule Selecto.TestDialect.SQLite do
  alias Selecto.Dialect.TextSearch.{Predicate, Rank}

  def render_json_extraction(fragment, _selecto),
    do: Selecto.TestDialect.Json.extraction(:sqlite, fragment)

  def render_json_contains(fragment, _selecto),
    do: Selecto.TestDialect.Json.contains(:sqlite, fragment)

  def render_json_key_exists(fragment, _selecto),
    do: Selecto.TestDialect.Json.key_exists(:sqlite, fragment)

  def render_json_array_contains(fragment, _selecto),
    do: Selecto.TestDialect.Json.array_contains(:sqlite, fragment)

  def render_json_array_contains_all(fragment, _selecto),
    do: Selecto.TestDialect.Json.array_contains_all(:sqlite, fragment)

  def render_json_operation(fragment, _selecto),
    do: Selecto.TestDialect.Json.operation(:sqlite, fragment)

  def render_collection_operation(fragment, _selecto),
    do: Selecto.TestDialect.Collection.render(:sqlite, fragment)

  def render_text_search_predicate(%Predicate{} = predicate, selecto) do
    invalid =
      Enum.reject(predicate.fields, fn %{config: conf} ->
        Map.get(conf, :type) == :fts5 or Map.get(conf, :sqlite_fts5) == true or
          Map.get(conf, :text_search_backend) == :fts5
      end)

    cond do
      invalid != [] ->
        {:error,
         Selecto.Error.validation_error(
           "SQLite text search requires an FTS5-configured field",
           %{}
         )}

      not runtime_available?(selecto) ->
        {:error,
         Selecto.Error.validation_error(
           "SQLite FTS5 is not available on the current connection",
           %{}
         )}

      predicate.mode not in [nil, :websearch, :boolean, :phrase] ->
        {:error,
         Selecto.Error.validation_error(
           "SQLite FTS5 search does not support this text search mode",
           %{}
         )}

      true ->
        query = phrase_query(predicate.query, predicate.mode)
        clauses = Enum.map(predicate.selectors, &[&1, " MATCH ", {:param, query}])

        sql =
          if length(clauses) == 1,
            do: [" ", hd(clauses), " "],
            else: [" (", Enum.intersperse(clauses, " OR "), ") "]

        {:ok, sql}
    end
  end

  def render_text_search_rank(%Rank{} = rank, selecto) do
    unless Enum.all?(rank.weights, &is_number/1) do
      {:error, Selecto.Error.validation_error("weights must contain only numbers", %{})}
    else
      source = selecto.domain.source.source_table

      weights =
        if rank.weights == [],
          do: [],
          else: [", ", Enum.intersperse(Enum.map(rank.weights, &to_string/1), ", ")]

      {:ok,
       {:custom_sql,
        [
          "bm25(",
          Selecto.Builder.Sql.Helpers.quote_identifier(selecto, source),
          weights,
          ") AS ",
          Selecto.Builder.Sql.Helpers.force_quote_identifier(selecto, rank.alias)
        ], %{}}}
    end
  end

  defp runtime_available?(selecto) do
    adapter = Map.get(selecto, :adapter)
    connection = Selecto.Runtime.Context.connection(selecto)

    connection in [nil, [], %{}] or
      not Selecto.AdapterSupport.callback_available?(adapter, :fts5_available?, 1) or
      adapter.fts5_available?(connection)
  end

  defp phrase_query(value, :phrase) when is_binary(value),
    do: ~s("#{String.replace(value, "\"", "\"\"")}")

  defp phrase_query(value, _mode), do: value
end

defmodule Selecto.TestDialect.MSSQL do
  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation
  alias Selecto.Dialect.Predicate.Comparison
  alias Selecto.Dialect.TableFunction.Join, as: TableFunctionJoin
  alias Selecto.Dialect.Window.FrameBoundary

  def render_json_extraction(fragment, _selecto),
    do: Selecto.TestDialect.Json.extraction(:mssql, fragment)

  def render_json_contains(fragment, _selecto),
    do: Selecto.TestDialect.Json.contains(:mssql, fragment)

  def render_json_key_exists(fragment, _selecto),
    do: Selecto.TestDialect.Json.key_exists(:mssql, fragment)

  def render_json_array_contains(fragment, _selecto),
    do: Selecto.TestDialect.Json.array_contains(:mssql, fragment)

  def render_json_array_contains_all(fragment, _selecto),
    do: Selecto.TestDialect.Json.array_contains_all(:mssql, fragment)

  def render_json_operation(fragment, _selecto),
    do: Selecto.TestDialect.Json.operation(:mssql, fragment)

  def render_collection_operation(fragment, _selecto),
    do: Selecto.TestDialect.Collection.render(:mssql, fragment)

  def render_datetime_operation(%DateTimeOperation{operation: :format} = operation, _selecto) do
    {:ok,
     apply(SelectoDBMSSQL.Adapter, :format_datetime, [
       operation.expression,
       Map.fetch!(operation.options, :format)
     ])}
  end

  def render_comparison(%Comparison{} = comparison, _selecto) do
    operator = if comparison.operation == :case_insensitive_not_like, do: "NOT LIKE", else: "LIKE"
    {:ok, ["LOWER(", comparison.left, ") ", operator, " LOWER(", comparison.right, ")"]}
  end

  def render_table_function_join(%TableFunctionJoin{ordinality_alias: nil} = join, _selecto) do
    case join.join_type do
      type when type in [:cross, :inner] ->
        {:ok, ["CROSS APPLY ", join.source_sql, " AS [", join.alias, "]"]}

      :left ->
        {:ok, ["OUTER APPLY ", join.source_sql, " AS [", join.alias, "]"]}

      type ->
        {:error,
         Selecto.Error.validation_error(
           "MSSQL APPLY only supports :inner and :left lateral joins",
           %{join_type: type, unsupported_feature: :table_function_join}
         )}
    end
  end

  def render_window_frame_boundary(%FrameBoundary{} = boundary, _selecto) do
    {:error,
     Selecto.Error.validation_error("MSSQL window frames do not support interval boundaries", %{
       adapter: :mssql,
       frame_boundary: boundary,
       unsupported_feature: :window_interval_frame
     })}
  end
end

defmodule Selecto.TestDialect.Collection do
  alias Selecto.Dialect.Collection.Operation

  def render(style, %Operation{} = operation) do
    case {style, operation.operation} do
      {:mysql, :array_agg} when not operation.distinct and operation.order_by in [nil, []] ->
        {:ok, ["JSON_ARRAYAGG(", operation.column, ")"]}

      {:sqlite, :array_agg} when operation.order_by in [nil, []] ->
        distinct = if operation.distinct, do: "DISTINCT ", else: ""
        {:ok, ["json_group_array(", distinct, operation.column, ")"]}

      {:mysql, :string_agg} ->
        delimiter = Map.get(operation.options, :delimiter, ",")
        distinct = if operation.distinct, do: "DISTINCT ", else: ""

        {:ok,
         {[
            "GROUP_CONCAT(",
            distinct,
            operation.column,
            mysql_order_by(operation.order_by),
            " SEPARATOR ",
            {:param, delimiter},
            ")"
          ], [delimiter]}}

      {:sqlite, :string_agg}
      when not operation.distinct and operation.order_by in [nil, []] ->
        delimiter = Map.get(operation.options, :delimiter, ",")
        {:ok, {["group_concat(", operation.column, ", ", {:param, delimiter}, ")"], [delimiter]}}

      {:mssql, :string_agg} when not operation.distinct ->
        delimiter = Map.get(operation.options, :delimiter, ",")

        within_group =
          case operation.order_by do
            order_by when order_by in [nil, []] -> []
            order_by -> [" WITHIN GROUP (ORDER BY ", order_parts(order_by), ")"]
          end

        {:ok,
         {[
            "STRING_AGG(",
            operation.column,
            ", ",
            {:param, delimiter},
            ")",
            within_group
          ], [delimiter]}}

      {_style, unsupported} ->
        {:error,
         Selecto.Error.validation_error("Adapter does not support this collection operation", %{
           operation: unsupported,
           unsupported_feature: :collection_operation
         })}
    end
  end

  defp mysql_order_by(order_by) when order_by in [nil, []], do: []
  defp mysql_order_by(order_by), do: [" ORDER BY ", order_parts(order_by)]

  defp order_parts(order_by) do
    order_by
    |> Enum.map(fn {expression, direction} ->
      [expression, " ", direction |> Atom.to_string() |> String.upcase()]
    end)
    |> Enum.intersperse(", ")
  end
end
