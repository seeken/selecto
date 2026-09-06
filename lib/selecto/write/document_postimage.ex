defmodule Selecto.Write.DocumentPostimage do
  @moduledoc """
  Bounded selected postimages stored inside a document action's durable receipt.

  Cells preserve authored projection order and distinguish absent values from
  present null. Projection entries contain exactly the string keys `id`, `type`,
  `nullable`, and `missing`. Field policy and native pre/post-shape validation
  belong to the governing action and adapter; this codec validates portable data.
  """

  alias Selecto.Document.{Missing, ObjectId, Path}
  alias Selecto.Write.{DocumentMutation, Error}

  @types ~w(string integer boolean object_id)
  @max_budget 16_384

  @doc "Validate exact cells against a bounded, ordered scalar projection and receipt budget."
  def validate(cells, projection) do
    with true <- valid_projection?(projection),
         {:ok, bytes} <- budget(cells),
         true <- bytes <= @max_budget,
         true <- length(cells) == length(projection),
         true <-
           Enum.zip(cells, projection)
           |> Enum.all?(fn {cell, field} -> matches_projection?(cell, field) end) do
      :ok
    else
      _ -> invalid()
    end
  end

  @doc "Decode exactly one selected row; absent cells become the portable Missing sentinel."
  def decode(cells, projection) do
    with :ok <- validate(cells, projection) do
      row =
        Map.new(cells, fn cell ->
          value = if cell["present"], do: cell["value"], else: %Missing{}
          {cell["field"], value}
        end)

      {:ok, [row]}
    end
  end

  @doc "Return the conservative encoded-size budget for valid cells, even when over the limit."
  def budget(cells) when is_list(cells) and length(cells) in 1..16 do
    if Enum.all?(cells, &valid_cell?/1) and
         Enum.uniq_by(cells, & &1["field"]) == cells do
      bytes =
        Enum.reduce(cells, 64, fn cell, total ->
          value_bytes = if is_binary(cell["value"]), do: byte_size(cell["value"]), else: 0
          total + 256 + 6 * byte_size(cell["field"]) + 6 * value_bytes
        end)

      {:ok, bytes}
    else
      invalid()
    end
  end

  def budget(_), do: invalid()

  defp valid_projection?(projection) when is_list(projection) and length(projection) in 1..16,
    do:
      Enum.all?(projection, &valid_field?/1) and
        Enum.uniq_by(projection, & &1["id"]) == projection

  defp valid_projection?(_), do: false

  defp valid_field?(
         %{"id" => id, "type" => type, "nullable" => nullable, "missing" => missing} = field
       )
       when not is_struct(field) and map_size(field) == 4,
       do:
         Path.safe_key?(id) and type in @types and is_boolean(nullable) and
           missing in ["preserve", "reject"]

  defp valid_field?(_), do: false

  defp valid_cell?(%{"field" => id, "present" => false} = cell)
       when not is_struct(cell) and map_size(cell) == 2,
       do: Path.safe_key?(id)

  defp valid_cell?(%{"field" => id, "present" => true, "value" => value} = cell)
       when not is_struct(cell) and map_size(cell) == 3,
       do: Path.safe_key?(id) and DocumentMutation.scalar_value?(value)

  defp valid_cell?(_), do: false

  defp matches_projection?(cell, field) do
    cell["field"] == field["id"] and
      case cell do
        %{"present" => false} -> field["missing"] == "preserve"
        %{"value" => nil} -> field["nullable"]
        %{"value" => value} -> typed?(field["type"], value)
      end
  end

  defp typed?("string", value), do: is_binary(value)
  defp typed?("integer", value), do: is_integer(value)
  defp typed?("boolean", value), do: is_boolean(value)
  defp typed?("object_id", value), do: ObjectId.valid?(value)

  defp invalid,
    do:
      {:error,
       Error.new(:invalid_document_postimage, "Invalid bounded document postimage",
         details: %{code: :invalid_document_postimage}
       )}
end
