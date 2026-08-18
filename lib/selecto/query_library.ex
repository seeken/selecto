defmodule Selecto.QueryLibrary do
  @moduledoc """
  Portable named query definitions attached to a Selecto domain.

  A query library separates common query intent into four semantic registries:

  * segments constrain row membership and compose through boolean operators
  * projections define and merge reusable result shapes
  * orderings define deterministic ordering
  * views compose the other definitions

  Required domain filters, selections, and ordering remain in force when a
  named definition is applied.
  """

  @registries [:segments, :projections, :orderings, :views]
  @parameter_types ~w(string integer float decimal boolean date datetime naive_datetime utc_datetime uuid)a

  @type definition_id :: atom() | String.t()
  @type library :: %{
          optional(:segments) => %{optional(definition_id()) => map()},
          optional(:projections) => %{optional(definition_id()) => map()},
          optional(:orderings) => %{optional(definition_id()) => map()},
          optional(:views) => %{optional(definition_id()) => map()}
        }

  @doc "Returns the configured domain's portable query library."
  @spec library(Selecto.t() | map()) :: library()
  def library(%Selecto{domain: domain}), do: library(domain)

  def library(domain) when is_map(domain) do
    case map_value(domain, :query_library) do
      library when is_map(library) -> normalize_library(library)
      _ -> empty_library()
    end
  end

  @doc "Returns definitions from one named registry."
  @spec definitions(Selecto.t() | map(), atom()) :: map()
  def definitions(selecto_or_domain, kind) when kind in @registries do
    selecto_or_domain
    |> library()
    |> Map.fetch!(kind)
  end

  @doc "Applies a named segment and its composed segments to a query."
  @spec apply_segment(Selecto.t(), definition_id(), map() | keyword()) :: Selecto.t()
  def apply_segment(%Selecto{} = selecto, segment_id, params \\ %{}) do
    apply_segments(selecto, [segment_id], params)
  end

  @doc "Applies one or more named projections, replacing optional selections with their merged shape."
  @spec apply_projection(Selecto.t(), definition_id() | [definition_id()]) :: Selecto.t()
  def apply_projection(%Selecto{} = selecto, projection_id_or_ids) do
    library = checked_library(selecto)

    projection_ids = definition_ids!(projection_id_or_ids, :projection)

    projection =
      Enum.reduce(projection_ids, empty_projection_resolution(), fn projection_id, acc ->
        merge_projection_resolutions(acc, resolve_projection!(library, projection_id, []))
      end)

    required = map_value(selecto.domain, :required_selected) || []
    shape = Enum.uniq(List.wrap(required) ++ projection_shape(projection))

    if shape == [] do
      raise ArgumentError,
            "projections #{inspect(projection_ids)} do not select any fields"
    end

    selecto = Selecto.SelectionShape.select_shape(selecto, shape)

    Enum.reduce(projection.ids, selecto, fn id, acc ->
      record_application(acc, :projection, id)
    end)
  end

  @doc "Applies a named ordering while preserving required domain ordering."
  @spec apply_ordering(Selecto.t(), definition_id()) :: Selecto.t()
  def apply_ordering(%Selecto{} = selecto, ordering_id) do
    library = checked_library(selecto)
    ordering = fetch_definition!(library.orderings, :ordering, ordering_id)
    required = map_value(selecto.domain, :required_order_by) || []
    order_by = map_value(ordering, :order_by) || []
    combined = Enum.uniq(List.wrap(required) ++ order_by)
    selecto = put_in(selecto.set.order_by, [])

    selecto =
      case combined do
        [] -> selecto
        orders -> Selecto.Query.order_by(selecto, orders)
      end

    record_application(selecto, :ordering, definition_key(ordering_id))
  end

  @doc "Applies the named segments, projection, and ordering declared by a view."
  @spec apply_view(Selecto.t(), definition_id(), map() | keyword()) :: Selecto.t()
  def apply_view(%Selecto{} = selecto, view_id, params \\ %{}) do
    library = checked_library(selecto)
    view = fetch_definition!(library.views, :view, view_id)

    selecto
    |> apply_segments(map_value(view, :segments) || [], params)
    |> maybe_apply_projection(map_value(view, :projection))
    |> maybe_apply_ordering(map_value(view, :ordering))
    |> record_application(:view, definition_key(view_id))
  end

  @doc "Returns named query definitions already applied to a query."
  @spec applied(Selecto.t()) :: map()
  def applied(%Selecto{} = selecto) do
    Map.get(selecto.set, :applied_query_library, default_applied())
  end

  @doc false
  @spec validate_library!(term()) :: :ok
  def validate_library!(library) do
    case structure_errors(library) do
      [] -> :ok
      errors -> raise ArgumentError, Enum.map_join(errors, "; ", & &1.message)
    end
  end

  @doc false
  @spec structure_errors(term()) :: [map()]
  def structure_errors(library) when is_map(library) do
    normalized = normalize_library(library)

    []
    |> validate_registries(library)
    |> validate_segments(normalized)
    |> validate_projections(normalized)
    |> validate_orderings(normalized)
    |> validate_views(normalized)
    |> validate_segment_cycles(normalized)
    |> validate_projection_cycles(normalized)
    |> Enum.reverse()
  end

  def structure_errors(library) do
    [error(:invalid_query_library, [:query_library], "query_library must be a map", library)]
  end

  defp checked_library(selecto) do
    library = library(selecto)
    validate_library!(library)
    library
  end

  defp apply_segments(selecto, [], params) do
    ensure_no_params!(params)
    selecto
  end

  defp apply_segments(selecto, segment_ids, params) when is_list(segment_ids) do
    library = checked_library(selecto)

    resolved =
      Enum.reduce(segment_ids, %{filters: [], parameters: %{}, ids: []}, fn segment_id, acc ->
        merge_resolved(acc, resolve_segment!(library, segment_id, []))
      end)

    values = normalize_parameters!(resolved.parameters, params)
    filters = substitute_parameters(resolved.filters, values)

    selecto =
      case filters do
        [] -> selecto
        filters -> Selecto.Query.filter(selecto, filters)
      end

    Enum.reduce(resolved.ids, selecto, &record_application(&2, :segment, &1))
  end

  defp apply_segments(_selecto, segment_ids, _params) do
    raise ArgumentError, "view segments must be a list, got: #{inspect(segment_ids)}"
  end

  defp resolve_segment!(library, segment_id, stack) do
    key = definition_key(segment_id)

    if key in stack do
      cycle = Enum.reverse([key | stack])
      raise ArgumentError, "query-library segment cycle detected: #{Enum.join(cycle, " -> ")}"
    end

    segment = fetch_definition!(library.segments, :segment, segment_id)

    included =
      Enum.reduce(
        map_value(segment, :segments) || [],
        %{filters: [], parameters: %{}, ids: []},
        fn id, acc ->
          merge_resolved(acc, resolve_segment!(library, id, [key | stack]))
        end
      )

    grouped =
      Enum.reduce(
        map_value(segment, :segment_groups) || [],
        %{filters: [], parameters: %{}, ids: []},
        fn group, acc ->
          merge_resolved(acc, resolve_segment_group!(library, group, [key | stack]))
        end
      )

    included
    |> merge_resolved(grouped)
    |> merge_resolved(%{
      filters: map_value(segment, :filters) || [],
      parameters: map_value(segment, :parameters) || %{},
      ids: [key]
    })
  end

  defp resolve_segment_group!(library, group, stack) do
    operator = normalize_boolean_operator(map_value(group, :operator))

    resolved_segments =
      group
      |> map_value(:segments)
      |> Enum.map(&resolve_segment!(library, &1, stack))

    merged =
      Enum.reduce(
        resolved_segments,
        %{filters: [], parameters: %{}, ids: []},
        &merge_resolved(&2, &1)
      )

    filters =
      case operator do
        :and ->
          Enum.flat_map(resolved_segments, & &1.filters)

        :or ->
          operands = Enum.map(resolved_segments, &segment_operand/1)

          if Enum.any?(operands, &is_nil/1) do
            []
          else
            logical_filters(operands, :or)
          end

        operator when operator in [:not, :nor, :xor] ->
          operands = Enum.map(resolved_segments, &segment_operand/1)

          if Enum.any?(operands, &is_nil/1) do
            raise ArgumentError,
                  "#{operator} segment groups cannot reference an unconstrained segment"
          end

          lower_boolean_group(operator, operands)
      end

    %{merged | filters: filters}
  end

  defp segment_operand(%{filters: []}), do: nil
  defp segment_operand(%{filters: [filter]}), do: filter
  defp segment_operand(%{filters: filters}), do: {:and, filters}

  defp logical_filters([], _operator), do: []
  defp logical_filters([filter], _operator), do: [filter]
  defp logical_filters(filters, operator), do: [{operator, filters}]

  defp lower_boolean_group(:not, [filter]), do: [{:not, filter}]
  defp lower_boolean_group(:nor, filters), do: [{:not, {:or, filters}}]

  defp lower_boolean_group(:xor, [left, right]) do
    [{:and, [{:or, [left, right]}, {:not, {:and, [left, right]}}]}]
  end

  defp merge_resolved(left, right) do
    %{
      filters: left.filters ++ right.filters,
      parameters: merge_parameter_specs!(left.parameters, right.parameters),
      ids: Enum.uniq(left.ids ++ right.ids)
    }
  end

  defp merge_parameter_specs!(left, right) do
    Enum.reduce(right, left, fn {id, spec}, acc ->
      case fetch_entry(acc, id) do
        nil ->
          Map.put(acc, id, spec)

        {_existing_id, ^spec} ->
          acc

        {_existing_id, existing_spec} ->
          raise ArgumentError,
                "conflicting definitions for segment parameter #{inspect(id)}: #{inspect(existing_spec)} and #{inspect(spec)}"
      end
    end)
  end

  defp resolve_projection!(library, projection_id, stack) do
    key = definition_key(projection_id)

    if key in stack do
      cycle = Enum.reverse([key | stack])
      raise ArgumentError, "query-library projection cycle detected: #{Enum.join(cycle, " -> ")}"
    end

    projection = fetch_definition!(library.projections, :projection, projection_id)

    included =
      Enum.reduce(
        map_value(projection, :projections) || [],
        empty_projection_resolution(),
        fn id, acc ->
          merge_projection_resolutions(acc, resolve_projection!(library, id, [key | stack]))
        end
      )

    merge_projection_resolutions(included, %{
      fields: map_value(projection, :fields) || [],
      associations: map_value(projection, :associations) || [],
      ids: [key]
    })
  end

  defp merge_projection_resolutions(left, right) do
    %{
      fields: Enum.uniq(left.fields ++ right.fields),
      associations: merge_associations(left.associations, right.associations),
      ids: Enum.uniq(left.ids ++ right.ids)
    }
  end

  defp merge_associations(left, right) do
    Enum.reduce(right, left, fn association, acc ->
      name = map_value(association, :name)

      case Enum.find_index(acc, &(definition_key(map_value(&1, :name)) == definition_key(name))) do
        nil ->
          acc ++ [normalize_association(association)]

        index ->
          List.update_at(acc, index, &merge_association(&1, association))
      end
    end)
  end

  defp merge_association(left, right) do
    %{
      name: map_value(left, :name),
      fields:
        Enum.uniq(List.wrap(map_value(left, :fields)) ++ List.wrap(map_value(right, :fields))),
      associations:
        merge_associations(
          List.wrap(map_value(left, :associations)),
          List.wrap(map_value(right, :associations))
        )
    }
  end

  defp normalize_association(association) do
    %{
      name: map_value(association, :name),
      fields: List.wrap(map_value(association, :fields)),
      associations: merge_associations([], List.wrap(map_value(association, :associations)))
    }
  end

  defp empty_projection_resolution, do: %{fields: [], associations: [], ids: []}

  defp normalize_parameters!(specs, params) when is_list(params) do
    if Keyword.keyword?(params) do
      normalize_parameters!(specs, Map.new(params))
    else
      raise ArgumentError, "segment parameters must be a map or keyword list"
    end
  end

  defp normalize_parameters!(specs, params) when is_map(params) do
    unknown =
      params
      |> Map.keys()
      |> Enum.reject(&entry_exists?(specs, &1))

    if unknown != [] do
      raise ArgumentError, "unknown segment parameters: #{inspect(unknown)}"
    end

    Enum.reduce(specs, %{}, fn {id, spec}, acc ->
      value =
        case fetch_entry(params, id) do
          {_input_id, input} ->
            input

          nil ->
            cond do
              map_has_key?(spec, :default) -> map_value(spec, :default)
              map_value(spec, :required) == false -> nil
              true -> raise ArgumentError, "missing required segment parameter #{inspect(id)}"
            end
        end

      Map.put(acc, definition_key(id), cast_parameter!(id, map_value(spec, :type), value))
    end)
  end

  defp normalize_parameters!(_specs, params) do
    raise ArgumentError,
          "segment parameters must be a map or keyword list, got: #{inspect(params)}"
  end

  defp cast_parameter!(_id, _type, nil), do: nil

  defp cast_parameter!(_id, type, value) when type in [:string, "string"] and is_binary(value),
    do: value

  defp cast_parameter!(_id, type, value) when type in [:integer, "integer"] and is_integer(value),
    do: value

  defp cast_parameter!(id, type, value) when type in [:integer, "integer"] and is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> invalid_parameter!(id, type, value)
    end
  end

  defp cast_parameter!(_id, type, value) when type in [:float, "float"] and is_float(value),
    do: value

  defp cast_parameter!(_id, type, value)
       when type in [:float, "float"] and is_integer(value),
       do: value / 1

  defp cast_parameter!(id, type, value) when type in [:float, "float"] and is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> invalid_parameter!(id, type, value)
    end
  end

  defp cast_parameter!(_id, type, %Decimal{} = value) when type in [:decimal, "decimal"],
    do: value

  defp cast_parameter!(id, type, value)
       when type in [:decimal, "decimal"] and (is_binary(value) or is_integer(value)) do
    Decimal.new(value)
  rescue
    _ -> invalid_parameter!(id, type, value)
  end

  defp cast_parameter!(_id, type, value)
       when type in [:boolean, "boolean"] and is_boolean(value),
       do: value

  defp cast_parameter!(_id, type, "true") when type in [:boolean, "boolean"], do: true
  defp cast_parameter!(_id, type, "false") when type in [:boolean, "boolean"], do: false
  defp cast_parameter!(_id, type, %Date{} = value) when type in [:date, "date"], do: value

  defp cast_parameter!(id, type, value) when type in [:date, "date"] and is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> invalid_parameter!(id, type, value)
    end
  end

  defp cast_parameter!(_id, type, %NaiveDateTime{} = value)
       when type in [:datetime, "datetime", :naive_datetime, "naive_datetime"],
       do: value

  defp cast_parameter!(id, type, value)
       when type in [:datetime, "datetime", :naive_datetime, "naive_datetime"] and
              is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} -> datetime
      _ -> invalid_parameter!(id, type, value)
    end
  end

  defp cast_parameter!(_id, type, %DateTime{} = value)
       when type in [:utc_datetime, "utc_datetime"],
       do: value

  defp cast_parameter!(id, type, value)
       when type in [:utc_datetime, "utc_datetime"] and is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> invalid_parameter!(id, type, value)
    end
  end

  defp cast_parameter!(_id, type, value)
       when type in [:uuid, "uuid"] and is_binary(value),
       do: value

  defp cast_parameter!(id, type, value) do
    if known_parameter_type?(type) do
      invalid_parameter!(id, type, value)
    else
      value
    end
  end

  defp known_parameter_type?(type) when is_atom(type), do: type in @parameter_types

  defp known_parameter_type?(type) when is_binary(type) do
    Enum.any?(@parameter_types, &(Atom.to_string(&1) == type))
  end

  defp known_parameter_type?(_type), do: false

  defp invalid_parameter!(id, type, value) do
    raise ArgumentError,
          "segment parameter #{inspect(id)} must be #{inspect(type)}, got: #{inspect(value)}"
  end

  defp substitute_parameters({:param, id}, values) do
    case Map.fetch(values, definition_key(id)) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing resolved segment parameter #{inspect(id)}"
    end
  end

  defp substitute_parameters(value, values) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&substitute_parameters(&1, values))
    |> List.to_tuple()
  end

  defp substitute_parameters(value, values) when is_list(value) do
    Enum.map(value, &substitute_parameters(&1, values))
  end

  defp substitute_parameters(value, values) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {substitute_parameters(key, values), substitute_parameters(item, values)}
    end)
  end

  defp substitute_parameters(value, _values), do: value

  defp projection_shape(projection) do
    fields = map_value(projection, :fields) || []
    associations = map_value(projection, :associations) || []
    fields ++ Enum.map(associations, &association_shape(&1, nil))
  end

  defp association_shape(association, parent_path) do
    name = map_value(association, :name)
    path = if is_nil(parent_path), do: to_string(name), else: "#{parent_path}.#{name}"

    fields =
      association
      |> map_value(:fields)
      |> List.wrap()
      |> Enum.map(&"#{path}.#{&1}")

    nested =
      association
      |> map_value(:associations)
      |> List.wrap()
      |> Enum.map(&association_shape(&1, path))

    fields ++ nested
  end

  defp maybe_apply_projection(selecto, nil), do: selecto
  defp maybe_apply_projection(selecto, projection), do: apply_projection(selecto, projection)
  defp maybe_apply_ordering(selecto, nil), do: selecto
  defp maybe_apply_ordering(selecto, ordering), do: apply_ordering(selecto, ordering)

  defp ensure_no_params!(params) when params in [[], %{}], do: :ok

  defp ensure_no_params!(params),
    do: raise(ArgumentError, "view does not accept parameters: #{inspect(params)}")

  defp record_application(selecto, kind, id) do
    applied = applied(selecto)

    updated =
      case kind do
        :segment ->
          Map.update!(applied, :segments, &Enum.uniq(&1 ++ [id]))

        :projection ->
          applied
          |> Map.put(:projection, id)
          |> Map.update(:projections, [id], &Enum.uniq(&1 ++ [id]))

        :ordering ->
          Map.put(applied, :ordering, id)

        :view ->
          Map.update!(applied, :views, &Enum.uniq(&1 ++ [id]))
      end

    put_in(selecto.set, Map.put(selecto.set, :applied_query_library, updated))
  end

  defp default_applied,
    do: %{segments: [], projection: nil, projections: [], ordering: nil, views: []}

  defp empty_library do
    %{segments: %{}, projections: %{}, orderings: %{}, views: %{}}
  end

  defp normalize_library(library) do
    Enum.reduce(@registries, empty_library(), fn registry, acc ->
      value = map_value(library, registry)
      Map.put(acc, registry, if(is_map(value), do: value, else: %{}))
    end)
  end

  defp validate_registries(errors, library) do
    Enum.reduce(@registries, errors, fn registry, acc ->
      case map_value(library, registry) do
        nil ->
          acc

        value when is_map(value) ->
          acc

        value ->
          [
            error(
              :invalid_query_library_registry,
              [:query_library, registry],
              "query_library #{registry} must be a map",
              value
            )
            | acc
          ]
      end
    end)
  end

  defp validate_segments(errors, library) do
    Enum.reduce(library.segments, errors, fn {id, spec}, acc ->
      acc
      |> validate_definition_id(:segment, id)
      |> validate_map_spec(:segment, id, spec)
      |> validate_list_key(:segment, id, spec, :filters)
      |> validate_list_key(:segment, id, spec, :segments)
      |> validate_list_key(:segment, id, spec, :segment_groups)
      |> validate_map_key(:segment, id, spec, :parameters)
      |> validate_parameter_specs(id, spec)
      |> validate_segment_references(id, spec, library)
      |> validate_segment_groups(id, spec, library)
    end)
  end

  defp validate_projections(errors, library) do
    Enum.reduce(library.projections, errors, fn {id, spec}, acc ->
      acc
      |> validate_definition_id(:projection, id)
      |> validate_map_spec(:projection, id, spec)
      |> validate_list_key(:projection, id, spec, :fields)
      |> validate_list_key(:projection, id, spec, :associations)
      |> validate_list_key(:projection, id, spec, :projections)
      |> validate_projection_references(id, spec, library)
      |> validate_projection_associations(id, spec)
    end)
  end

  defp validate_orderings(errors, library) do
    Enum.reduce(library.orderings, errors, fn {id, spec}, acc ->
      acc
      |> validate_definition_id(:ordering, id)
      |> validate_map_spec(:ordering, id, spec)
      |> validate_list_key(:ordering, id, spec, :order_by)
    end)
  end

  defp validate_views(errors, library) do
    Enum.reduce(library.views, errors, fn {id, spec}, acc ->
      acc
      |> validate_definition_id(:view, id)
      |> validate_map_spec(:view, id, spec)
      |> validate_list_key(:view, id, spec, :segments)
      |> validate_view_references(id, spec, library)
    end)
  end

  defp validate_definition_id(errors, kind, id) do
    if valid_id?(id) do
      errors
    else
      [
        error(
          :invalid_query_definition_id,
          [:query_library, registry_for(kind), id],
          "#{kind} id must be a non-empty atom or string",
          id
        )
        | errors
      ]
    end
  end

  defp validate_map_spec(errors, _kind, _id, spec) when is_map(spec), do: errors

  defp validate_map_spec(errors, kind, id, spec) do
    [
      error(
        :invalid_query_definition,
        [:query_library, registry_for(kind), id],
        "#{kind} #{inspect(id)} must be a map",
        spec
      )
      | errors
    ]
  end

  defp validate_list_key(errors, _kind, _id, spec, _key) when not is_map(spec), do: errors

  defp validate_list_key(errors, kind, id, spec, key) do
    case map_value(spec, key) do
      nil ->
        errors

      value when is_list(value) ->
        errors

      value ->
        [
          error(
            :invalid_query_definition,
            [:query_library, registry_for(kind), id, key],
            "#{kind} #{inspect(id)} #{key} must be a list",
            value
          )
          | errors
        ]
    end
  end

  defp validate_map_key(errors, _kind, _id, spec, _key) when not is_map(spec), do: errors

  defp validate_map_key(errors, kind, id, spec, key) do
    case map_value(spec, key) do
      nil ->
        errors

      value when is_map(value) ->
        errors

      value ->
        [
          error(
            :invalid_query_definition,
            [:query_library, registry_for(kind), id, key],
            "#{kind} #{inspect(id)} #{key} must be a map",
            value
          )
          | errors
        ]
    end
  end

  defp validate_parameter_specs(errors, _segment_id, spec) when not is_map(spec), do: errors

  defp validate_parameter_specs(errors, segment_id, spec) do
    case map_value(spec, :parameters) do
      parameters when is_map(parameters) ->
        Enum.reduce(parameters, errors, fn {parameter_id, parameter_spec}, acc ->
          cond do
            not valid_id?(parameter_id) ->
              [
                error(
                  :invalid_segment_parameter,
                  [:query_library, :segments, segment_id, :parameters, parameter_id],
                  "segment parameter ids must be non-empty atoms or strings",
                  parameter_id
                )
                | acc
              ]

            not is_map(parameter_spec) ->
              [
                error(
                  :invalid_segment_parameter,
                  [:query_library, :segments, segment_id, :parameters, parameter_id],
                  "segment parameter definitions must be maps",
                  parameter_spec
                )
                | acc
              ]

            not valid_id?(map_value(parameter_spec, :type)) ->
              [
                error(
                  :invalid_segment_parameter,
                  [:query_library, :segments, segment_id, :parameters, parameter_id, :type],
                  "segment parameter types must be atoms or strings",
                  map_value(parameter_spec, :type)
                )
                | acc
              ]

            true ->
              acc
          end
        end)

      _ ->
        errors
    end
  end

  defp validate_segment_references(errors, _id, spec, _library) when not is_map(spec), do: errors

  defp validate_segment_references(errors, id, spec, library) do
    Enum.reduce(List.wrap(map_value(spec, :segments)), errors, fn reference, acc ->
      if entry_exists?(library.segments, reference) do
        acc
      else
        [
          error(
            :query_segment_not_found,
            [:query_library, :segments, id, :segments],
            "segment #{inspect(id)} references missing segment #{inspect(reference)}",
            reference
          )
          | acc
        ]
      end
    end)
  end

  defp validate_segment_groups(errors, _id, spec, _library) when not is_map(spec), do: errors

  defp validate_segment_groups(errors, id, spec, library) do
    case map_value(spec, :segment_groups) do
      groups when is_list(groups) ->
        groups
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {group, index}, acc ->
          validate_segment_group(
            acc,
            group,
            [:query_library, :segments, id, :segment_groups, index],
            id,
            library
          )
        end)

      _ ->
        errors
    end
  end

  defp validate_segment_group(errors, group, path, segment_id, library) when is_map(group) do
    operator = normalize_boolean_operator(map_value(group, :operator))
    segments = map_value(group, :segments)

    distinct_segments =
      if is_list(segments), do: Enum.uniq_by(segments, &definition_key/1), else: []

    errors =
      cond do
        operator not in [:and, :or, :not, :nor, :xor] ->
          [
            error(
              :invalid_query_segment_group,
              path ++ [:operator],
              "segment boolean group operator must be :and, :or, :not, :nor, or :xor",
              map_value(group, :operator)
            )
            | errors
          ]

        operator == :not and not (is_list(segments) and length(segments) == 1) ->
          [
            error(
              :invalid_query_segment_group,
              path ++ [:segments],
              "not segment groups require exactly one segment",
              segments
            )
            | errors
          ]

        operator == :xor and not (is_list(segments) and length(distinct_segments) == 2) ->
          [
            error(
              :invalid_query_segment_group,
              path ++ [:segments],
              "xor segment groups require exactly two segments",
              segments
            )
            | errors
          ]

        not is_list(segments) or segments == [] ->
          [
            error(
              :invalid_query_segment_group,
              path ++ [:segments],
              "segment boolean groups require a non-empty segment list",
              segments
            )
            | errors
          ]

        true ->
          errors
      end

    if is_list(segments) do
      Enum.reduce(segments, errors, fn reference, acc ->
        if entry_exists?(library.segments, reference) do
          acc
        else
          [
            error(
              :query_segment_not_found,
              path ++ [:segments],
              "segment #{inspect(segment_id)} references missing segment #{inspect(reference)}",
              reference
            )
            | acc
          ]
        end
      end)
    else
      errors
    end
  end

  defp validate_segment_group(errors, group, path, _segment_id, _library) do
    [
      error(
        :invalid_query_segment_group,
        path,
        "segment boolean groups must be maps",
        group
      )
      | errors
    ]
  end

  defp validate_projection_references(errors, _id, spec, _library) when not is_map(spec),
    do: errors

  defp validate_projection_references(errors, id, spec, library) do
    Enum.reduce(List.wrap(map_value(spec, :projections)), errors, fn reference, acc ->
      if entry_exists?(library.projections, reference) do
        acc
      else
        [
          error(
            :query_projection_not_found,
            [:query_library, :projections, id, :projections],
            "projection #{inspect(id)} references missing projection #{inspect(reference)}",
            reference
          )
          | acc
        ]
      end
    end)
  end

  defp validate_projection_associations(errors, _id, spec) when not is_map(spec), do: errors

  defp validate_projection_associations(errors, id, spec) do
    validate_association_specs(
      errors,
      map_value(spec, :associations),
      [:query_library, :projections, id, :associations]
    )
  end

  defp validate_association_specs(errors, associations, path) when is_list(associations) do
    associations
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {association, index}, acc ->
      association_path = path ++ [index]

      if is_map(association) do
        nested = map_value(association, :associations)

        acc
        |> maybe_add_association_error(
          valid_id?(map_value(association, :name)),
          association_path ++ [:name],
          "projection association names must be non-empty atoms or strings",
          map_value(association, :name)
        )
        |> maybe_add_association_error(
          nil_or_list?(map_value(association, :fields)),
          association_path ++ [:fields],
          "projection association fields must be a list",
          map_value(association, :fields)
        )
        |> maybe_add_association_error(
          nil_or_list?(nested),
          association_path ++ [:associations],
          "nested projection associations must be a list",
          nested
        )
        |> validate_association_specs(nested, association_path ++ [:associations])
      else
        [
          error(
            :invalid_query_projection_association,
            association_path,
            "projection associations must be maps",
            association
          )
          | acc
        ]
      end
    end)
  end

  defp validate_association_specs(errors, _associations, _path), do: errors

  defp maybe_add_association_error(errors, true, _path, _message, _actual), do: errors

  defp maybe_add_association_error(errors, false, path, message, actual) do
    [error(:invalid_query_projection_association, path, message, actual) | errors]
  end

  defp nil_or_list?(nil), do: true
  defp nil_or_list?(value), do: is_list(value)

  defp validate_view_references(errors, _id, spec, _library) when not is_map(spec), do: errors

  defp validate_view_references(errors, id, spec, library) do
    errors =
      Enum.reduce(List.wrap(map_value(spec, :segments)), errors, fn reference, acc ->
        validate_reference(acc, library.segments, :segment, id, reference)
      end)

    errors
    |> validate_optional_reference(
      library.projections,
      :projection,
      id,
      map_value(spec, :projection)
    )
    |> validate_optional_reference(library.orderings, :ordering, id, map_value(spec, :ordering))
  end

  defp validate_reference(errors, registry, kind, view_id, reference) do
    if entry_exists?(registry, reference) do
      errors
    else
      [
        error(
          :query_definition_not_found,
          [:query_library, :views, view_id, kind],
          "view #{inspect(view_id)} references missing #{kind} #{inspect(reference)}",
          reference
        )
        | errors
      ]
    end
  end

  defp validate_optional_reference(errors, _registry, _kind, _view_id, nil), do: errors

  defp validate_optional_reference(errors, registry, kind, view_id, reference) do
    validate_reference(errors, registry, kind, view_id, reference)
  end

  defp validate_segment_cycles(errors, library) do
    Enum.reduce(Map.keys(library.segments), errors, fn id, acc ->
      case find_segment_cycle(library, id, []) do
        nil ->
          acc

        cycle ->
          [
            error(
              :query_segment_cycle,
              [:query_library, :segments, id],
              "query-library segment cycle detected: #{Enum.join(cycle, " -> ")}",
              cycle
            )
            | acc
          ]
      end
    end)
  end

  defp find_segment_cycle(library, id, stack) do
    key = definition_key(id)

    if key in stack do
      Enum.reverse([key | stack])
    else
      case fetch_entry(library.segments, id) do
        {_stored_id, spec} when is_map(spec) ->
          Enum.find_value(segment_references(spec), fn child ->
            find_segment_cycle(library, child, [key | stack])
          end)

        _ ->
          nil
      end
    end
  end

  defp segment_references(spec) do
    grouped =
      spec
      |> map_value(:segment_groups)
      |> List.wrap()
      |> Enum.flat_map(fn
        group when is_map(group) -> List.wrap(map_value(group, :segments))
        _group -> []
      end)

    List.wrap(map_value(spec, :segments)) ++ grouped
  end

  defp validate_projection_cycles(errors, library) do
    Enum.reduce(Map.keys(library.projections), errors, fn id, acc ->
      case find_projection_cycle(library, id, []) do
        nil ->
          acc

        cycle ->
          [
            error(
              :query_projection_cycle,
              [:query_library, :projections, id],
              "query-library projection cycle detected: #{Enum.join(cycle, " -> ")}",
              cycle
            )
            | acc
          ]
      end
    end)
  end

  defp find_projection_cycle(library, id, stack) do
    key = definition_key(id)

    if key in stack do
      Enum.reverse([key | stack])
    else
      case fetch_entry(library.projections, id) do
        {_stored_id, spec} when is_map(spec) ->
          Enum.find_value(List.wrap(map_value(spec, :projections)), fn child ->
            find_projection_cycle(library, child, [key | stack])
          end)

        _ ->
          nil
      end
    end
  end

  defp fetch_definition!(registry, kind, id) do
    case fetch_entry(registry, id) do
      {_stored_id, spec} when is_map(spec) -> spec
      _ -> raise ArgumentError, "unknown query-library #{kind} #{inspect(id)}"
    end
  end

  defp fetch_entry(map, key) when is_map(map) do
    target = definition_key(key)
    Enum.find(map, fn {candidate, _value} -> definition_key(candidate) == target end)
  end

  defp entry_exists?(map, key), do: not is_nil(fetch_entry(map, key))

  defp definition_ids!(ids, kind) when is_list(ids) do
    if ids != [] and Enum.all?(ids, &valid_id?/1) do
      ids
    else
      raise ArgumentError,
            "#{kind} names must be a non-empty name or list of names, got: #{inspect(ids)}"
    end
  end

  defp definition_ids!(id, _kind) when is_atom(id) and not is_nil(id), do: [id]

  defp definition_ids!(id, _kind) when is_binary(id) and id != "", do: [id]

  defp definition_ids!(id, kind) do
    raise ArgumentError,
          "#{kind} names must be a non-empty name or list of names, got: #{inspect(id)}"
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp map_value(_map, _key), do: nil

  defp map_has_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or (is_atom(key) and Map.has_key?(map, Atom.to_string(key)))
  end

  defp valid_id?(value) when is_atom(value), do: not is_nil(value)
  defp valid_id?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_id?(_value), do: false

  defp normalize_boolean_operator(operator) when operator in [:and, "and"], do: :and
  defp normalize_boolean_operator(operator) when operator in [:or, "or"], do: :or
  defp normalize_boolean_operator(operator) when operator in [:not, "not"], do: :not
  defp normalize_boolean_operator(operator) when operator in [:nor, "nor"], do: :nor
  defp normalize_boolean_operator(operator) when operator in [:xor, "xor"], do: :xor
  defp normalize_boolean_operator(_operator), do: nil

  defp definition_key(value) when is_atom(value), do: Atom.to_string(value)
  defp definition_key(value) when is_binary(value), do: value
  defp definition_key(value), do: inspect(value)

  defp registry_for(:segment), do: :segments
  defp registry_for(:projection), do: :projections
  defp registry_for(:ordering), do: :orderings
  defp registry_for(:view), do: :views

  defp error(code, path, message, actual) do
    %{code: code, path: path, message: message, actual: value_type(actual)}
  end

  defp value_type(value) when is_map(value), do: :map
  defp value_type(value) when is_list(value), do: :list
  defp value_type(value) when is_tuple(value), do: :tuple
  defp value_type(value) when is_atom(value), do: :atom
  defp value_type(value) when is_binary(value), do: :string
  defp value_type(value) when is_integer(value), do: :integer
  defp value_type(value) when is_float(value), do: :float
  defp value_type(_value), do: :term
end
