defmodule Selecto.Json do
  @moduledoc """
  Portable structured-JSON field paths and query intent.

  Core parses domain paths and schema evidence. The configured adapter dialect
  owns native extraction, containment, existence, and array-membership SQL.
  """

  alias Selecto.Dialect.Json.{ArrayContains, ArrayContainsAll, Contains, Extraction, KeyExists}

  @doc "Parses a JSON dot path or returns a regular field reference."
  def parse_field_reference(field, domain) when is_binary(field) do
    columns = Map.get(domain, :columns, %{})

    if String.contains?(field, ".") do
      [first | rest] = String.split(field, ".")

      case Map.get(columns, first) || Map.get(columns, safe_existing_atom(first)) do
        %{type: :json} -> {:json_path, first, rest}
        _ -> {:regular, field}
      end
    else
      {:regular, field}
    end
  end

  def parse_field_reference(field, _domain), do: {:regular, field}

  @doc "Returns nested schema evidence for a JSON path."
  def get_path_schema(domain, column, path) when is_list(path) do
    columns = Map.get(domain, :columns, %{})

    case Map.get(columns, column) || Map.get(columns, safe_existing_atom(column)) do
      %{type: :json, schema: schema} -> traverse_schema(schema, path)
      _ -> nil
    end
  end

  @doc "Renders a JSON path extraction through the configured adapter dialect."
  def build_extraction(column, path, opts \\ []) do
    fragment = %Extraction{
      column: to_string(column),
      path: normalize_path_segments(path),
      as_text: Keyword.get(opts, :as_text, true),
      cast: Keyword.get(opts, :cast),
      table_alias: normalize_alias(Keyword.get(opts, :table_alias))
    }

    render!(:render_json_extraction, fragment, opts)
  end

  @doc "Renders JSON containment through the configured adapter dialect."
  def build_contains(column, value, opts \\ []) do
    render!(
      :render_json_contains,
      %Contains{
        column: to_string(column),
        value: value,
        table_alias: normalize_alias(Keyword.get(opts, :table_alias))
      },
      opts
    )
  end

  @doc "Renders JSON key/path existence through the configured adapter dialect."
  def build_key_exists(column, key_or_path, opts \\ []) do
    render!(
      :render_json_key_exists,
      %KeyExists{
        column: to_string(column),
        path: normalize_path_segments(key_or_path),
        table_alias: normalize_alias(Keyword.get(opts, :table_alias))
      },
      opts
    )
  end

  @doc "Renders JSON-array membership through the configured adapter dialect."
  def build_array_contains(column, path, value, opts \\ []) do
    render!(
      :render_json_array_contains,
      %ArrayContains{
        column: to_string(column),
        path: normalize_path_segments(path),
        value: value,
        table_alias: normalize_alias(Keyword.get(opts, :table_alias))
      },
      opts
    )
  end

  @doc "Renders all-values JSON-array membership through the configured adapter dialect."
  def build_array_contains_all(column, path, values, opts \\ []) when is_list(values) do
    render!(
      :render_json_array_contains_all,
      %ArrayContainsAll{
        column: to_string(column),
        path: normalize_path_segments(path),
        values: values,
        table_alias: normalize_alias(Keyword.get(opts, :table_alias))
      },
      opts
    )
  end

  @doc "Maps a portable JSON schema leaf type to a portable cast intent."
  def cast_for_type(type)
      when type in [
             :integer,
             :decimal,
             :float,
             :boolean,
             :date,
             :datetime,
             :utc_datetime
           ],
      do: type

  def cast_for_type(:naive_datetime), do: :datetime
  def cast_for_type(_type), do: nil

  @doc "Returns whether a domain column is declared as portable JSON."
  def json_column?(domain, column) do
    columns = Map.get(domain, :columns, %{})

    case Map.get(columns, column) || Map.get(columns, safe_existing_atom(column)) do
      %{type: :json} -> true
      _ -> false
    end
  end

  defp render!(callback, fragment, opts) do
    adapter = Keyword.get(opts, :adapter)

    case Selecto.DialectSupport.render_json(adapter, callback, fragment, %{adapter: adapter}) do
      {:ok, sql} -> IO.iodata_to_binary(sql)
      {:error, %Selecto.Error{} = error} -> raise Selecto.Error.to_exception(error)
      {:error, reason} -> raise ArgumentError, "adapter JSON rendering failed: #{inspect(reason)}"
    end
  end

  defp traverse_schema(schema, []) when is_map(schema), do: schema

  defp traverse_schema(schema, [key | rest]) when is_map(schema) do
    case Map.get(schema, key) || Map.get(schema, safe_existing_atom(key)) do
      %{type: :object, schema: nested_schema} ->
        traverse_schema(nested_schema, rest)

      %{type: :array, items: %{type: :object, schema: nested_schema}} when rest != [] ->
        traverse_schema(nested_schema, rest)

      field_def when rest == [] ->
        field_def

      _ ->
        nil
    end
  end

  defp traverse_schema(_schema, _path), do: nil

  defp normalize_path_segments(path) when is_binary(path) do
    path
    |> String.replace_prefix("$.", "")
    |> String.split(~r/[\.\[\]]/, trim: true)
  end

  defp normalize_path_segments(path) when is_list(path), do: Enum.map(path, &to_string/1)
  defp normalize_path_segments(path), do: [to_string(path)]

  defp normalize_alias(nil), do: nil
  defp normalize_alias(value), do: to_string(value)

  defp safe_existing_atom(value) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> nil
    end
  end

  defp safe_existing_atom(_value), do: nil
end
