defmodule SelectoUpdato.KeyNormalizer do
  @moduledoc false

  @spec schema_fields(map() | module() | [atom()]) :: [atom()]
  def schema_fields(fields) when is_list(fields) do
    Enum.filter(fields, &is_atom/1)
  end

  def schema_fields(schema) when is_atom(schema) do
    if function_exported?(schema, :__schema__, 1), do: schema.__schema__(:fields), else: []
  end

  def schema_fields(domain) when is_map(domain) do
    domain
    |> schema_module()
    |> schema_fields()
  end

  def schema_fields(_), do: []

  @spec normalize_field(term(), map() | module() | [atom()]) :: atom() | nil
  def normalize_field(field, source) do
    fields = schema_fields(source)

    cond do
      is_atom(field) and (fields == [] or field in fields) ->
        field

      is_binary(field) and fields != [] ->
        Enum.find(fields, fn candidate -> Atom.to_string(candidate) == field end)

      true ->
        nil
    end
  end

  @spec normalize_fields([term()], map() | module() | [atom()]) :: [atom()]
  def normalize_fields(fields, source) when is_list(fields) do
    fields
    |> Enum.map(&normalize_field(&1, source))
    |> Enum.reject(&is_nil/1)
  end

  @spec atomize_known_keys(map(), map() | module() | [atom()]) :: map()
  def atomize_known_keys(attrs, source) when is_map(attrs) do
    allowed_fields = schema_fields(source)

    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      case normalize_field(key, allowed_fields) do
        nil -> Map.put(acc, key, value)
        field -> Map.put(acc, field, value)
      end
    end)
  end

  def atomize_known_keys(attrs, _source), do: attrs

  defp schema_module(%{source: source}) when is_atom(source), do: source

  defp schema_module(%{source: source}) when is_map(source) do
    Map.get(source, :module)
  end

  defp schema_module(%{config: %{source: source}}) when is_atom(source), do: source

  defp schema_module(%{config: %{source: source}}) when is_map(source) do
    Map.get(source, :module)
  end

  defp schema_module(_), do: nil
end
