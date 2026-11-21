defmodule Selecto.Domain.ContractExport do
  @moduledoc false

  # `Selecto.Domain.contract_json/1` and `Selecto.Domain.contract_keys/0`
  # (certification profile domain_contract_export, specification 4.1.0).
  # Additive: parsing, validation and fingerprints are unchanged.

  alias Selecto.Domain
  alias Selecto.Domain.Diagnostics
  alias Selecto.Domain.Sections

  @column_flags ~w(hidden internal redacted nullable selectable filterable sortable groupable
                   detail_selectable query_filterable aggregatable)
  @tenant_aliases ~w(tenant_required require_tenant)
  @write_operation_flags ~w(enabled bulk require_filter)
  @write_field_flags ~w(insertable updatable required write_once)
  @write_relationship_flags ~w(writable delete_missing required cascade_delete cascade_update)
  @editor_field_flags ~w(required nullable readonly)

  @spec contract_keys() :: %{
          top_level: [String.t()],
          relation: :any,
          association: :any,
          join: :any,
          through: :any,
          join_types: :any
        }
  def contract_keys do
    top_level =
      Sections.sections()
      |> Map.values()
      |> List.flatten()
      |> Enum.sort()

    %{
      top_level: top_level,
      relation: :any,
      association: :any,
      join: :any,
      through: :any,
      join_types: :any
    }
  end

  @spec contract_json(map()) :: {:ok, map()} | {:error, Diagnostics.t()}
  def contract_json(%Selecto{domain: domain}) when is_map(domain), do: contract_json(domain)

  def contract_json(domain) when is_map(domain) and not is_struct(domain) do
    with :ok <- unambiguous(domain, []),
         {:ok, authored} <- json(domain),
         {:ok, normalized, _diagnostics} <- Domain.validate(flags(authored)),
         {:ok, canonical} <- json(normalized.domain) do
      {:ok, flags(canonical)}
    end
  end

  def contract_json(_domain),
    do: refuse(:invalid_domain, [], "Selecto domains must be maps or a configured Selecto")

  # ------------------------------------------------------------------ JSON form

  # An object naming a key both as an atom and as a string has no single JSON
  # form; it is refused rather than resolved.
  defp unambiguous(value, path) when is_map(value) and not is_struct(value) do
    names = Enum.map(Map.keys(value), &name_of/1)

    if length(names) == length(Enum.uniq(names)) do
      Enum.reduce_while(value, :ok, fn {key, member}, :ok ->
        case unambiguous(member, [name_of(key) | path]) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      refuse(:ambiguous_domain_keys, Enum.reverse(path), "an object names a key twice")
    end
  end

  defp unambiguous(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case unambiguous(item, [index | path]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp unambiguous(_value, _path), do: :ok

  defp name_of(key) when is_atom(key), do: Atom.to_string(key)
  defp name_of(key), do: key

  # String keys; atoms (other than nil and booleans) become strings, tuples
  # arrays. Numbers, strings, booleans and null keep their JSON types.
  defp json(value) do
    {:ok, to_json(value, [])}
  catch
    {:contract_json, code, path, message} -> refuse(code, Enum.reverse(path), message)
  end

  defp to_json(value, _path) when is_nil(value) or is_boolean(value), do: value
  defp to_json(value, _path) when is_binary(value) or is_number(value), do: value
  defp to_json(value, _path) when is_atom(value), do: Atom.to_string(value)
  defp to_json(%Date{} = value, _path), do: Date.to_iso8601(value)
  defp to_json(%Time{} = value, _path), do: Time.to_iso8601(value)
  defp to_json(%NaiveDateTime{} = value, _path), do: NaiveDateTime.to_iso8601(value)
  defp to_json(%DateTime{} = value, _path), do: DateTime.to_iso8601(value)

  defp to_json(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map(fn {item, index} -> to_json(item, [index | path]) end)
  end

  defp to_json(value, path) when is_tuple(value), do: to_json(Tuple.to_list(value), path)

  defp to_json(value, path) when is_map(value) and not is_struct(value) do
    value
    # The normalizer writes atom keys (schema_version) into string-keyed
    # documents; its value is the canonical one, so atom keys convert last.
    |> Enum.sort_by(fn {key, _member} -> is_atom(key) end)
    |> Enum.reduce(%{}, fn {key, member}, acc ->
      name = key_name(key, path)
      Map.put(acc, name, to_json(member, [name | path]))
    end)
  end

  defp to_json(value, path) do
    throw(
      {:contract_json, :invalid_contract_value, path,
       "contract value #{inspect(value)} is not JSON data"}
    )
  end

  defp key_name(key, _path) when is_binary(key), do: key
  defp key_name(key, _path) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)

  defp key_name(key, path) do
    throw(
      {:contract_json, :invalid_contract_value, path,
       "contract object key #{inspect(key)} is not a string"}
    )
  end

  defp refuse(code, path, message) do
    {:error, Diagnostics.new(errors: [%{code: code, path: path, message: message}])}
  end

  # ------------------------------------------------------------------ flags

  # JSON booleans at the flag positions of docs/domain_contract_export.md;
  # everything else is data and keeps its JSON type.
  @doc false
  @spec flags(term()) :: term()
  def flags(contract) when is_map(contract) do
    contract
    |> tenant_aliases()
    |> booleans(@tenant_aliases)
    |> update("source", &relation_flags/1)
    |> update("schemas", &each_value(&1, fn relation -> relation_flags(relation) end))
    |> update("columns", &each_value(&1, fn column -> booleans(column, @column_flags) end))
    |> update("components", &component_flags/1)
    |> update(
      "co_domains",
      &each_value(&1, fn co -> update(co, "search", fn s -> booleans(s, ["rank"]) end) end)
    )
    |> update("actions", &each_value(&1, fn action -> action_flags(action) end))
    |> update("detail_actions", &each_value(&1, fn action -> detail_action_flags(action) end))
    |> update("editors", &each_value(&1, fn editor -> editor_flags(editor) end))
    |> update("writes", &write_flags/1)
  end

  def flags(contract), do: contract

  # The engine coalesces the tenant aliases before its truth test; an absent
  # (null) alias beside a present one takes that one's value, so the export
  # never manufactures a conflict.
  defp tenant_aliases(contract) do
    value =
      case {contract["tenant_required"], contract["require_tenant"]} do
        {nil, nil} -> false
        {nil, other} -> other
        {value, _other} -> value
      end

    Enum.reduce(@tenant_aliases, contract, fn key, acc ->
      if Map.has_key?(acc, key) and is_nil(acc[key]), do: Map.put(acc, key, value), else: acc
    end)
  end

  defp relation_flags(relation),
    do:
      update(
        relation,
        "columns",
        &each_value(&1, fn column -> booleans(column, @column_flags) end)
      )

  defp component_flags(components) do
    components
    |> booleans(["query_params"])
    |> update(
      "filter_choices",
      &each_value(&1, fn choice -> booleans(choice, ["picker_hidden"]) end)
    )
  end

  defp action_flags(action) do
    action
    |> booleans(["prerequisite_column"])
    |> update("inputs", fn
      inputs when is_list(inputs) -> Enum.map(inputs, &booleans(&1, ["required"]))
      inputs -> each_value(inputs, &booleans(&1, ["required"]))
    end)
  end

  defp detail_action_flags(action),
    do: update(action, "payload", &booleans(&1, ["navigation_enabled"]))

  defp editor_flags(editor) do
    update(editor, "fields", fn
      fields when is_list(fields) -> Enum.map(fields, &booleans(&1, @editor_field_flags))
      fields -> fields
    end)
  end

  defp write_flags(writes) do
    writes
    |> update("operations", &each_value(&1, fn op -> booleans(op, @write_operation_flags) end))
    |> update("fields", &each_value(&1, fn field -> booleans(field, @write_field_flags) end))
    |> update("scope", &update(&1, "tenant", fn tenant -> booleans(tenant, ["required"]) end))
    |> update("relationships", &each_value(&1, fn rel -> relationship_flags(rel) end))
  end

  defp relationship_flags(relationship) do
    relationship
    |> booleans(@write_relationship_flags)
    |> update("domain", &flags/1)
  end

  defp booleans(object, keys) when is_map(object) do
    Enum.reduce(keys, object, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, value} -> Map.put(acc, key, truthy?(value))
        :error -> acc
      end
    end)
  end

  defp booleans(value, _keys), do: value

  @doc false
  # The portable truth test of a flag written as JSON: false, null, 0, "" and
  # "0" are false; every other value is true.
  @spec truthy?(term()) :: boolean()
  def truthy?(value) when value in [nil, false, ""], do: false
  def truthy?(value) when is_number(value), do: value != 0
  def truthy?("0"), do: false
  def truthy?(_value), do: true

  defp update(object, key, fun) when is_map(object) do
    case Map.fetch(object, key) do
      {:ok, value} -> Map.put(object, key, fun.(value))
      :error -> object
    end
  end

  defp update(object, _key, _fun), do: object

  defp each_value(object, fun) when is_map(object),
    do: Map.new(object, fn {key, value} -> {key, fun.(value)} end)

  defp each_value(object, _fun), do: object
end
