defmodule Selecto.Domain.JsonV1 do
  @moduledoc false

  # The canonical JSON v1 parser's key tables (certification specification
  # 4.1.0, domain_contract_export 1.5.0 DC002) and their admission check.
  # `Selecto.Domain.validate_json/1` applies them; `Selecto.Domain.validate/1`
  # and native (atom-map) authoring keep Selecto's open join vocabulary.

  @top_level ~w(actions associations capabilities choice_sources co_domains columns components
                custom_columns default_selected detail_actions domain_data domain_dependencies
                domain_fingerprint domain_version editors events experiences extensions filters
                functions imports joins json_schemas jsonb_schemas name operations pagination
                published_views query_library query_members redact_fields require_tenant
                required_filters required_group_by required_order_by required_selected retarget
                rules schema_version schemas source source_relationships subfilters
                tenant_required window_functions writes)
  @relation ~w(associations columns fields primary_key readonly redact_fields source_kind
               source_table tenant_field values)
  @source Enum.sort(["fts5_index" | @relation])
  @association ~w(cardinality conditions field join_strategy owner_key queryable related_key
                  source_scope_key target_scope_key through where)
  @join ~w(alias dimension_key display_fallback display_field fields joins name on source type)
  @through ~w(owner_key related_key source_scope_key table target_key_cast target_scope_key
              through_scope_key where)
  @join_types ~w(left inner star_dimension right full)

  @doc false
  def tables do
    %{
      top_level: @top_level,
      source: @source,
      relation: @relation,
      association: @association,
      join: @join,
      through: @through,
      join_types: @join_types
    }
  end

  @doc false
  # Errors for keys outside the tables, a join type outside @join_types and a
  # `through` that is not an object, each `:invalid_domain` with a `reason`.
  @spec errors(map()) :: [map()]
  def errors(domain) when is_map(domain) do
    schemas = value(domain, "schemas")
    schemas = if is_map(schemas), do: schemas, else: %{}
    source = value(domain, "source")

    []
    |> unknown(domain, @top_level, [])
    |> unknown(source, @source, [:source])
    |> associations(source, [:source])
    |> then(fn errors ->
      Enum.reduce(sorted(schemas), errors, fn {name, relation}, errors ->
        errors
        |> unknown(relation, @relation, [:schemas, name])
        |> associations(relation, [:schemas, name])
      end)
    end)
    |> joins(value(domain, "joins"), [:joins])
    |> Enum.reverse()
  end

  def errors(_domain), do: []

  defp associations(errors, relation, path) when is_map(relation) do
    case value(relation, "associations") do
      associations when is_map(associations) ->
        Enum.reduce(sorted(associations), errors, fn {name, association}, errors ->
          association_path = path ++ [:associations, name]

          errors
          |> unknown(association, @association, association_path)
          |> through(association, association_path)
        end)

      _ ->
        errors
    end
  end

  defp associations(errors, _relation, _path), do: errors

  defp through(errors, association, path) when is_map(association) do
    case fetch(association, "through") do
      {:ok, through} when is_map(through) ->
        unknown(errors, through, @through, path ++ [:through])

      {:ok, _through} ->
        [
          error(path ++ [:through], :invalid_through, "association through must be an object")
          | errors
        ]

      :error ->
        errors
    end
  end

  defp through(errors, _association, _path), do: errors

  defp joins(errors, joins, path) when is_map(joins) do
    Enum.reduce(sorted(joins), errors, fn {name, join}, errors ->
      join_path = path ++ [name]

      if is_map(join) do
        errors
        |> unknown(join, @join, join_path)
        |> join_type(fetch(join, "type"), join_path ++ [:type])
        |> joins(value(join, "joins"), join_path ++ [:joins])
      else
        errors
      end
    end)
  end

  defp joins(errors, _joins, _path), do: errors

  defp join_type(errors, :error, _path), do: errors

  defp join_type(errors, {:ok, type}, path) when is_binary(type) or is_atom(type) do
    if not is_nil(type) and String.downcase(to_string(type)) in @join_types,
      do: errors,
      else: [unsupported_join_type(path, type) | errors]
  end

  defp join_type(errors, {:ok, type}, path), do: [unsupported_join_type(path, type) | errors]

  defp unsupported_join_type(path, type),
    do:
      error(
        path,
        :unsupported_join_type,
        "unsupported join type #{inspect(type)}; expected one of #{Enum.join(@join_types, ", ")}",
        type: type
      )

  defp unknown(errors, map, allowed, path) when is_map(map) and not is_struct(map) do
    case map |> Map.keys() |> Enum.reject(&(name(&1) in allowed)) |> Enum.sort_by(&name/1) do
      [] ->
        errors

      keys ->
        [
          error(
            path,
            :unknown_domain_key,
            "unknown keys at #{location(path)}: #{Enum.map_join(keys, ", ", &name/1)}",
            keys: Enum.map(keys, &name/1)
          )
          | errors
        ]
    end
  end

  defp unknown(errors, _value, _allowed, _path), do: errors

  defp error(path, reason, message, attrs \\ []) do
    Map.merge(
      %{code: :invalid_domain, reason: reason, path: path, message: message},
      Map.new(attrs)
    )
  end

  defp sorted(map), do: Enum.sort_by(map, fn {key, _value} -> name(key) end)

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Enum.find_value(map, :error, fn {candidate, value} ->
          if is_atom(candidate) and Atom.to_string(candidate) == key, do: {:ok, value}
        end)
    end
  end

  defp value(map, key) when is_map(map) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp name(key) when is_atom(key), do: Atom.to_string(key)
  defp name(key) when is_binary(key), do: key
  defp name(key), do: inspect(key)

  defp location([]), do: "the domain"
  defp location(path), do: Enum.map_join(path, ".", &name/1)
end
