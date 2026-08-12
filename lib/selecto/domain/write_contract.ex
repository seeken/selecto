defmodule Selecto.Domain.WriteContract do
  @moduledoc """
  Compiles the explicit, fail-closed write surface of a Selecto domain.

  Read-domain structure and database introspection never grant write access.
  A caller receives a contract only when the domain declares a non-empty
  `writes.operations` registry with explicitly enabled operations.
  """

  alias Selecto.Domain
  alias Selecto.Domain.Contract.Shared.Core
  alias Selecto.Write.Error

  @operation_ids %{
    "insert" => :insert,
    "update" => :update,
    "delete" => :delete,
    "upsert" => :upsert
  }

  @type t :: %__MODULE__{
          source: map(),
          operations: %{optional(atom()) => map()},
          fields: %{optional(String.t()) => map()},
          scope: map(),
          relationships: map(),
          constraints: term(),
          transitions: map(),
          fingerprint: String.t() | nil
        }

  @enforce_keys [:source, :operations, :fields]
  defstruct source: %{},
            operations: %{},
            fields: %{},
            scope: %{},
            relationships: %{},
            constraints: %{},
            transitions: %{},
            fingerprint: nil

  @spec compile(term()) :: {:ok, t()} | {:error, Error.t()}
  def compile(input) do
    with {:ok, normalized} <- normalized_domain(input),
         {:ok, writes} <- explicit_writes(normalized),
         {:ok, operations} <- compile_operations(writes),
         {:ok, fields} <- compile_fields(writes, normalized),
         {:ok, scope} <- compile_scope(writes, normalized) do
      {:ok,
       %__MODULE__{
         source: Map.get(normalized, :source, %{}),
         operations: operations,
         fields: fields,
         scope: scope,
         relationships: map_section(writes, :relationships),
         constraints: map_section(writes, :constraints),
         transitions: map_section(writes, :transitions),
         fingerprint: Map.get(normalized, :domain_fingerprint)
       }}
    end
  end

  @spec operation_enabled?(t(), atom()) :: boolean()
  def operation_enabled?(%__MODULE__{operations: operations}, operation)
      when is_atom(operation) do
    match?(%{enabled: true}, Map.get(operations, operation))
  end

  @spec field_spec(t(), atom() | String.t()) :: map() | nil
  def field_spec(%__MODULE__{fields: fields}, field), do: Map.get(fields, Core.field_id(field))

  @spec writable?(t(), atom(), atom() | String.t()) :: boolean()
  def writable?(%__MODULE__{} = contract, operation, field)
      when operation in [:insert, :upsert] do
    match?(%{insertable: true}, field_spec(contract, field))
  end

  def writable?(%__MODULE__{} = contract, :update, field) do
    match?(%{updatable: true}, field_spec(contract, field))
  end

  def writable?(%__MODULE__{}, _operation, _field), do: false

  @doc """
  Returns the authored foreign-key policies keyed by normalized local field.

  A policy is portable data, not SQL. `source` identifies where the local
  value may come from (`:input` or `{:context, key}`), while `references`
  names the relation and field an adapter must guard or enforce.
  """
  @spec foreign_keys(t()) :: %{optional(String.t()) => map()}
  def foreign_keys(%__MODULE__{constraints: constraints}) when is_map(constraints) do
    constraints
    |> map_section(:foreign_keys)
    |> case do
      foreign_keys when is_map(foreign_keys) ->
        Map.new(foreign_keys, fn {field, spec} ->
          {Core.field_id(field), normalize_foreign_key_spec(spec)}
        end)

      _ ->
        %{}
    end
  end

  def foreign_keys(%__MODULE__{}), do: %{}

  defp normalized_domain(%{domain: %{}, schema_version: _} = normalized), do: {:ok, normalized}
  defp normalized_domain(%Selecto{domain: domain}), do: normalized_domain(domain)

  defp normalized_domain(domain) when is_map(domain) do
    case Domain.validate(domain) do
      {:ok, normalized, _diagnostics} ->
        {:ok, normalized}

      {:error, diagnostics} ->
        {:error,
         Error.new(:invalid_domain, "domain does not satisfy the Selecto contract",
           details: %{errors: diagnostics.errors}
         )}
    end
  end

  defp normalized_domain(other) do
    {:error,
     Error.new(:invalid_domain, "expected a Selecto domain or configured Selecto value",
       details: %{input: other}
     )}
  end

  defp explicit_writes(normalized) do
    writes = Map.get(normalized, :writes, %{})
    operations = map_section(writes, :operations)

    cond do
      not is_map(writes) ->
        {:error, Error.new(:write_not_declared, "domain does not declare a write contract")}

      not is_map(operations) or map_size(operations) == 0 ->
        {:error,
         Error.new(:write_not_declared, "domain does not declare any enabled write operations",
           details: %{required: [:writes, :operations]}
         )}

      true ->
        {:ok, writes}
    end
  end

  defp compile_operations(writes) do
    operations = map_section(writes, :operations)

    with :ok <-
           ensure_unique_registry_ids(
             operations,
             :duplicate_write_operation_id,
             [:writes, :operations]
           ) do
      Enum.reduce_while(operations, {:ok, %{}}, fn {operation_id, spec}, {:ok, acc} ->
        with {:ok, operation} <- normalize_operation(operation_id),
             true <- is_map(spec) do
          normalized = normalize_map_keys(spec)

          if Map.get(normalized, :enabled) == true do
            {:cont, {:ok, Map.put(acc, operation, normalized)}}
          else
            {:cont, {:ok, acc}}
          end
        else
          false ->
            {:halt,
             {:error,
              Error.new(:invalid_domain, "write operation configuration must be a map",
                details: %{operation: operation_id, spec: spec}
              )}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    end
    |> case do
      {:ok, operations} when map_size(operations) > 0 ->
        {:ok, operations}

      {:ok, _operations} ->
        {:error,
         Error.new(:write_not_declared, "domain has no explicitly enabled write operations")}

      error ->
        error
    end
  end

  defp compile_fields(writes, normalized) do
    fields = map_section(writes, :fields)
    source_fields = Core.relation_fields(Map.get(normalized, :source, %{})) |> MapSet.new()

    cond do
      not is_map(fields) ->
        {:error, Error.new(:invalid_domain, "writes.fields must be a map")}

      map_size(fields) == 0 ->
        {:error, Error.new(:write_not_declared, "domain must explicitly declare writable fields")}

      true ->
        with :ok <-
               ensure_unique_registry_ids(
                 fields,
                 :duplicate_write_field_id,
                 [:writes, :fields]
               ) do
          Enum.reduce_while(fields, {:ok, %{}}, fn {field, spec}, {:ok, acc} ->
            field_id = Core.field_id(field)

            cond do
              not MapSet.member?(source_fields, field_id) ->
                {:halt,
                 {:error,
                  Error.new(:invalid_domain, "write field is not defined on the source relation",
                    details: %{field: field}
                  )}}

              not is_map(spec) ->
                {:halt,
                 {:error,
                  Error.new(:invalid_domain, "write field specification must be a map",
                    details: %{field: field, spec: spec}
                  )}}

              true ->
                {:cont, {:ok, Map.put(acc, field_id, normalize_map_keys(spec))}}
            end
          end)
        end
    end
  end

  defp ensure_unique_registry_ids(registry, code, path) when is_map(registry) do
    duplicates =
      registry
      |> Enum.filter(fn {id, _spec} -> Core.field_ref?(id) end)
      |> Enum.group_by(fn {id, _spec} -> Core.field_id(id) end, fn {id, _spec} -> id end)
      |> Enum.filter(fn {_normalized_id, authored_ids} -> length(authored_ids) > 1 end)
      |> Enum.sort_by(fn {normalized_id, _authored_ids} -> normalized_id end)

    case duplicates do
      [] ->
        :ok

      [{normalized_id, authored_ids} | _rest] ->
        {:error,
         Error.new(:invalid_domain, "write registry contains ambiguous normalized identifiers",
           details: %{
             code: code,
             path: path,
             normalized_id: normalized_id,
             authored_ids: Enum.sort_by(authored_ids, &inspect/1)
           }
         )}
    end
  end

  defp compile_scope(writes, normalized) do
    scope = map_section(writes, :scopes, map_section(writes, :scope))

    case map_section(scope, :tenant, nil) do
      nil ->
        {:ok, %{}}

      tenant when is_map(tenant) ->
        tenant = normalize_map_keys(tenant)
        field = Map.get(tenant, :field)
        source_fields = Core.relation_fields(Map.get(normalized, :source, %{}))

        cond do
          Map.get(tenant, :required) != true ->
            {:error, Error.new(:invalid_domain, "tenant scope must explicitly be required")}

          not Core.field_ref?(field) or not Core.field_in_list?(source_fields, field) ->
            {:error,
             Error.new(:invalid_domain, "tenant scope field must exist on the source relation",
               details: %{field: field}
             )}

          true ->
            {:ok, %{tenant: tenant}}
        end

      other ->
        {:error,
         Error.new(:invalid_domain, "tenant scope must be a map", details: %{tenant: other})}
    end
  end

  defp normalize_operation(operation) do
    case Map.fetch(@operation_ids, Core.field_id(operation)) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         Error.new(:invalid_domain, "unknown write operation", details: %{operation: operation})}
    end
  end

  defp map_section(map, key, default \\ %{})

  defp map_section(map, key, default) when is_map(map) do
    case Core.fetch_map_value(map, key) do
      :__missing__ -> default
      value -> value
    end
  end

  defp map_section(_map, _key, default), do: default

  defp normalize_map_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_key =
        case key do
          key when is_atom(key) -> key
          "enabled" -> :enabled
          "insertable" -> :insertable
          "updatable" -> :updatable
          "required" -> :required
          "field" -> :field
          key -> key
        end

      Map.put(acc, normalized_key, value)
    end)
  end

  defp normalize_foreign_key_spec(spec) when is_map(spec) do
    spec
    |> normalize_map_keys()
    |> Map.update(:references, nil, &normalize_map_keys_if_map/1)
  end

  defp normalize_foreign_key_spec(spec), do: spec

  defp normalize_map_keys_if_map(value) when is_map(value), do: normalize_map_keys(value)
  defp normalize_map_keys_if_map(value), do: value
end
