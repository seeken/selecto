defmodule SelectoUpdato.ChoiceMembership do
  @moduledoc false

  alias Selecto.Domain.Choices
  alias Selecto.Domain.Choices.Result
  alias SelectoUpdato.{Error, Operation}

  @resolver_keys [:choice_source_membership_resolver, :choice_membership_resolver]

  @spec validate(Operation.t(), map(), struct() | map() | nil, map()) ::
          :ok | {:error, Error.t()}
  def validate(%Operation{} = op, attrs, record \\ nil, context \\ %{}) when is_map(attrs) do
    choice_fields = choice_fields(op, attrs)

    case {choice_fields, membership_resolver(op, context)} do
      {[], _resolver} ->
        :ok

      {fields, nil} ->
        {:error,
         Error.new(:validation, "Choice-backed write fields require a membership resolver",
           details: %{
             code: :choice_membership_resolver_required,
             fields: Enum.map(fields, &field_id/1),
             errors: Enum.map(fields, &{[field_id(&1)], "membership resolver is required"})
           }
         )}

      {_fields, resolver} when is_function(resolver, 1) ->
        validate_choice_fields(op, attrs, record, resolver, context)

      {_fields, resolver} ->
        {:error,
         Error.new(:invalid_operation, "Invalid choice-source membership resolver",
           details: %{resolver: inspect(resolver)}
         )}
    end
  end

  defp validate_choice_fields(op, attrs, record, resolver, context) do
    request_record = attrs_record(record, attrs)

    errors =
      attrs
      |> Enum.flat_map(fn {field, value} ->
        validate_choice_field(op, field, value, request_record, resolver, context)
      end)

    if errors == [] do
      :ok
    else
      {:error,
       Error.new(:validation, "Choice-source membership validation failed",
         details: %{errors: errors}
       )}
    end
  end

  defp validate_choice_field(op, field, value, request_record, resolver, context) do
    if choice_backed_field?(op.domain, field) do
      domain = choice_source_domain(op)
      request_attrs = choice_request_attrs(op, request_record, context)

      case Choices.validate_choice(
             domain,
             field,
             value,
             Keyword.put(request_attrs, :resolver, resolver)
           ) do
        {:ok, %Result{status: :valid}} ->
          []

        {:error, %Result{} = result} ->
          [{field, result_message(result)}]

        {:error, %{message: message}} ->
          [{field, message}]
      end
    else
      []
    end
  end

  defp choice_request_attrs(%Operation{} = op, record, context) do
    [
      actor: map_value(context, :actor) || Keyword.get(op.opts || [], :actor),
      tenant:
        map_value(context, :tenant) || map_value(context, :tenant_id) ||
          Keyword.get(op.opts || [], :tenant),
      filters:
        map_value(context, :choice_source_filters) ||
          Keyword.get(op.opts || [], :choice_source_filters, op.filters || []),
      record: record,
      context:
        map_value(context, :choice_source_context) ||
          Keyword.get(op.opts || [], :choice_source_context, %{}),
      metadata: %{surface: :updato, operation: op.type}
    ]
  end

  defp result_message(%Result{user_message: message}) when is_binary(message) and message != "" do
    message
  end

  defp result_message(%Result{status: :unknown, reason_code: reason}) do
    "could not be validated by choice source: #{reason}"
  end

  defp result_message(%Result{reason_code: reason}) do
    "is not an allowed choice: #{reason}"
  end

  defp attrs_record(nil, attrs), do: attrs

  defp attrs_record(record, attrs) when is_struct(record) do
    record
    |> Map.from_struct()
    |> Map.merge(attrs)
  end

  defp attrs_record(record, attrs) when is_map(record) do
    Map.merge(record, attrs)
  end

  defp membership_resolver(%Operation{opts: opts}, context) when is_list(opts) do
    Enum.find_value(@resolver_keys, fn key ->
      map_value(context, key) || Keyword.get(opts, key)
    end)
  end

  defp membership_resolver(_op, _context), do: nil

  defp choice_fields(%Operation{} = op, attrs) do
    attrs
    |> Map.keys()
    |> Enum.filter(&choice_backed_field?(op.domain, &1))
  end

  defp choice_source_domain(%Operation{domain: domain, opts: opts}) when is_list(opts) do
    Keyword.get(opts, :choice_source_domain, domain)
  end

  defp choice_source_domain(%Operation{domain: domain}), do: domain

  defp choice_backed_field?(domain, field) when is_map(domain) do
    case field_column(domain, field) do
      %{} = column ->
        choice_source_ref?(map_value(column, :choice_source)) or
          choice_source_ref?(column |> map_value(:reference) |> map_value(:choice_source))

      _other ->
        false
    end
  end

  defp choice_backed_field?(_domain, _field), do: false

  defp field_column(domain, field) do
    source_columns =
      domain
      |> map_value(:source)
      |> map_value(:columns)

    top_level_columns = map_value(domain, :columns)

    fetch_column(source_columns, field) || fetch_column(top_level_columns, field)
  end

  defp fetch_column(columns, field) when is_map(columns) do
    Map.get(columns, field) || Map.get(columns, to_string(field)) ||
      atom_key_lookup(columns, field)
  end

  defp fetch_column(_columns, _field), do: nil

  defp atom_key_lookup(columns, field) when is_binary(field) do
    Enum.find_value(columns, fn
      {key, value} when is_atom(key) -> if Atom.to_string(key) == field, do: value
      _entry -> nil
    end)
  end

  defp atom_key_lookup(_columns, _field), do: nil

  defp choice_source_ref?(value) when is_atom(value) and not is_nil(value), do: true
  defp choice_source_ref?(value) when is_binary(value) and value != "", do: true
  defp choice_source_ref?(_value), do: false

  defp field_id(field) when is_atom(field), do: Atom.to_string(field)
  defp field_id(field) when is_binary(field), do: field
  defp field_id(field), do: inspect(field)

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil
end
