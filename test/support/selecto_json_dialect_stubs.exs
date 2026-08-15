defmodule Selecto.TestDialect.Json do
  alias Selecto.Dialect.Json.{
    ArrayContains,
    ArrayContainsAll,
    Contains,
    Extraction,
    KeyExists,
    Operation
  }

  def extraction(style, %Extraction{} = fragment) do
    column = column_ref(style, fragment)
    path = json_path(fragment.path)

    sql =
      case style do
        :postgresql ->
          postgres_extraction(column, fragment)

        :mysql ->
          ["JSON_EXTRACT(", column, ", '", path, "')"] |> maybe_unquote(fragment.as_text)

        :sqlite ->
          ["json_extract(", column, ", '", path, "')"]

        :mssql ->
          [
            if(fragment.as_text, do: "JSON_VALUE", else: "JSON_QUERY"),
            "(",
            column,
            ", '",
            path,
            "')"
          ]
      end

    {:ok, cast(style, sql, fragment.cast)}
  end

  def contains(:postgresql, %Contains{} = fragment) do
    {:ok, [column_ref(:postgresql, fragment), " @> '", encoded(fragment.value), "'::jsonb"]}
  end

  def contains(:mysql, %Contains{} = fragment) do
    {:ok, ["JSON_CONTAINS(", column_ref(:mysql, fragment), ", '", encoded(fragment.value), "')"]}
  end

  def contains(style, %Contains{value: value} = fragment)
      when style in [:sqlite, :mssql] and is_map(value) do
    if nested_list?(value) do
      label = if style == :mssql, do: "MSSQL", else: "SQLite"

      {:error,
       Selecto.Error.validation_error(
         "#{label} JSON containment for arrays is not supported",
         %{unsupported_feature: :json_contains_array}
       )}
    else
      clauses =
        value
        |> flatten([])
        |> Enum.map(fn {path, item} ->
          case style do
            :sqlite ->
              [
                "json_extract(",
                column_ref(style, fragment),
                ", '",
                json_path(path),
                "') = ",
                literal(style, item)
              ]

            :mssql ->
              [
                "JSON_VALUE(",
                column_ref(style, fragment),
                ", '",
                json_path(path),
                "') = '",
                escape(item),
                "'"
              ]
          end
        end)
        |> Enum.intersperse(" AND ")

      {:ok, clauses}
    end
  end

  def contains(style, %Contains{value: value}) do
    {:error,
     Selecto.Error.validation_error("#{style} JSON containment does not support arrays", %{
       value: value
     })}
  end

  def key_exists(:postgresql, %KeyExists{path: [key]} = fragment) do
    {:ok, [column_ref(:postgresql, fragment), " ? '", escape(key), "'"]}
  end

  def key_exists(:postgresql, %KeyExists{} = fragment) do
    {parent, [key]} = Enum.split(fragment.path, -1)

    {:ok, extraction} =
      extraction(:postgresql, %Extraction{
        column: fragment.column,
        path: parent,
        as_text: false,
        table_alias: fragment.table_alias
      })

    {:ok, [extraction, " ? '", escape(key), "'"]}
  end

  def key_exists(:mysql, %KeyExists{} = fragment) do
    {:ok,
     [
       "JSON_CONTAINS_PATH(",
       column_ref(:mysql, fragment),
       ", 'one', '",
       json_path(fragment.path),
       "')"
     ]}
  end

  def key_exists(:sqlite, %KeyExists{} = fragment) do
    {:ok,
     [
       "json_type(",
       column_ref(:sqlite, fragment),
       ", '",
       json_path(fragment.path),
       "') IS NOT NULL"
     ]}
  end

  def key_exists(:mssql, %KeyExists{} = fragment) do
    column = column_ref(:mssql, fragment)
    path = json_path(fragment.path)

    {:ok,
     [
       "(JSON_QUERY(",
       column,
       ", '",
       path,
       "') IS NOT NULL OR JSON_VALUE(",
       column,
       ", '",
       path,
       "') IS NOT NULL)"
     ]}
  end

  def array_contains(:postgresql, %ArrayContains{} = fragment) do
    {:ok, array} =
      extraction(:postgresql, %Extraction{
        column: fragment.column,
        path: fragment.path,
        as_text: false,
        table_alias: fragment.table_alias
      })

    case fragment.value do
      value when is_binary(value) -> {:ok, [array, " ? '", escape(value), "'"]}
      values when is_list(values) -> {:ok, [array, " ?| array[", quoted_values(values), "]"]}
    end
  end

  def array_contains(:mysql, %ArrayContains{value: values} = fragment) when is_list(values),
    do: combine(values, " OR ", &array_contains(:mysql, %{fragment | value: &1}))

  def array_contains(:mysql, %ArrayContains{} = fragment) do
    {:ok,
     [
       "JSON_CONTAINS(",
       column_ref(:mysql, fragment),
       ", '",
       encoded(fragment.value),
       "', '",
       json_path(fragment.path),
       "')"
     ]}
  end

  def array_contains(:sqlite, %ArrayContains{value: values} = fragment) when is_list(values),
    do: combine(values, " OR ", &array_contains(:sqlite, %{fragment | value: &1}))

  def array_contains(:sqlite, %ArrayContains{} = fragment) do
    {:ok,
     [
       "EXISTS (SELECT 1 FROM json_each(",
       column_ref(:sqlite, fragment),
       ", '",
       json_path(fragment.path),
       "') WHERE value = '",
       escape(fragment.value),
       "')"
     ]}
  end

  def array_contains(:mssql, %ArrayContains{value: values} = fragment) when is_list(values),
    do: combine(values, " OR ", &array_contains(:mssql, %{fragment | value: &1}))

  def array_contains(:mssql, %ArrayContains{} = fragment) do
    {:ok,
     [
       "EXISTS (SELECT 1 FROM OPENJSON(",
       column_ref(:mssql, fragment),
       ", '",
       json_path(fragment.path),
       "') WHERE value = '",
       escape(fragment.value),
       "')"
     ]}
  end

  def array_contains_all(:postgresql, %ArrayContainsAll{} = fragment) do
    {:ok, array} =
      extraction(:postgresql, %Extraction{
        column: fragment.column,
        path: fragment.path,
        as_text: false,
        table_alias: fragment.table_alias
      })

    {:ok, [array, " ?& array[", quoted_values(fragment.values), "]"]}
  end

  def array_contains_all(style, %ArrayContainsAll{} = fragment) do
    combine(fragment.values, " AND ", fn value ->
      array_contains(style, %ArrayContains{
        column: fragment.column,
        path: fragment.path,
        value: value,
        table_alias: fragment.table_alias
      })
    end)
  end

  def operation(style, %Operation{} = operation) do
    case operation.operation do
      :json_extract ->
        operation_extraction(style, operation, false)

      :json_extract_text ->
        operation_extraction(style, operation, true)

      :json_contains ->
        contains(style, operation_contains(operation))

      :json_contained when style == :postgresql ->
        {:ok, [column_ref(style, operation), " <@ '", encoded(operation.value), "'::jsonb"]}

      :json_contained ->
        unsupported(style, operation.operation)

      kind when kind in [:json_exists, :json_path_exists] ->
        key_exists(style, operation_key_exists(operation))

      :json_agg when style == :postgresql ->
        {:ok, ["json_agg(", column_ref(style, operation), ")"]}

      :json_agg when style == :mysql ->
        {:ok, ["JSON_ARRAYAGG(", column_ref(style, operation), ")"]}

      :json_object_agg when style == :postgresql ->
        {:ok,
         [
           "json_object_agg(",
           operation_field(style, operation, :key_sql, operation.key_field),
           ", ",
           operation_field(style, operation, :value_sql, operation.value_field),
           ")"
         ]}

      :json_object_agg when style == :mysql ->
        {:ok,
         [
           "JSON_OBJECTAGG(",
           operation_field(style, operation, :key_sql, operation.key_field),
           ", ",
           operation_field(style, operation, :value_sql, operation.value_field),
           ")"
         ]}

      :json_build_object when style in [:postgresql, :mysql] ->
        function = if style == :postgresql, do: "json_build_object", else: "JSON_OBJECT"
        pairs = Map.get(operation.options || %{}, :pairs_sql) || object_pairs(operation.value)
        {:ok, [function, "(", pairs, ")"]}

      :json_build_object when style == :sqlite ->
        {:ok, ["json_object(", Map.fetch!(operation.options, :pairs_sql), ")"]}

      :json_build_array when style in [:postgresql, :mysql] ->
        function = if style == :postgresql, do: "json_build_array", else: "JSON_ARRAY"
        {:ok, [function, "(", json_values(operation.value), ")"]}

      :json_empty_array when style == :postgresql ->
        {:ok, "'[]'::json"}

      :json_empty_array when style == :mysql ->
        {:ok, "JSON_ARRAY()"}

      :json_empty_array when style in [:sqlite, :mssql] ->
        {:ok, "'[]'"}

      :json_agg when style == :sqlite ->
        {:ok, ["json_group_array(", column_ref(style, operation), ")"]}

      :json_set when style in [:postgresql, :mysql] ->
        operation_mutation(style, "SET", operation)

      :json_remove when style == :postgresql ->
        {:ok, [column_ref(style, operation), " #- ", postgres_path(operation.path)]}

      :json_remove when style == :mysql ->
        {:ok,
         [
           "JSON_REMOVE(",
           column_ref(style, operation),
           ", '",
           operation.path |> operation_path() |> json_path(),
           "')"
         ]}

      :json_typeof when style == :postgresql ->
        {:ok, ["JSONB_TYPEOF(", column_ref(style, operation), ")"]}

      :json_typeof when style == :mysql ->
        {:ok, ["JSON_TYPE(", column_ref(style, operation), ")"]}

      :json_typeof when style == :sqlite ->
        {:ok, sqlite_path_function("json_type", operation)}

      :json_array_length when style == :postgresql ->
        {:ok, ["JSONB_ARRAY_LENGTH(", column_ref(style, operation), ")"]}

      :json_array_length when style == :mysql ->
        {:ok, mysql_path_function("JSON_LENGTH", operation)}

      :json_array_length when style == :sqlite ->
        {:ok, sqlite_path_function("json_array_length", operation)}

      _operation ->
        unsupported(style, operation.operation)
    end
  end

  defp operation_extraction(style, operation, as_text) do
    extraction(style, %Extraction{
      column: operation.column,
      path: operation_path(operation.path),
      as_text: as_text,
      table_alias: operation.table_alias
    })
  end

  defp operation_field(style, operation, key, field) do
    Map.get(operation.options || %{}, key) ||
      column_ref(style, %{column: field, table_alias: nil})
  end

  defp operation_contains(operation) do
    %Contains{
      column: operation.column,
      value: operation.value,
      table_alias: operation.table_alias
    }
  end

  defp operation_key_exists(operation) do
    %KeyExists{
      column: operation.column,
      path: operation_path(operation.path),
      table_alias: operation.table_alias
    }
  end

  defp operation_mutation(:postgresql, suffix, operation) do
    {:ok,
     [
       "JSONB_",
       suffix,
       "(",
       column_ref(:postgresql, operation),
       ", ",
       postgres_path(operation.path),
       ", ",
       json_value(operation.value),
       ")"
     ]}
  end

  defp operation_mutation(:mysql, suffix, operation) do
    {:ok,
     [
       "JSON_",
       suffix,
       "(",
       column_ref(:mysql, operation),
       ", '",
       operation.path |> operation_path() |> json_path(),
       "', ",
       json_value(operation.value),
       ")"
     ]}
  end

  defp mysql_path_function(function, %{path: nil} = operation),
    do: [function, "(", column_ref(:mysql, operation), ")"]

  defp mysql_path_function(function, operation) do
    [
      function,
      "(",
      column_ref(:mysql, operation),
      ", '",
      operation.path |> operation_path() |> json_path(),
      "')"
    ]
  end

  defp sqlite_path_function(function, %{path: nil} = operation),
    do: [function, "(", column_ref(:sqlite, operation), ")"]

  defp sqlite_path_function(function, operation) do
    [
      function,
      "(",
      column_ref(:sqlite, operation),
      ", '",
      operation.path |> operation_path() |> json_path(),
      "')"
    ]
  end

  defp postgres_path(path),
    do: ["ARRAY[", operation_path(path) |> quoted_values(", "), "]"]

  defp operation_path(nil), do: []

  defp operation_path(path) do
    path
    |> String.replace_prefix("$.", "")
    |> String.split(~r/[\.\[\]]/, trim: true)
  end

  defp object_pairs(pairs) do
    pairs
    |> Enum.map(fn {key, value} -> [json_value(to_string(key)), ", ", json_value(value)] end)
    |> Enum.intersperse(", ")
  end

  defp json_values(values), do: values |> Enum.map(&json_value/1) |> Enum.intersperse(", ")

  defp json_value(value) when is_binary(value), do: ["'", escape(value), "'"]
  defp json_value(value) when is_integer(value), do: Integer.to_string(value)
  defp json_value(value) when is_float(value), do: Float.to_string(value)
  defp json_value(true), do: "true"
  defp json_value(false), do: "false"
  defp json_value(nil), do: "null"
  defp json_value(value), do: ["'", encoded(value), "'"]

  defp unsupported(style, operation) do
    {:error,
     Selecto.Error.validation_error("#{style} does not support this JSON operation", %{
       operation: operation,
       unsupported_feature: :json_operation
     })}
  end

  defp postgres_extraction(column, %Extraction{path: [key], as_text: as_text}) do
    [column, if(as_text, do: "->>", else: "->"), "'", escape(key), "'"]
  end

  defp postgres_extraction(column, %Extraction{path: path, as_text: as_text}) do
    [column, if(as_text, do: "#>>", else: "#>"), "ARRAY[", quoted_values(path, ", "), "]"]
  end

  defp column_ref(_style, %{options: options}) when is_map_key(options, :column_sql),
    do: Map.fetch!(options, :column_sql)

  defp column_ref(style, %{column: column, table_alias: table_alias}) do
    quote = fn value ->
      case style do
        :mysql ->
          "`#{String.replace(to_string(value), "`", "``")}`"

        :mssql ->
          escaped = value |> to_string() |> String.replace("]", "]]")
          "[#{escaped}]"

        _ ->
          ~s("#{String.replace(to_string(value), "\"", "\"\"")}")
      end
    end

    if table_alias, do: [quote.(table_alias), ".", quote.(column)], else: quote.(column)
  end

  defp json_path(path) do
    path
    |> Enum.reduce("$", fn segment, acc ->
      case Integer.parse(to_string(segment)) do
        {index, ""} -> acc <> "[#{index}]"
        _ -> acc <> "." <> to_string(segment)
      end
    end)
    |> escape()
  end

  defp maybe_unquote(sql, true), do: ["JSON_UNQUOTE(", sql, ")"]
  defp maybe_unquote(sql, false), do: sql

  defp cast(_style, sql, nil), do: sql
  defp cast(:postgresql, sql, :decimal), do: ["(", sql, ")::numeric"]
  defp cast(:postgresql, sql, :integer), do: ["(", sql, ")::integer"]
  defp cast(:mysql, sql, :decimal), do: ["CAST(", sql, " AS DECIMAL(38, 10))"]
  defp cast(:sqlite, sql, :decimal), do: ["CAST(", sql, " AS NUMERIC)"]
  defp cast(:mssql, sql, :decimal), do: ["CAST(", sql, " AS decimal(38, 10))"]
  defp cast(_style, sql, _cast), do: sql

  defp flatten(map, prefix) do
    Enum.flat_map(map, fn
      {key, nested} when is_map(nested) -> flatten(nested, prefix ++ [to_string(key)])
      {key, value} -> [{prefix ++ [to_string(key)], value}]
    end)
  end

  defp nested_list?(map) when is_map(map) do
    Enum.any?(map, fn
      {_key, value} when is_list(value) -> true
      {_key, value} when is_map(value) -> nested_list?(value)
      _pair -> false
    end)
  end

  defp literal(:sqlite, value) when is_binary(value), do: ["'", escape(value), "'"]
  defp literal(:sqlite, value) when is_integer(value), do: Integer.to_string(value)
  defp literal(:sqlite, value), do: ["'", escape(value), "'"]

  defp combine(values, separator, renderer) do
    values
    |> Enum.map(fn value -> renderer.(value) |> elem(1) end)
    |> Enum.intersperse(separator)
    |> then(&{:ok, &1})
  end

  defp quoted_values(values, separator \\ ",") do
    values |> Enum.map(&["'", escape(&1), "'"]) |> Enum.intersperse(separator)
  end

  defp encoded(value), do: value |> Jason.encode!() |> escape()
  defp escape(value), do: value |> to_string() |> String.replace("'", "''")
end
