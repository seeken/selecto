defmodule Selecto.Domain.Contract.Relations do
  @moduledoc false

  use Selecto.Domain.Constants
  alias Selecto.Domain.Contract.Shared.Core
  alias Selecto.Domain.Contract.ComputedPredicates
  alias Selecto.Analytics.Unit

  @relation_required_keys [:primary_key, :fields, :columns]

  def validate(errors, source, schemas) do
    errors
    |> validate_relation(:source, source, [:source])
    |> ComputedPredicates.validate(source)
    |> validate_schemas(schemas)
  end

  def validate_relation(errors, relation_id, relation, path) when is_map(relation) do
    errors
    |> validate_required_relation_keys(relation_id, relation, path)
    |> validate_relation_source_table(relation_id, relation, path)
    |> validate_relation_values(relation_id, relation, path)
    |> validate_relation_fields(relation_id, relation, path)
    |> validate_relation_columns(relation_id, relation, path)
    |> validate_relation_primary_key(relation_id, relation, path)
    |> validate_relation_field_columns(relation_id, relation, path)
    |> validate_relation_source_kind(relation_id, relation, path)
    |> validate_relation_readonly(relation_id, relation, path)
  end

  def validate_relation(errors, relation_id, relation, path) do
    [
      Core.error(
        :invalid_section_shape,
        path,
        "domain relation #{inspect(relation_id)} must be a map",
        expected: :map,
        actual: Core.value_type(relation)
      )
      | errors
    ]
  end

  def validate_required_relation_keys(errors, relation_id, relation, path) do
    required =
      if relation_id == :source,
        do: [:source_table | @relation_required_keys],
        else: @relation_required_keys

    missing_keys = Enum.reject(required, &Core.has_key?(relation, &1))

    case missing_keys do
      [] ->
        errors

      _ ->
        [
          Core.error(
            :missing_required_keys,
            path,
            "domain relation #{inspect(relation_id)} is missing required keys #{inspect(missing_keys)}",
            relation: relation_id,
            keys: missing_keys
          )
          | errors
        ]
    end
  end

  defp validate_relation_values(errors, :source, relation, path) do
    if Core.has_key?(relation, :values),
      do: [
        Core.error(:invalid_root_values, path ++ [:values], "root source must use source_table")
        | errors
      ],
      else: errors
  end

  defp validate_relation_values(errors, relation_id, relation, path) do
    has_table = Core.has_key?(relation, :source_table)
    has_values = Core.has_key?(relation, :values)

    errors =
      if has_table != has_values do
        errors
      else
        [
          Core.error(
            :invalid_relation_source,
            path,
            "schema must declare exactly one of source_table or values",
            relation: relation_id
          )
          | errors
        ]
      end

    if has_values do
      fields = Core.map_value(relation, :fields)
      rows = Core.map_value(relation, :values)

      if is_list(fields) and fields != [] and Enum.all?(fields, &Core.field_ref?/1) and
           is_list(rows) and rows != [] do
        expected = MapSet.new(Enum.map(fields, &to_string/1))

        rows
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {row, index}, acc ->
          row_fields =
            if is_map(row) and Enum.all?(Map.keys(row), &Core.field_ref?/1),
              do: MapSet.new(Enum.map(Map.keys(row), &to_string/1))

          literals? = is_map(row) and Enum.all?(Map.values(row), &scalar_value?/1)

          if row_fields == expected and literals? do
            acc
          else
            [
              Core.error(
                :invalid_relation_values_row,
                path ++ [:values, index],
                "values row must contain exactly the declared scalar fields"
              )
              | acc
            ]
          end
        end)
      else
        [
          Core.error(
            :invalid_relation_values,
            path ++ [:values],
            "values must be a non-empty list of rows"
          )
          | errors
        ]
      end
    else
      errors
    end
  end

  defp scalar_value?(value),
    do:
      is_nil(value) or is_binary(value) or is_integer(value) or is_float(value) or
        is_boolean(value)

  def validate_relation_source_table(errors, relation_id, relation, path) do
    case Core.fetch_map_value(relation, :source_table) do
      :__missing__ ->
        errors

      source_table
      when is_binary(source_table) or (is_atom(source_table) and not is_nil(source_table)) ->
        errors

      source_table ->
        [
          Core.error(
            :invalid_source_table,
            path ++ [:source_table],
            "domain relation #{inspect(relation_id)} has an invalid source_table",
            relation: relation_id,
            expected: "atom or string",
            actual: Core.value_type(source_table)
          )
          | errors
        ]
    end
  end

  def validate_relation_fields(errors, relation_id, relation, path) do
    case Core.fetch_map_value(relation, :fields) do
      :__missing__ ->
        errors

      fields when is_list(fields) ->
        errors

      fields ->
        [
          Core.error(
            :invalid_fields,
            path ++ [:fields],
            "domain relation #{inspect(relation_id)} fields must be a list",
            relation: relation_id,
            expected: :list,
            actual: Core.value_type(fields)
          )
          | errors
        ]
    end
  end

  def validate_relation_columns(errors, relation_id, relation, path) do
    case Core.fetch_map_value(relation, :columns) do
      :__missing__ ->
        errors

      columns when is_map(columns) ->
        Enum.reduce(columns, errors, fn {field, definition}, acc ->
          if is_map(definition) do
            case Unit.normalize_column(definition) do
              {:ok, _normalized} ->
                acc

              {:error, message} ->
                [
                  Core.error(:invalid_quantitative_column, path ++ [:columns, field], message,
                    relation: relation_id
                  )
                  | acc
                ]
            end
          else
            [
              Core.error(
                :invalid_column_definition,
                path ++ [:columns, field],
                "domain relation #{inspect(relation_id)} column #{inspect(field)} must be a map",
                relation: relation_id,
                expected: :map,
                actual: Core.value_type(definition)
              )
              | acc
            ]
          end
        end)

      columns ->
        [
          Core.error(
            :invalid_columns,
            path ++ [:columns],
            "domain relation #{inspect(relation_id)} columns must be a map",
            relation: relation_id,
            expected: :map,
            actual: Core.value_type(columns)
          )
          | errors
        ]
    end
  end

  def validate_relation_primary_key(errors, relation_id, relation, path) do
    fields = Core.map_value(relation, :fields)
    primary_key = Core.map_value(relation, :primary_key)

    cond do
      not Core.has_key?(relation, :primary_key) ->
        errors

      not is_nil(primary_key) and Core.field_ref?(primary_key) and not is_list(fields) ->
        errors

      not is_nil(primary_key) and Core.field_ref?(primary_key) and
          Core.field_in_list?(fields, primary_key) ->
        errors

      not is_nil(primary_key) and Core.field_ref?(primary_key) ->
        [
          Core.error(
            :primary_key_not_found,
            path ++ [:primary_key],
            "domain relation #{inspect(relation_id)} primary_key #{inspect(primary_key)} is not listed in fields",
            relation: relation_id,
            field: primary_key
          )
          | errors
        ]

      true ->
        [
          Core.error(
            :invalid_primary_key,
            path ++ [:primary_key],
            "domain relation #{inspect(relation_id)} primary_key must be an atom or string",
            relation: relation_id,
            expected: "atom or string",
            actual: Core.value_type(primary_key)
          )
          | errors
        ]
    end
  end

  def validate_relation_field_columns(errors, relation_id, relation, path) do
    fields = Core.map_value(relation, :fields)
    columns = Core.map_value(relation, :columns)

    if is_list(fields) and is_map(columns) do
      fields
      |> Enum.reject(&Core.has_key?(columns, &1))
      |> Enum.reduce(errors, fn field, acc ->
        [
          Core.error(
            field_missing_column_code(relation_id),
            path ++ [:columns, field],
            "domain relation #{inspect(relation_id)} field #{inspect(field)} is missing a column definition",
            relation: relation_id,
            field: field
          )
          | acc
        ]
      end)
    else
      errors
    end
  end

  def field_missing_column_code(:source), do: :source_field_missing_column
  def field_missing_column_code(_relation_id), do: :schema_field_missing_column

  defp validate_relation_source_kind(errors, relation_id, relation, path) do
    case Core.fetch_map_value(relation, :source_kind) do
      :__missing__ ->
        errors

      kind ->
        if Core.enum_value?(kind, [:table, :view, :materialized_view]) do
          errors
        else
          [
            Core.error(
              :invalid_source_kind,
              path ++ [:source_kind],
              "domain relation #{inspect(relation_id)} source_kind must be table, view, or materialized_view",
              relation: relation_id
            )
            | errors
          ]
        end
    end
  end

  defp validate_relation_readonly(errors, relation_id, relation, path) do
    case Core.fetch_map_value(relation, :readonly) do
      :__missing__ ->
        errors

      readonly when is_boolean(readonly) ->
        errors

      _ ->
        [
          Core.error(
            :invalid_readonly,
            path ++ [:readonly],
            "domain relation #{inspect(relation_id)} readonly must be boolean",
            relation: relation_id
          )
          | errors
        ]
    end
  end

  def validate_schemas(errors, schemas) when is_map(schemas) do
    Enum.reduce(schemas, errors, fn {schema_id, schema}, acc ->
      validate_relation(acc, schema_id, schema, [:schemas, schema_id])
    end)
  end

  def validate_schemas(errors, schemas) do
    [
      Core.error(
        :invalid_section_shape,
        [:schemas],
        "domain section :schemas must be a map",
        expected: :map,
        actual: Core.value_type(schemas)
      )
      | errors
    ]
  end
end
