defmodule Selecto.Domain.Contract.QueryLibrary do
  @moduledoc false

  alias Selecto.Domain.Contract.Query.FieldLists
  alias Selecto.Domain.Contract.Query.Filters
  alias Selecto.Domain.Contract.Shared.Core
  alias Selecto.Domain.Contract.Shared.FieldReference

  def validate(errors, nil, _field_index, _functions), do: errors

  def validate(errors, library, field_index, functions) when is_map(library) do
    normalized = %{
      segments: registry(library, :segments),
      projections: registry(library, :projections),
      orderings: registry(library, :orderings)
    }

    errors =
      Enum.reduce(Selecto.QueryLibrary.structure_errors(library), errors, fn error, acc ->
        [error | acc]
      end)

    errors
    |> validate_segment_fields(normalized.segments, field_index)
    |> validate_projection_fields(normalized.projections, field_index, functions)
    |> validate_ordering_fields(normalized.orderings, field_index, functions)
  end

  def validate(errors, library, _field_index, _functions) do
    [
      Core.error(
        :invalid_query_library,
        [:query_library],
        "query_library must be a map",
        expected: :map,
        actual: Core.value_type(library)
      )
      | errors
    ]
  end

  defp validate_segment_fields(errors, segments, field_index) do
    Enum.reduce(segments, errors, fn
      {segment_id, spec}, acc when is_map(spec) ->
        spec
        |> Core.map_value(:filters)
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {filter, index}, filter_errors ->
          Filters.validate_filter_expression(
            filter_errors,
            filter,
            [:query_library, :segments, segment_id, :filters, index],
            field_index
          )
        end)

      {_segment_id, _spec}, acc ->
        acc
    end)
  end

  defp validate_projection_fields(errors, projections, field_index, functions) do
    Enum.reduce(projections, errors, fn
      {projection_id, spec}, acc when is_map(spec) ->
        acc
        |> validate_projection_field_list(
          Core.map_value(spec, :fields),
          [:query_library, :projections, projection_id, :fields],
          field_index,
          functions
        )
        |> validate_associations(
          Core.map_value(spec, :associations),
          projection_id,
          nil,
          field_index
        )

      {_projection_id, _spec}, acc ->
        acc
    end)
  end

  defp validate_projection_field_list(errors, fields, path, field_index, functions)
       when is_list(fields) do
    fields
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {field, index}, acc ->
      FieldLists.validate_query_selection_entry(
        acc,
        :query_library,
        field,
        path ++ [index],
        field_index,
        functions
      )
    end)
  end

  defp validate_projection_field_list(errors, _fields, _path, _field_index, _functions),
    do: errors

  defp validate_associations(errors, associations, projection_id, parent, field_index)
       when is_list(associations) do
    associations
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {association, index}, acc when is_map(association) ->
        name = Core.map_value(association, :name)

        path =
          if is_nil(parent), do: Core.field_id(name), else: "#{parent}.#{Core.field_id(name)}"

        acc =
          association
          |> Core.map_value(:fields)
          |> List.wrap()
          |> Enum.with_index()
          |> Enum.reduce(acc, fn {field, field_index_number}, field_errors ->
            FieldReference.validate_field_reference(
              field_errors,
              "#{path}.#{Core.field_id(field)}",
              [
                :query_library,
                :projections,
                projection_id,
                :associations,
                index,
                :fields,
                field_index_number
              ],
              field_index
            )
          end)

        validate_associations(
          acc,
          Core.map_value(association, :associations),
          projection_id,
          path,
          field_index
        )

      {_association, _index}, acc ->
        acc
    end)
  end

  defp validate_associations(errors, _associations, _projection_id, _parent, _field_index),
    do: errors

  defp validate_ordering_fields(errors, orderings, field_index, functions) do
    Enum.reduce(orderings, errors, fn
      {ordering_id, spec}, acc when is_map(spec) ->
        spec
        |> Core.map_value(:order_by)
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {order, index}, order_errors ->
          FieldLists.validate_query_order_entry(
            order_errors,
            :query_library,
            order,
            [:query_library, :orderings, ordering_id, :order_by, index],
            field_index,
            functions
          )
        end)

      {_ordering_id, _spec}, acc ->
        acc
    end)
  end

  defp registry(library, key) do
    case Core.map_value(library, key) do
      registry when is_map(registry) -> registry
      _ -> %{}
    end
  end
end
