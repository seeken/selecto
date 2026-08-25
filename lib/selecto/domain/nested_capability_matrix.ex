defmodule Selecto.Domain.NestedCapabilityMatrix do
  @moduledoc """
  Published implementation and certification boundaries for nested consumers.

  `implemented_features` controls whether a projection may be emitted. The
  separate `live_evidence` and finite limits intentionally prevent an
  implementation claim from being mistaken for proof over arbitrary schemas,
  databases, depths, graph sizes, callbacks, or concurrency schedules.
  """

  @execution_features ~w(
    owned_one owned_many
    mutation:append_only mutation:delta mutation:full_set mutation:replace_one
    mutation:link_delta
    operation:create operation:update operation:delete operation:link operation:unlink
    recursive_tenant_policy conflict_policy identity_mapping capability_policy
    validation:field_rules validation:unique_fields validation:aggregate_rules
  )

  @client_features @execution_features ++
                     ~w(nested_read operation:reorder idempotency_policy offline assurance ordering_policy)

  @profiles %{
    {"selecto_updato", "postgresql"} => %{
      "implementation_status" => "implemented",
      "implemented_features" => @execution_features,
      "maximum_compiler_depth" => 32,
      "live_certified_depth" => 2,
      "live_certified_graph_rows" => 3,
      "live_evidence" => [
        "selecto_db_postgresql:write_graph_integration_test",
        "selecto_updato:nested_composition_test"
      ],
      "proof_boundary" => "finite fixtures plus live PostgreSQL transactions"
    },
    {"selecto_updato", "sqlite"} => %{
      "implementation_status" => "implemented",
      "implemented_features" => @execution_features,
      "maximum_compiler_depth" => 32,
      "live_certified_depth" => 1,
      "live_certified_graph_rows" => 2,
      "live_evidence" => ["selecto_db_sqlite:write_adapter_test"],
      "proof_boundary" => "finite in-process SQLite graph fixtures"
    },
    {"selecto_updato", "duckdb"} => %{
      "implementation_status" => "implemented",
      "implemented_features" => @execution_features,
      "maximum_compiler_depth" => 32,
      "live_certified_depth" => 1,
      "live_certified_graph_rows" => 2,
      "live_evidence" => ["selecto_db_duckdb:write_adapter_test"],
      "proof_boundary" => "finite in-process DuckDB graph fixtures"
    },
    {"selecto_updato", "mssql"} => %{
      "implementation_status" => "implemented",
      "implemented_features" => @execution_features,
      "maximum_compiler_depth" => 32,
      "live_certified_depth" => 1,
      "live_certified_graph_rows" => 2,
      "live_evidence" => ["selecto_db_mssql:write_execution_integration_test"],
      "proof_boundary" => "finite opt-in SQL Server graph fixtures"
    },
    {"selecto_components", "web"} => %{
      "implementation_status" => "implemented",
      "implemented_features" => @client_features,
      "maximum_compiler_depth" => nil,
      "live_certified_depth" => 2,
      "live_certified_graph_rows" => 25,
      "live_evidence" => [
        "selecto_components:nested_experience_test",
        "selecto_components:action_form_modal_test"
      ],
      "proof_boundary" => "finite rendered LiveComponent and normalization fixtures"
    },
    {"selecto_operations", "portable"} => %{
      "implementation_status" => "implemented",
      "implemented_features" => @client_features -- ["nested_read"],
      "maximum_compiler_depth" => nil,
      "live_certified_depth" => 2,
      "live_certified_graph_rows" => 40,
      "live_evidence" => [
        "selecto_operations:nested_contract_test",
        "selecto_operations:gateway_queue_test"
      ],
      "proof_boundary" => "finite manifest, wire-validation, and durable-queue fixtures"
    }
  }

  @spec profile(String.t() | atom(), String.t() | atom()) :: {:ok, map()} | :error
  def profile(runtime, adapter) do
    case Map.fetch(@profiles, {to_string(runtime), to_string(adapter)}) do
      {:ok, profile} ->
        {:ok,
         profile
         |> Map.put("runtime", to_string(runtime))
         |> Map.put("adapter", to_string(adapter))
         |> canonical()}

      :error ->
        :error
    end
  end

  @spec supported_features(String.t() | atom(), String.t() | atom()) :: [String.t()]
  def supported_features(runtime, adapter) do
    case profile(runtime, adapter) do
      {:ok, profile} -> profile["implemented_features"]
      :error -> []
    end
  end

  @spec profiles() :: [map()]
  def profiles do
    @profiles
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn {runtime, adapter} ->
      {:ok, profile} = profile(runtime, adapter)
      profile
    end)
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Map.new(fn {key, value} -> {to_string(key), canonical(value)} end)
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value) when is_boolean(value) or is_nil(value), do: value
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value
end
