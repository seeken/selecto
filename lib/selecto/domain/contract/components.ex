defmodule Selecto.Domain.Contract.Components do
  @moduledoc false

  # Exploration hints are otherwise passed through as authored; a
  # filter_choices entry's optional description follows the field description
  # rule (Selecto.Domain.Description).

  alias Selecto.Domain.Contract.Shared.Core
  alias Selecto.Domain.Description

  def validate(errors, components) when is_map(components) do
    case Core.map_value(components, :filter_choices) do
      filter_choices when is_map(filter_choices) ->
        Enum.reduce(filter_choices, errors, &validate_filter_choice/2)

      _ ->
        errors
    end
  end

  def validate(errors, _components), do: errors

  defp validate_filter_choice({path, spec}, errors) when is_map(spec) do
    case Core.fetch_map_value(spec, :description) do
      :__missing__ ->
        errors

      description ->
        if Description.valid?(description),
          do: errors,
          else: [
            Core.error(
              :invalid_filter_choice_description,
              [:components, :filter_choices, path, :description],
              "filter choices for #{Core.field_id(path)} description must be a non-blank string " <>
                "of at most #{Description.max_length()} characters without control characters " <>
                "other than a line feed"
            )
            | errors
          ]
    end
  end

  defp validate_filter_choice(_entry, errors), do: errors
end
