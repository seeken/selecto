defmodule Selecto.Domain.Contract.DomainDependencies do
  @moduledoc false

  alias Selecto.Domain.Contract.Shared.Core

  @keys ~w(provider contract accepts expected_fingerprint uses satisfies)
  @uses_keys ~w(fields filters query_members)

  def validate(errors, dependencies) when is_list(dependencies) do
    dependencies
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {dependency, index}, acc ->
      validate_dependency(acc, dependency, [:domain_dependencies, index])
    end)
  end

  def validate(errors, dependencies) do
    [
      Core.error(
        :invalid_section_shape,
        [:domain_dependencies],
        "domain section :domain_dependencies must be a list",
        expected: :list,
        actual: Core.value_type(dependencies)
      )
      | errors
    ]
  end

  defp validate_dependency(errors, dependency, path) when is_map(dependency) do
    errors
    |> reject_unknown(dependency, @keys, path)
    |> require_identifier(dependency, :provider, path)
    |> require_identifier(dependency, :contract, path)
    |> optional_string(dependency, :accepts, path)
    |> optional_string(dependency, :expected_fingerprint, path)
    |> validate_uses(dependency, path)
    |> validate_identifier_list(dependency, :satisfies, path)
  end

  defp validate_dependency(errors, dependency, path) do
    [
      Core.error(
        :invalid_domain_dependency,
        path,
        "domain dependency must be a map",
        expected: :map,
        actual: Core.value_type(dependency)
      )
      | errors
    ]
  end

  defp reject_unknown(errors, map, allowed, path) do
    Enum.reduce(Map.keys(map), errors, fn key, acc ->
      if (is_atom(key) or is_binary(key)) and to_string(key) in allowed do
        acc
      else
        [
          Core.error(
            :unknown_domain_dependency_key,
            path ++ [key],
            "unknown domain dependency key #{inspect(key)}"
          )
          | acc
        ]
      end
    end)
  end

  defp require_identifier(errors, dependency, key, path) do
    value = Core.map_value(dependency, key)

    if Core.non_empty_atom_or_string?(value) do
      errors
    else
      [
        Core.error(
          :invalid_domain_dependency_identifier,
          path ++ [key],
          "domain dependency #{key} must be a non-empty atom or string",
          attribute: key,
          actual: Core.value_type(value)
        )
        | errors
      ]
    end
  end

  defp optional_string(errors, dependency, key, path) do
    value = Core.map_value(dependency, key)

    if is_nil(value) or Core.non_empty_string?(value) do
      errors
    else
      [
        Core.error(
          :invalid_domain_dependency_string,
          path ++ [key],
          "domain dependency #{key} must be a non-empty string",
          attribute: key,
          actual: Core.value_type(value)
        )
        | errors
      ]
    end
  end

  defp validate_uses(errors, dependency, path) do
    case Core.map_value(dependency, :uses) do
      nil ->
        errors

      uses when is_map(uses) ->
        errors = reject_unknown(errors, uses, @uses_keys, path ++ [:uses])

        Enum.reduce([:fields, :filters, :query_members], errors, fn key, acc ->
          validate_identifier_list(acc, uses, key, path ++ [:uses])
        end)

      uses ->
        [
          Core.error(
            :invalid_domain_dependency_uses,
            path ++ [:uses],
            "domain dependency uses must be a map",
            expected: :map,
            actual: Core.value_type(uses)
          )
          | errors
        ]
    end
  end

  defp validate_identifier_list(errors, map, key, path) do
    case Core.map_value(map, key) do
      nil ->
        errors

      values when is_list(values) ->
        Enum.reduce(Enum.with_index(values), errors, fn {value, index}, acc ->
          if Core.non_empty_atom_or_string?(value) do
            acc
          else
            [
              Core.error(
                :invalid_domain_dependency_reference,
                path ++ [key, index],
                "domain dependency #{key} entries must be non-empty atoms or strings",
                attribute: key,
                actual: Core.value_type(value)
              )
              | acc
            ]
          end
        end)

      values ->
        [
          Core.error(
            :invalid_domain_dependency_reference_list,
            path ++ [key],
            "domain dependency #{key} must be a list",
            attribute: key,
            expected: :list,
            actual: Core.value_type(values)
          )
          | errors
        ]
    end
  end
end
