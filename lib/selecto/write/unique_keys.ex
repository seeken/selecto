defmodule Selecto.Write.UniqueKeys do
  @moduledoc false
  alias Selecto.Domain.Contract.Shared.Core, as: M

  def normalize(error, domain) do
    keys = domain |> M.map_value(:writes) |> M.map_value(:unique_keys) || %{}
    details = error.details || %{}

    if is_map(keys) and map_size(keys) > 0 and
         M.map_value(details, :category) == :unique_violation do
      constraint = M.map_value(details, :constraint)
      fields = M.map_value(details, :fields) || parse_fields(M.map_value(details, :column))

      match =
        Enum.find(keys, fn {key, columns} ->
          to_string(key) == constraint or
            (fields != [] and Enum.sort(Enum.map(columns, &to_string/1)) == Enum.sort(fields))
        end)

      {key, fields} =
        case match do
          {key, columns} -> {to_string(key), Enum.sort(Enum.map(columns, &to_string/1))}
          nil -> {nil, []}
        end

      %{
        error
        | type: :database_unique_violation,
          message: "declared unique key rejected the write",
          details: %{
            code: :database_unique_violation,
            key: key,
            fields: fields,
            category: :unique_violation
          }
      }
    else
      error
    end
  end

  defp parse_fields(value) when is_binary(value) do
    fields =
      value
      |> String.split(",")
      |> Enum.map(&(String.trim(&1) |> String.split(".") |> List.last()))

    if Enum.all?(fields, &Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, &1)), do: fields, else: []
  end

  defp parse_fields(_), do: []
end
