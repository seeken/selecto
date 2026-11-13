defmodule SelectoUpdato.DomainInput do
  @moduledoc """
  Helpers for accepting authored and normalized Selecto domain inputs.

  Updato execution works against one canonical domain map. This module accepts
  normalized `Selecto.Domain.normalize/1` / `Selecto.Domain.compose/2` shapes
  and normalizes source-colocated write authoring before graph validation.
  """

  @spec canonical_domain(map()) :: map()
  def canonical_domain(
        %{
          schema_version: _schema_version,
          domain: %{} = domain,
          query: %{},
          projection: %{}
        } = _normalized
      ) do
    domain
  end

  def canonical_domain(%{} = domain), do: domain

  @doc false
  @spec normalize_write_authoring(map()) ::
          {:ok, map()} | {:error, SelectoUpdato.Error.t()}
  def normalize_write_authoring(%{} = input) do
    domain = canonical_domain(input)

    if colocated_write_authoring?(domain) do
      {:ok, normalized, diagnostics} = Selecto.Domain.normalize(domain)
      normalized_authoring(normalized, diagnostics)
    else
      {:ok, domain}
    end
  end

  defp colocated_write_authoring?(domain) when is_map(domain) do
    source = value(domain, :source, %{})
    writes = value(domain, :writes, %{})

    registry_has_write?(nested_value(source, :columns, %{})) or
      registry_has_write?(nested_value(source, :associations, %{})) or
      nested_domain_has_colocated_writes?(nested_value(writes, :relationships, %{}))
  end

  defp registry_has_write?(registry) when is_map(registry) do
    Enum.any?(registry, fn {_id, spec} -> is_map(spec) and has_key?(spec, :write) end)
  end

  defp registry_has_write?(_registry), do: false

  defp nested_domain_has_colocated_writes?(relationships) when is_map(relationships) do
    Enum.any?(relationships, fn {_id, spec} ->
      is_map(spec) and
        case value(spec, :domain) do
          domain when is_map(domain) -> colocated_write_authoring?(domain)
          _domain -> false
        end
    end)
  end

  defp nested_domain_has_colocated_writes?(_relationships), do: false

  defp invalid_authoring(diagnostics) do
    errors = Map.get(diagnostics, :errors, [])

    {:error,
     SelectoUpdato.Error.new(:invalid_operation, "Invalid domain authoring",
       details: %{errors: errors}
     )}
  end

  defp normalized_authoring(normalized, %{errors: []}), do: {:ok, normalized}
  defp normalized_authoring(_normalized, diagnostics), do: invalid_authoring(diagnostics)

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, to_string(key))

  defp nested_value(map, key, default) when is_map(map), do: value(map, key, default)
  defp nested_value(_other, _key, default), do: default

  defp value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
