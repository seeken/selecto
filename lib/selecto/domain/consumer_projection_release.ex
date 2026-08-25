defmodule Selecto.Domain.ConsumerProjectionRelease do
  @moduledoc """
  Builds immutable, projection-specific nested consumer contracts and compares
  them for compatibility.

  Publication is fail closed when a target runtime/adapter does not declare
  every feature required by the projected relationship contract. Callers may
  provide an explicit `:supported_features` list for a separately certified
  target.
  """

  alias Selecto.Domain
  alias Selecto.Domain.CompositionContract
  alias Selecto.Domain.Contract.Shared.Core
  alias Selecto.Domain.NestedCapabilityMatrix

  @schema "selecto.consumer_projection_release.v1"

  @spec compile(term(), keyword()) :: {:ok, map()} | {:error, map() | [map()]}
  def compile(input, opts \\ []) when is_list(opts) do
    with {:ok, normalized, _diagnostics} <- normalized(input),
         {:ok, composition} <- CompositionContract.compile(normalized),
         :ok <- reject_deferred_extensions(composition, opts),
         {:ok, target} <- target(opts),
         all_features = CompositionContract.required_features(composition),
         {:ok, feature_scope, required_features} <- feature_scope(all_features, opts),
         :ok <- ensure_supported(required_features, target) do
      projection_id = Keyword.get(opts, :projection_id, "default") |> to_string()
      version = Keyword.get(opts, :version, Map.get(normalized, :domain_version))
      consumer = Keyword.get(opts, :consumer, projection_id) |> to_string()
      authored = Map.fetch!(normalized, :domain)

      release = %{
        "schema" => @schema,
        "schema_version" => 1,
        "projection_id" => projection_id,
        "version" => version,
        "consumer" => consumer,
        "target" => target,
        "feature_scope" => feature_scope,
        "dependencies" => %{
          "domain_version" => Map.get(normalized, :domain_version),
          "domain_fingerprint" => Map.get(normalized, :domain_fingerprint),
          "operations" => registry_dependencies(authored, :operations)
        },
        "composition" => composition,
        "experiences" => registry(authored, :experiences),
        "operations" => registry(authored, :operations),
        "required_features" => required_features
      }

      fingerprint = CompositionContract.fingerprint(release)
      {:ok, Map.put(release, "fingerprint", fingerprint)}
    end
  end

  @spec diff(map(), map()) :: map()
  def diff(previous, current) when is_map(previous) and is_map(current) do
    previous_relationships = relationships(previous)
    current_relationships = relationships(current)

    ids =
      (Map.keys(previous_relationships) ++ Map.keys(current_relationships))
      |> Enum.uniq()
      |> Enum.sort()

    changes =
      Enum.flat_map(ids, fn id ->
        relationship_changes(id, previous_relationships[id], current_relationships[id])
      end)

    %{
      classification:
        if(Enum.any?(changes, &(&1.classification == :breaking)),
          do: :breaking,
          else: :compatible
        ),
      changes: changes
    }
  end

  @spec supported_features(String.t(), String.t()) :: [String.t()]
  def supported_features(runtime, adapter) do
    NestedCapabilityMatrix.supported_features(runtime, adapter)
  end

  defp normalized(%{domain: %{}, schema_version: _} = normalized),
    do: {:ok, normalized, nil}

  defp normalized(input) do
    case Domain.validate(input) do
      {:ok, normalized, diagnostics} -> {:ok, normalized, diagnostics}
      {:error, diagnostics} -> {:error, diagnostics.errors}
    end
  end

  defp target(opts) do
    runtime = Keyword.get(opts, :runtime)
    adapter = Keyword.get(opts, :adapter)
    explicit = Keyword.get(opts, :supported_features)

    cond do
      is_list(explicit) ->
        {:ok,
         %{
           "runtime" => optional_string(runtime),
           "adapter" => optional_string(adapter),
           "supported_features" => Enum.map(explicit, &to_string/1) |> Enum.uniq() |> Enum.sort()
         }}

      is_nil(runtime) and is_nil(adapter) ->
        {:ok, %{"runtime" => nil, "adapter" => nil, "supported_features" => :unrestricted}}

      is_nil(runtime) or is_nil(adapter) ->
        {:error,
         %{
           code: :incomplete_consumer_target,
           message: "consumer projection targets must declare both runtime and adapter"
         }}

      true ->
        certification =
          case NestedCapabilityMatrix.profile(runtime, adapter) do
            {:ok, profile} -> profile
            :error -> nil
          end

        {:ok,
         %{
           "runtime" => to_string(runtime),
           "adapter" => to_string(adapter),
           "supported_features" => supported_features(runtime, adapter),
           "certification" => certification
         }}
    end
  end

  defp feature_scope(features, opts) do
    case Keyword.get(opts, :feature_scope, :all) do
      :all ->
        {:ok, "all", features}

      "all" ->
        {:ok, "all", features}

      :read ->
        {:ok, "read", Enum.filter(features, &read_feature?/1)}

      "read" ->
        {:ok, "read", Enum.filter(features, &read_feature?/1)}

      :write ->
        {:ok, "write", Enum.reject(features, &(&1 == "nested_read"))}

      "write" ->
        {:ok, "write", Enum.reject(features, &(&1 == "nested_read"))}

      :execution ->
        {:ok, "execution", Enum.filter(features, &execution_feature?/1)}

      "execution" ->
        {:ok, "execution", Enum.filter(features, &execution_feature?/1)}

      scope ->
        {:error,
         %{
           code: :invalid_consumer_feature_scope,
           message: "consumer projection feature scope is unknown",
           feature_scope: scope
         }}
    end
  end

  defp read_feature?(feature),
    do: feature == "nested_read" or feature in ~w(owned_one owned_many)

  defp execution_feature?(feature) do
    feature in ~w(owned_one owned_many recursive_tenant_policy conflict_policy identity_mapping capability_policy) or
      String.starts_with?(feature, "mutation:") or String.starts_with?(feature, "operation:") or
      String.starts_with?(feature, "validation:")
  end

  defp ensure_supported(_required, %{"supported_features" => :unrestricted}), do: :ok

  defp ensure_supported(required, %{"supported_features" => supported} = target) do
    missing = required -- supported

    if missing == [] do
      :ok
    else
      {:error,
       %{
         code: :unsupported_consumer_projection,
         message: "consumer target does not support the complete nested contract",
         runtime: target["runtime"],
         adapter: target["adapter"],
         missing_features: missing
       }}
    end
  end

  defp reject_deferred_extensions(composition, opts) do
    supported = Keyword.get(opts, :supported_extensions, []) |> MapSet.new(&to_string/1)

    unsupported =
      composition
      |> Map.get("relationships", %{})
      |> Enum.flat_map(fn {id, relationship} ->
        relationship
        |> Map.get("extensions", %{})
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(supported, &1))
        |> Enum.map(&"#{id}.#{&1}")
      end)

    if unsupported == [] or Keyword.get(opts, :preserve_only, false) do
      :ok
    else
      {:error,
       %{
         code: :unsupported_nested_extensions,
         message: "consumer projection contains preserved concepts unsupported by the target",
         concepts: Enum.sort(unsupported)
       }}
    end
  end

  defp relationship_changes(id, nil, current) do
    [%{path: id, kind: :relationship_added, classification: addition_classification(current)}]
  end

  defp relationship_changes(id, _previous, nil) do
    [%{path: id, kind: :relationship_removed, classification: :breaking}]
  end

  defp relationship_changes(id, previous, current) do
    []
    |> compare_value(id, "ownership", previous, current, :breaking)
    |> compare_value(id, "cardinality", previous, current, :breaking)
    |> compare_value(id, "identity", previous, current, :breaking)
    |> compare_value(id, "tenant_scope", previous, current, :breaking)
    |> compare_value(id, "capabilities", previous, current, :breaking)
    |> compare_value(id, "ordering", previous, current, :breaking)
    |> compare_value(id, "validation", previous, current, :breaking)
    |> compare_value(id, "conflict", previous, current, :breaking)
    |> compare_value(id, "idempotency", previous, current, :breaking)
    |> compare_value(id, "assurance", previous, current, :breaking)
    |> compare_modes(id, previous, current)
    |> compare_omission(id, previous, current)
    |> compare_bounds(id, previous, current)
  end

  defp compare_value(changes, id, field, previous, current, classification) do
    if previous[field] == current[field] do
      changes
    else
      changes ++
        [%{path: "#{id}.#{field}", kind: :changed, classification: classification}]
    end
  end

  defp compare_modes(changes, id, previous, current) do
    old_modes = get_in(previous, ["write", "modes"]) || []
    new_modes = get_in(current, ["write", "modes"]) || []

    cond do
      old_modes == new_modes ->
        changes

      old_modes -- new_modes != [] ->
        changes ++ [%{path: "#{id}.write.modes", kind: :narrowed, classification: :breaking}]

      true ->
        changes ++ [%{path: "#{id}.write.modes", kind: :expanded, classification: :compatible}]
    end
  end

  defp compare_omission(changes, id, previous, current) do
    old_value = get_in(previous, ["write", "omission"])
    new_value = get_in(current, ["write", "omission"])

    if old_value == new_value do
      changes
    else
      changes ++ [%{path: "#{id}.write.omission", kind: :changed, classification: :breaking}]
    end
  end

  defp compare_bounds(changes, id, previous, current) do
    changes
    |> compare_upper_bound(id, previous, current, ["read", "max_depth"])
    |> compare_upper_bound(id, previous, current, ["read", "max_rows"])
    |> compare_upper_bound(id, previous, current, ["write", "max_items"])
    |> compare_lower_bound(id, previous, current, ["write", "min_items"])
  end

  defp compare_upper_bound(changes, id, previous, current, path) do
    old_value = get_in(previous, path)
    new_value = get_in(current, path)

    cond do
      old_value == new_value ->
        changes

      is_integer(old_value) and is_integer(new_value) and new_value < old_value ->
        changes ++
          [%{path: Enum.join([id | path], "."), kind: :narrowed, classification: :breaking}]

      true ->
        changes ++
          [%{path: Enum.join([id | path], "."), kind: :changed, classification: :compatible}]
    end
  end

  defp compare_lower_bound(changes, id, previous, current, path) do
    old_value = get_in(previous, path)
    new_value = get_in(current, path)

    cond do
      old_value == new_value ->
        changes

      is_integer(old_value) and is_integer(new_value) and new_value > old_value ->
        changes ++
          [%{path: Enum.join([id | path], "."), kind: :narrowed, classification: :breaking}]

      true ->
        changes ++
          [%{path: Enum.join([id | path], "."), kind: :changed, classification: :compatible}]
    end
  end

  defp addition_classification(relationship) do
    if get_in(relationship, ["write", "operations", "delete"]) == true,
      do: :breaking,
      else: :compatible
  end

  defp relationships(release) do
    nested =
      get_in(release, ["composition", "relationships"]) ||
        get_in(release, [:composition, "relationships"]) ||
        get_in(release, [:composition, :relationships]) || %{}

    flatten_relationships(nested)
  end

  defp flatten_relationships(relationships) when is_map(relationships) do
    Enum.reduce(relationships, %{}, fn {id, relationship}, acc ->
      path_id = relationship["path_id"] || to_string(id)
      children = flatten_relationships(relationship["relationships"] || %{})
      acc |> Map.put(path_id, relationship) |> Map.merge(children)
    end)
  end

  defp flatten_relationships(_relationships), do: %{}

  defp registry(domain, key) do
    value = Core.map_value(domain, key)
    if is_map(value), do: CompositionContract.canonical(value), else: %{}
  end

  defp registry_dependencies(domain, key) do
    domain
    |> registry(key)
    |> Enum.map(fn {id, spec} ->
      %{
        "id" => id,
        "version" => map_value(spec, "version"),
        "fingerprint" => map_value(spec, "fingerprint")
      }
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp map_value(map, key) when is_map(map) do
    Enum.find_value(map, fn {candidate, value} ->
      if to_string(candidate) == key, do: value
    end)
  end

  defp map_value(_map, _key), do: nil

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)
end
