defmodule Selecto.Document.Canonical do
  @moduledoc "Canonical, sorted-key JSON for the versioned document contracts."

  @spec encode(term()) :: binary()
  def encode(value), do: value |> encode_value() |> IO.iodata_to_binary()

  @spec digest(term()) :: binary()
  def digest(value), do: :crypto.hash(:sha256, encode(value)) |> Base.encode16(case: :lower)

  defp encode_value(value) when is_map(value) and not is_struct(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {key, value} when is_binary(key) ->
        [Jason.encode!(key), ":", encode_value(value)]
      end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp encode_value(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &encode_value/1), ","), "]"]

  defp encode_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: Jason.encode!(value)
end
