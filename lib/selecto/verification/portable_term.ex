defmodule Selecto.Verification.PortableTerm do
  @moduledoc false

  @doc false
  @spec encode(term()) :: term()
  def encode(value)
      when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value),
      do: value

  def encode(value) when is_binary(value) do
    if String.valid?(value),
      do: value,
      else: %{binary_base64: Base.encode64(value)}
  end

  def encode(value) when is_list(value), do: encode_list(value, [])

  def encode(value) when is_tuple(value) do
    %{tuple: value |> Tuple.to_list() |> Enum.map(&encode/1)}
  end

  def encode(%module{} = value) do
    %{
      struct_module: inspect(module),
      fields: value |> Map.from_struct() |> encode()
    }
  end

  def encode(value) when is_map(value), do: encode_map(value)
  def encode(value), do: inspect(value)

  defp encode_list([], head), do: Enum.reverse(head)

  defp encode_list([item | tail], head) do
    encode_list(tail, [encode(item) | head])
  end

  defp encode_list(tail, head) do
    %{
      improper_list: %{
        head: Enum.reverse(head),
        tail: encode(tail)
      }
    }
  end

  defp encode_map(map) do
    entries =
      map
      |> Enum.map(fn {key, value} ->
        {key, %{key: encode_key(key), value: encode(value)}}
      end)
      |> Enum.sort_by(fn {_key, entry} -> entry_sort_key(entry) end)

    if plain_json_object?(entries) do
      Map.new(entries, fn {key, entry} -> {key, entry.value} end)
    else
      %{map_entries: Enum.map(entries, &elem(&1, 1))}
    end
  end

  defp plain_json_object?(entries) do
    descriptors = Enum.map(entries, fn {_key, entry} -> entry.key end)
    json_keys = Enum.map(descriptors, & &1.value)

    Enum.all?(descriptors, &(&1.type in [:atom, :string])) and
      length(json_keys) == length(Enum.uniq(json_keys))
  end

  defp entry_sort_key(%{key: %{type: type, value: value}}) do
    rank = %{atom: 0, string: 1, term: 2} |> Map.fetch!(type)
    {inspect(value, limit: :infinity, printable_limit: :infinity), rank}
  end

  defp encode_key(key) when is_atom(key), do: %{type: :atom, value: Atom.to_string(key)}

  defp encode_key(key) when is_binary(key) do
    if String.valid?(key),
      do: %{type: :string, value: key},
      else: %{type: :term, value: encode(key)}
  end

  defp encode_key(key), do: %{type: :term, value: encode(key)}
end
