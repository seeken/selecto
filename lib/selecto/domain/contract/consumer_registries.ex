defmodule Selecto.Domain.Contract.ConsumerRegistries do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core

  def validate(errors, section, registry) when section in [:operations, :experiences] do
    if is_map(registry) do
      Enum.reduce(registry, errors, fn {id, spec}, acc ->
        path = [section, id]

        acc
        |> validate_id(section, id, path)
        |> validate_spec(section, id, spec, path)
      end)
    else
      [
        Core.error(
          :invalid_section_shape,
          [section],
          "domain section #{inspect(section)} must be a map",
          expected: :map,
          actual: Core.value_type(registry)
        )
        | errors
      ]
    end
  end

  defp validate_id(errors, _section, id, _path) when is_atom(id) and not is_nil(id), do: errors

  defp validate_id(errors, section, id, path) when is_binary(id) do
    if String.trim(id) == "", do: invalid_id(errors, section, id, path), else: errors
  end

  defp validate_id(errors, section, id, path), do: invalid_id(errors, section, id, path)

  defp invalid_id(errors, section, id, path) do
    [
      Core.error(
        :invalid_consumer_registry_id,
        path,
        "#{section} ids must be non-empty atoms or strings",
        section: section,
        id: id
      )
      | errors
    ]
  end

  defp validate_spec(errors, _section, _id, spec, _path) when is_map(spec), do: errors

  defp validate_spec(errors, section, id, spec, path) do
    [
      Core.error(
        :invalid_consumer_registry_entry,
        path,
        "#{section} entry #{inspect(id)} must be a map",
        expected: :map,
        actual: Core.value_type(spec),
        section: section,
        id: id
      )
      | errors
    ]
  end
end
