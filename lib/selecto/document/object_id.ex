defmodule Selecto.Document.ObjectId do
  @moduledoc """
  Driver-free portable ObjectId values. Construction is explicit and accepts a
  24-digit hexadecimal string. Validation accepts only the canonical tagged
  map, never a raw string, vendor struct, extended JSON variant, or extra keys.
  """

  @type t :: %{required(String.t()) => String.t()}

  @spec new(term()) :: {:ok, t()} | {:error, :invalid_object_id}
  def new(hex) when is_binary(hex) and byte_size(hex) == 24 do
    if Regex.match?(~r/\A[0-9a-fA-F]{24}\z/, hex),
      do: {:ok, %{"$bson" => "object_id", "value" => String.downcase(hex)}},
      else: {:error, :invalid_object_id}
  end

  def new(_), do: {:error, :invalid_object_id}

  @spec valid?(term()) :: boolean()
  def valid?(%{"$bson" => "object_id", "value" => hex} = value)
      when not is_struct(value) and map_size(value) == 2 and is_binary(hex) and
             byte_size(hex) == 24,
      do: Regex.match?(~r/\A[0-9a-f]{24}\z/, hex)

  def valid?(_), do: false
end
