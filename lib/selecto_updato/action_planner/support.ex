defmodule SelectoUpdato.ActionPlanner.Support do
  @moduledoc """
  Shared map/key/error helpers for action planning.

  These are the small normalization primitives used by
  `SelectoUpdato.ActionPlanner`, `SelectoUpdato.ActionInputCoercion`, and
  `SelectoUpdato.CollectionPatch`. They tolerate atom- and string-keyed maps
  interchangeably because action metadata may come from either spelling.
  """

  @doc false
  def error(code, path, message, attrs \\ []) do
    attrs
    |> Map.new()
    |> Map.merge(%{code: code, path: path, message: message})
  end

  @doc false
  def id(nil), do: ""
  def id(value) when is_atom(value), do: Atom.to_string(value)
  def id(value) when is_binary(value), do: value
  def id(value), do: to_string(value)

  @doc false
  def field_name(value) when is_atom(value), do: Atom.to_string(value)
  def field_name(value) when is_binary(value), do: value
  def field_name(value), do: to_string(value)

  @doc false
  def map_get(map, key, default \\ nil)

  def map_get(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  def map_get(_other, _key, default), do: default

  @doc false
  def list_value(map, key) do
    case map_get(map, key, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc false
  def fetch_value(%{} = map, wanted_key) do
    wanted_key = id(wanted_key)

    Enum.find_value(map, :error, fn {key, value} ->
      if id(key) == wanted_key, do: {:ok, value}
    end)
  end

  def fetch_value(_map, _wanted_key), do: :error

  @doc false
  def fetch_first_value(map, keys) do
    Enum.find_value(keys, :error, fn key ->
      case fetch_value(map, key) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end)
  end

  @doc false
  def has_key?(%{} = map, wanted_key) do
    wanted_key = id(wanted_key)
    Enum.any?(Map.keys(map), &(id(&1) == wanted_key))
  end

  def has_key?(_map, _wanted_key), do: false

  @doc false
  def has_value?(map, key) do
    case fetch_value(map, key) do
      {:ok, nil} -> false
      {:ok, _value} -> true
      :error -> false
    end
  end

  @doc false
  def value!(map, key) do
    {:ok, value} = fetch_value(map, key)
    value
  end

  @doc false
  def integer_value?(value) when is_integer(value), do: true

  def integer_value?(value) when is_binary(value) do
    case Integer.parse(value) do
      {_integer, ""} -> true
      _other -> false
    end
  end

  def integer_value?(_value), do: false

  @doc false
  def truthy?(value), do: value in [true, "true", 1, "1"]

  @doc false
  def field_id_or_nil(nil), do: nil
  def field_id_or_nil(value), do: if(id(value) == "", do: nil, else: id(value))

  @doc false
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, _key, []), do: map
  def maybe_put(map, _key, value) when value == %{}, do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  def compact_plan_map(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, value} when value == %{} -> true
      _entry -> false
    end)
    |> Map.new()
  end

  @doc false
  def sorted_entries(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> id(key) end)
  end

  @doc false
  def contract_entry(contract, section, entry_id) do
    contract
    |> list_value(section)
    |> Enum.find(&(id(map_get(&1, :id)) == id(entry_id)))
  end
end
