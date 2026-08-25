defmodule Selecto.Domain.CompositionContract do
  @moduledoc """
  Compiles authored nested relationship metadata into one deterministic,
  portable composition contract.

  The compiler preserves compatibility with the delivered `:owned`,
  `:shared_reference`, and `:join_only` vocabulary while publishing the
  canonical ownership names used by new consumers. Database metadata never
  grants ownership or write authority.
  """

  alias Selecto.Domain
  alias Selecto.Domain.Contract.Shared.Core

  @schema "selecto.composition_contract.v1"
  @schema_version 1

  @ownership_aliases %{
    "owned" => "composition",
    "composition" => "composition",
    "shared_reference" => "shared_association",
    "shared_association" => "shared_association",
    "join_only" => "join_association",
    "join_association" => "join_association",
    "derived" => "derived",
    "deferred" => "deferred"
  }

  @mode_order ~w(append_only delta full_set replace_one link_delta)
  @operation_order ~w(create update delete reorder link unlink)

  @known_relationship_keys ~w(
    allowed_ops assurance capabilities cardinality child_identity child_key
    client_identity conflict delete_missing domain enabled foreign_key
    idempotency identity_fields max_items min_items offline ordering output
    ownership parent_key path_id physical_provenance read required strategy
    target tenant_scope validation writable write
  )

  @type error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec compile(term()) :: {:ok, map()} | {:error, [error()]}
  def compile(input) do
    with {:ok, normalized, _diagnostics} <- normalized(input) do
      relationships =
        normalized
        |> Map.get(:writes, %{})
        |> Core.map_value(:relationships)
        |> case do
          value when is_map(value) -> value
          _ -> %{}
        end

      compiled_relationships =
        relationships
        |> Enum.sort_by(fn {id, _spec} -> to_string(id) end)
        |> Map.new(fn {id, spec} -> {to_string(id), relationship(id, spec, nil)} end)

      contract = %{
        "schema" => @schema,
        "schema_version" => @schema_version,
        "domain_version" => Map.get(normalized, :domain_version),
        "domain_fingerprint" => Map.get(normalized, :domain_fingerprint),
        "relationships" => compiled_relationships
      }

      case duplicate_path_ids(compiled_relationships) do
        [] ->
          {:ok, contract}

        duplicates ->
          {:error,
           [
             %{
               code: :duplicate_composition_path_id,
               message: "composition relationship path ids must be globally unique",
               path_ids: duplicates
             }
           ]}
      end
    end
  end

  @spec required_features(map()) :: [String.t()]
  def required_features(%{"relationships" => relationships}) when is_map(relationships) do
    relationships
    |> Enum.flat_map(fn {_id, relationship} -> relationship_features(relationship) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def required_features(_contract), do: []

  @spec fingerprint(term()) :: String.t()
  def fingerprint(value) do
    digest =
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "sha256:#{digest}"
  end

  @spec canonical(term()) :: term()
  def canonical(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Map.new(fn {key, value} -> {to_string(key), canonical(value)} end)
  end

  def canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)

  def canonical(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&canonical/1)

  def canonical(value) when is_boolean(value) or is_nil(value), do: value
  def canonical(value) when is_atom(value), do: Atom.to_string(value)
  def canonical(value), do: value

  defp normalized(%{domain: %{}, schema_version: _} = normalized) do
    case Selecto.Domain.Contract.validate(normalized) do
      :ok -> {:ok, normalized, nil}
      {:error, errors} -> {:error, errors}
    end
  end

  defp normalized(input) do
    case Domain.validate(input) do
      {:ok, normalized, diagnostics} -> {:ok, normalized, diagnostics}
      {:error, diagnostics} -> {:error, diagnostics.errors}
    end
  end

  defp relationship(id, spec, parent_path) when is_map(spec) do
    write = Core.map_value(spec, :write)
    modes = mutation_modes(spec, write)
    ownership = canonical_ownership(Core.map_value(spec, :ownership))
    path_id = relationship_path(id, spec, parent_path)

    %{
      "id" => to_string(id),
      "path_id" => path_id,
      "target" => target(spec),
      "ownership" => ownership,
      "cardinality" => enum_string(Core.map_value(spec, :cardinality)),
      "physical_provenance" => physical_provenance(spec),
      "identity" => identity(spec),
      "read" => read_policy(spec),
      "write" => write_policy(spec, write, modes),
      "tenant_scope" => tenant_policy(spec),
      "capabilities" => canonical(Core.map_value(spec, :capabilities) || %{}),
      "ordering" => canonical(Core.map_value(spec, :ordering) || %{}),
      "conflict" => canonical(Core.map_value(spec, :conflict) || %{}),
      "idempotency" => canonical(Core.map_value(spec, :idempotency) || %{}),
      "offline" => canonical(Core.map_value(spec, :offline) || %{}),
      "validation" => canonical(Core.map_value(spec, :validation) || %{}),
      "assurance" => canonical(Core.map_value(spec, :assurance) || %{}),
      "output" => canonical(Core.map_value(spec, :output) || %{}),
      "extensions" => relationship_extensions(spec),
      "relationships" => child_relationships(spec, path_id)
    }
  end

  defp relationship(id, spec, parent_path) do
    %{
      "id" => to_string(id),
      "path_id" => join_path(parent_path, to_string(id)),
      "target" => nil,
      "ownership" => nil,
      "cardinality" => nil,
      "physical_provenance" => %{},
      "identity" => %{"fields" => [], "client_field" => nil},
      "read" => %{"allowed" => false},
      "write" => %{"modes" => [], "operations" => %{}, "omission" => nil},
      "tenant_scope" => %{},
      "capabilities" => %{},
      "ordering" => %{},
      "conflict" => %{},
      "idempotency" => %{},
      "offline" => %{},
      "validation" => %{},
      "assurance" => %{},
      "output" => %{},
      "extensions" => %{"invalid_authored_spec" => canonical(spec)},
      "relationships" => %{}
    }
  end

  defp child_relationships(spec, parent_path) do
    child_domain = Core.map_value(spec, :domain)
    writes = if is_map(child_domain), do: Core.map_value(child_domain, :writes)
    relationships = if is_map(writes), do: Core.map_value(writes, :relationships)

    if is_map(relationships) do
      relationships
      |> Enum.sort_by(fn {id, _child_spec} -> to_string(id) end)
      |> Map.new(fn {id, child_spec} ->
        {to_string(id), relationship(id, child_spec, parent_path)}
      end)
    else
      %{}
    end
  end

  defp relationship_path(id, spec, parent_path) do
    case string_value(Core.map_value(spec, :path_id)) do
      nil -> join_path(parent_path, to_string(id))
      explicit -> explicit
    end
  end

  defp join_path(nil, id), do: id
  defp join_path(parent, id), do: "#{parent}.#{id}"

  defp target(spec) do
    explicit = Core.map_value(spec, :target)
    child_domain = Core.map_value(spec, :domain)

    cond do
      not is_nil(explicit) -> to_string(explicit)
      is_map(child_domain) -> child_domain_target(child_domain)
      true -> nil
    end
  end

  defp child_domain_target(domain) do
    source = Core.map_value(domain, :source) || %{}

    Core.map_value(domain, :name) || Core.map_value(source, :source_table) ||
      Core.map_value(source, :table)
      |> case do
        nil -> nil
        value -> to_string(value)
      end
  end

  defp physical_provenance(spec) do
    authored = Core.map_value(spec, :physical_provenance)

    if is_map(authored) do
      canonical(authored)
    else
      %{
        "parent_key" => scalar(Core.map_value(spec, :parent_key)),
        "child_key" =>
          scalar(Core.map_value(spec, :child_key) || Core.map_value(spec, :foreign_key))
      }
    end
  end

  defp identity(spec) do
    %{
      "fields" =>
        spec
        |> Core.map_value(:identity_fields)
        |> List.wrap()
        |> Enum.map(&to_string/1),
      "child_identity" => scalar(Core.map_value(spec, :child_identity)),
      "client_field" => scalar(Core.map_value(spec, :client_identity))
    }
  end

  defp read_policy(spec) do
    read = Core.map_value(spec, :read)

    if is_map(read) do
      canonical(read)
    else
      %{"allowed" => false}
    end
  end

  defp write_policy(spec, write, modes) do
    operations =
      @operation_order
      |> Map.new(fn operation -> {operation, operation_enabled?(spec, write, operation)} end)

    omission =
      cond do
        is_map(write) and not is_nil(Core.map_value(write, :omission)) ->
          enum_string(Core.map_value(write, :omission))

        Core.map_value(spec, :delete_missing) == true ->
          "delete_missing"

        Core.map_value(spec, :delete_missing) == false ->
          "retain_missing"

        true ->
          nil
      end

    authored = if is_map(write), do: canonical(write), else: %{}

    authored
    |> Map.put("modes", modes)
    |> Map.put("operations", operations)
    |> Map.put("omission", omission)
    |> put_default("min_items", Core.map_value(spec, :min_items))
    |> put_default("max_items", Core.map_value(spec, :max_items))
  end

  defp tenant_policy(spec) do
    case Core.map_value(spec, :tenant_scope) do
      policy when is_map(policy) -> canonical(policy)
      nil -> %{}
      policy -> %{"mode" => enum_string(policy)}
    end
  end

  defp relationship_extensions(spec) do
    spec
    |> Enum.reject(fn {key, _value} -> to_string(key) in @known_relationship_keys end)
    |> Map.new(fn {key, value} -> {to_string(key), canonical(value)} end)
  end

  defp mutation_modes(_spec, write) when is_map(write) do
    write
    |> Core.map_value(:modes)
    |> List.wrap()
    |> Enum.map(&enum_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&Enum.find_index(@mode_order, fn mode -> mode == &1 end))
  end

  defp mutation_modes(spec, _write) do
    cond do
      Core.map_value(spec, :strategy) in [:sync, "sync"] -> ["full_set"]
      legacy_insert_only?(spec) -> ["append_only"]
      true -> []
    end
  end

  defp operation_enabled?(_spec, write, operation) when is_map(write) do
    Core.map_value(write, operation) == true
  end

  defp operation_enabled?(spec, _write, operation) do
    operations =
      spec
      |> Core.map_value(:allowed_ops)
      |> List.wrap()
      |> Enum.map(&enum_string/1)

    legacy =
      case operation do
        "create" -> ["insert", "nested_insert"]
        "update" -> ["update", "nested_update"]
        "delete" -> ["delete"]
        _ -> []
      end

    Enum.any?(legacy, &(&1 in operations))
  end

  defp legacy_insert_only?(spec) do
    operations =
      spec
      |> Core.map_value(:allowed_ops)
      |> List.wrap()
      |> Enum.map(&enum_string/1)
      |> Enum.uniq()

    operations != [] and Enum.all?(operations, &(&1 in ["insert", "nested_insert"]))
  end

  defp relationship_features(relationship) do
    ownership = relationship["ownership"]
    cardinality = relationship["cardinality"]
    read = relationship["read"] || %{}
    write = relationship["write"] || %{}
    modes = write["modes"] || []
    operations = write["operations"] || %{}

    []
    |> maybe_feature(read["allowed"] == true, "nested_read")
    |> maybe_feature(ownership == "composition" and cardinality == "one", "owned_one")
    |> maybe_feature(ownership == "composition" and cardinality == "many", "owned_many")
    |> Kernel.++(Enum.map(modes, &"mutation:#{&1}"))
    |> Kernel.++(
      operations
      |> Enum.filter(fn {_operation, enabled} -> enabled == true end)
      |> Enum.map(fn {operation, _enabled} -> "operation:#{operation}" end)
    )
    |> maybe_feature(relationship["tenant_scope"] != %{}, "recursive_tenant_policy")
    |> maybe_feature(relationship["capabilities"] != %{}, "capability_policy")
    |> maybe_feature(relationship["conflict"] != %{}, "conflict_policy")
    |> maybe_feature(relationship["idempotency"] != %{}, "idempotency_policy")
    |> maybe_feature(relationship["ordering"] != %{}, "ordering_policy")
    |> Kernel.++(
      relationship
      |> Map.get("validation", %{})
      |> Map.keys()
      |> Enum.map(&"validation:#{&1}")
    )
    |> maybe_feature(get_in(relationship, ["offline", "eligible"]) == true, "offline")
    |> maybe_feature(relationship["assurance"] != %{}, "assurance")
    |> maybe_feature(
      get_in(relationship, ["output", "identity_mapping"]) == true,
      "identity_mapping"
    )
    |> Kernel.++(
      relationship
      |> Map.get("relationships", %{})
      |> Enum.flat_map(fn {_id, child} -> relationship_features(child) end)
    )
  end

  defp duplicate_path_ids(relationships) do
    relationships
    |> all_path_ids()
    |> Enum.frequencies()
    |> Enum.filter(fn {_path, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp all_path_ids(relationships) do
    Enum.flat_map(relationships, fn {_id, relationship} ->
      [relationship["path_id"] | all_path_ids(relationship["relationships"] || %{})]
    end)
  end

  defp maybe_feature(features, true, feature), do: features ++ [feature]
  defp maybe_feature(features, false, _feature), do: features

  defp canonical_ownership(nil), do: nil

  defp canonical_ownership(value) do
    Map.get(@ownership_aliases, enum_string(value), enum_string(value))
  end

  defp enum_string(nil), do: nil
  defp enum_string(value) when is_atom(value), do: Atom.to_string(value)
  defp enum_string(value) when is_binary(value), do: value
  defp enum_string(value), do: to_string(value)

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp string_value(_value), do: nil
  defp scalar(nil), do: nil
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(value), do: value

  defp put_default(map, _key, nil), do: map
  defp put_default(map, key, value), do: Map.put_new(map, key, value)
end
