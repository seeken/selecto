defmodule SelectoUpdato.DomainContract.ChoiceSourceValidator do
  @moduledoc false

  alias Selecto.Domain.Choices
  alias Selecto.Domain.Choices.Result
  alias SelectoUpdato.DomainContract

  @spec validate(term(), map(), keyword()) :: [map()]
  def validate(input, intent, opts) when is_map(intent) and is_list(opts) do
    resolver = Keyword.get(opts, :choice_source_membership_resolver)
    choice_domain = Keyword.get(opts, :choice_source_domain, input)

    if is_map(choice_domain) and is_function(resolver, 1) do
      field_configs = choice_source_field_configs(input)
      request_attrs = choice_source_request_attrs(opts, resolver)

      intent
      |> choice_source_value_sets()
      |> Enum.flat_map(fn {path, values} ->
        choice_source_value_errors(choice_domain, field_configs, request_attrs, path, values)
      end)
    else
      []
    end
  end

  def validate(_input, _intent, _opts), do: []

  defp choice_source_field_configs(input) do
    input
    |> contract_fields()
    |> Enum.filter(&choice_source_field?/1)
    |> Map.new(fn field -> {to_string(map_value(field, :id)), field} end)
  end

  defp contract_fields(%{fields: fields}) when is_list(fields), do: fields
  defp contract_fields(%{"fields" => fields}) when is_list(fields), do: fields

  defp contract_fields(input) do
    case DomainContract.json_document(input, []) do
      {:ok, contract, _diagnostics} -> Map.get(contract, "fields", [])
      {:error, _diagnostics} -> []
    end
  end

  defp choice_source_request_attrs(opts, resolver) do
    [
      resolver: resolver,
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant),
      record: Keyword.get(opts, :choice_source_record),
      filters: Keyword.get(opts, :choice_source_filters, []),
      context: Keyword.get(opts, :choice_source_context, %{}),
      metadata: Keyword.get(opts, :choice_source_metadata, %{})
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, %{}, []] end)
  end

  defp choice_source_value_sets(intent) do
    scalar_sets =
      [
        {"attrs", map_value(intent, :attrs)},
        {"changes", map_value(intent, :changes)},
        {"set", map_value(intent, :set)}
      ]
      |> Enum.flat_map(fn
        {path, values} when is_map(values) -> [{[path], values}]
        _entry -> []
      end)

    record_sets =
      intent
      |> map_value(:records, [])
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {record, index} when is_map(record) -> [{["records", index], record}]
        _entry -> []
      end)

    scalar_sets ++ record_sets
  end

  defp choice_source_value_errors(domain, field_configs, request_attrs, path, values) do
    values
    |> Enum.flat_map(fn {field_id, raw_value} ->
      field_id = to_string(field_id)

      case Map.get(field_configs, field_id) do
        nil ->
          []

        field ->
          if blank_choice_value?(raw_value) do
            []
          else
            value = coerce_choice_value(raw_value, map_value(field, :type))
            choice_source_validation_error(domain, field_id, value, field, request_attrs, path)
          end
      end
    end)
  end

  defp choice_source_validation_error(domain, field_id, value, field, request_attrs, path) do
    case Choices.validate_choice(domain, field_id, value, request_attrs) do
      {:ok, %Result{status: :valid}} ->
        []

      {:error, %Result{} = result} ->
        [choice_source_error(field_id, field, result, path)]

      {:error, error} ->
        [choice_source_error(field_id, field, error, path)]
    end
  end

  defp choice_source_error(field_id, field, %Result{status: :invalid} = result, path) do
    compact(%{
      code: :choice_source_invalid,
      path: path,
      field: field_id,
      choice_source: map_value(field, :choice_source),
      reason: to_string(result.reason_code || :choice_invalid),
      message:
        result.user_message ||
          "#{map_value(field, :label, field_id)} is not an available choice"
    })
  end

  defp choice_source_error(field_id, field, %Result{} = result, path) do
    compact(%{
      code: :choice_source_unverified,
      path: path,
      field: field_id,
      choice_source: map_value(field, :choice_source),
      reason: to_string(result.reason_code || :choice_unknown),
      message:
        result.user_message || "#{map_value(field, :label, field_id)} could not be verified"
    })
  end

  defp choice_source_error(field_id, field, error, path) do
    compact(%{
      code: :choice_source_validation_error,
      path: path,
      field: field_id,
      choice_source: map_value(field, :choice_source),
      reason: inspect(error),
      message: "#{map_value(field, :label, field_id)} could not be verified"
    })
  end

  defp choice_source_field?(field) do
    case map_value(field, :choice_source) do
      value when is_binary(value) -> String.trim(value) != ""
      value when is_atom(value) -> not is_nil(value)
      _value -> false
    end
  end

  defp blank_choice_value?(nil), do: true
  defp blank_choice_value?(""), do: true
  defp blank_choice_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_choice_value?(_value), do: false

  defp coerce_choice_value(value, type) when type in [:integer, "integer"] and is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp coerce_choice_value(value, _type), do: value

  defp compact(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, []} -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  defp map_value(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_value(_map, _key, default), do: default
end
