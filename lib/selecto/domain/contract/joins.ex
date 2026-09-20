defmodule Selecto.Domain.Contract.Joins do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core

  def validate(errors, joins, source, schemas) do
    validate_joins(errors, joins, source, schemas)
  end

  def validate_joins(errors, joins, source, schemas) when is_map(joins) do
    validate_join_tree(errors, joins, source, schemas, [:joins], :source)
  end

  def validate_joins(errors, joins, _source, _schemas) do
    [
      Core.error(
        :invalid_section_shape,
        [:joins],
        "domain section :joins must be a map",
        expected: :map,
        actual: Core.value_type(joins)
      )
      | errors
    ]
  end

  def validate_join_tree(errors, joins, parent_relation, schemas, path, parent_id)
      when is_map(joins) do
    Enum.reduce(joins, errors, fn {join_id, join_config}, acc ->
      join_path = path ++ [join_id]

      acc
      |> validate_join_config_shape(join_config, join_path)
      |> validate_join_association(
        join_id,
        join_config,
        parent_relation,
        schemas,
        join_path,
        parent_id
      )
    end)
  end

  def validate_join_config_shape(errors, join_config, path) when is_map(join_config) do
    case Core.map_value(join_config, :joins) do
      nil ->
        errors

      nested_joins when is_map(nested_joins) ->
        errors

      nested_joins ->
        [
          Core.error(
            :invalid_section_shape,
            path ++ [:joins],
            "nested joins must be a map",
            expected: :map,
            actual: Core.value_type(nested_joins)
          )
          | errors
        ]
    end
  end

  def validate_join_config_shape(errors, join_config, path) do
    [
      Core.error(
        :invalid_section_shape,
        path,
        "join configuration must be a map",
        expected: :map,
        actual: Core.value_type(join_config)
      )
      | errors
    ]
  end

  def validate_join_association(
        errors,
        _join_id,
        join_config,
        _parent_relation,
        _schemas,
        _path,
        _parent_id
      )
      when not is_map(join_config),
      do: errors

  def validate_join_association(
        errors,
        join_id,
        join_config,
        parent_relation,
        schemas,
        path,
        parent_id
      ) do
    associations = relation_associations(parent_relation)

    case Core.fetch_key(associations, join_id) do
      {:ok, association} ->
        errors
        |> validate_display_fallback(join_config, association, parent_relation, schemas, path)
        |> validate_join_target(join_id, join_config, association, schemas, path)

      :error ->
        [
          Core.error(
            :join_missing_association,
            path,
            "join #{inspect(join_id)} is not declared as an association on #{inspect(parent_id)}",
            parent: parent_id,
            join: join_id
          )
          | errors
        ]
    end
  end

  defp validate_display_fallback(errors, join, association, parent, schemas, path) do
    fallback = Core.map_value(join, :display_fallback)

    if is_nil(fallback) do
      errors
    else
      mode = Core.map_value(join, :type)

      target =
        case Core.fetch_key(schemas, Core.map_value(association, :queryable)) do
          {:ok, relation} -> relation
          :error -> nil
        end

      owner_type = column_type(parent, Core.map_value(association, :owner_key))
      display_type = column_type(target, Core.map_value(join, :display_field) || :name)

      cond do
        mode not in [:star_dimension, "star_dimension"] ->
          [
            Core.error(
              :invalid_display_fallback,
              path ++ [:display_fallback],
              "display fallback is available only for star dimensions"
            )
            | errors
          ]

        fallback not in [:dimension_key, "dimension_key"] ->
          [
            Core.error(
              :invalid_display_fallback,
              path ++ [:display_fallback],
              "star dimension display fallback must be dimension_key"
            )
            | errors
          ]

        is_nil(owner_type) or owner_type != display_type ->
          [
            Core.error(
              :invalid_display_fallback,
              path ++ [:display_fallback],
              "star dimension display fallback requires matching display and key types"
            )
            | errors
          ]

        true ->
          errors
      end
    end
  end

  defp column_type(relation, field) when is_map(relation) and not is_nil(field) do
    columns = Core.map_value(relation, :columns) || %{}

    case Core.fetch_key(columns, field) do
      {:ok, column} when is_map(column) -> Core.map_value(column, :type)
      _ -> nil
    end
  end

  defp column_type(_, _), do: nil

  def validate_join_target(errors, join_id, join_config, association, schemas, path) do
    queryable = Core.map_value(association, :queryable)

    cond do
      is_nil(queryable) ->
        [
          Core.error(
            :join_association_missing_queryable,
            path,
            "join #{inspect(join_id)} association is missing :queryable",
            join: join_id
          )
          | errors
        ]

      Core.fetch_key(schemas, queryable) == :error and queryable != :source and
          queryable != "source" ->
        [
          Core.error(
            :join_target_schema_not_found,
            path,
            "join #{inspect(join_id)} targets missing schema #{inspect(queryable)}",
            join: join_id,
            schema: queryable
          )
          | errors
        ]

      true ->
        case Core.map_value(join_config, :joins) do
          nested_joins when is_map(nested_joins) ->
            target_relation =
              if queryable == :source or queryable == "source" do
                nil
              else
                {:ok, relation} = Core.fetch_key(schemas, queryable)
                relation
              end

            validate_join_tree(
              errors,
              nested_joins,
              target_relation,
              schemas,
              path ++ [:joins],
              queryable
            )

          _ ->
            errors
        end
    end
  end

  def relation_associations(relation) when is_map(relation) do
    case Core.map_value(relation, :associations) do
      associations when is_map(associations) -> associations
      _ -> %{}
    end
  end

  def relation_associations(_relation), do: %{}
end
