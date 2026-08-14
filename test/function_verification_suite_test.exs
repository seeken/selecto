defmodule Selecto.FunctionVerification.SuiteTest do
  use ExUnit.Case, async: true

  alias Selecto.FunctionVerification.Suite

  defmodule ResolvedAdapter do
    def name, do: :suite_resolved
    def connect(connection), do: {:ok, connection}
    def supports?(:function_verification), do: true
    def supports?(_feature), do: false

    def verify_function(_connection, request, _opts) do
      {:ok,
       %{
         status: :database_resolved,
         resolved_identity: "public.#{request.sql_name}(resolved)",
         server: %{version: "test"},
         evidence: %{strategy: :test},
         diagnostics: []
       }}
    end
  end

  defmodule MissingAdapter do
    def name, do: :suite_missing
    def connect(connection), do: {:ok, connection}
    def supports?(:function_verification), do: true
    def supports?(_feature), do: false

    def verify_function(_connection, request, _opts) do
      {:ok,
       %{
         status: :missing_function,
         evidence: %{requested: request.sql_name},
         diagnostics: [%{code: :function_not_found}]
       }}
    end
  end

  test "enumerates every function and overload in deterministic order" do
    selecto = selecto(ResolvedAdapter)

    first = Suite.verify(selecto)
    second = Suite.verify(selecto)

    assert first == second
    assert Jason.encode!(first) == Jason.encode!(second)
    refute Map.has_key?(first, :generated_at)
    assert first.strict_passed?

    assert Enum.map(first.results, &{&1.function_id, &1.signature_index}) == [
             {"alpha", 0},
             {"alpha", 1},
             {"zeta", 0}
           ]

    assert first.summary == %{
             function_count: 2,
             signature_count: 3,
             status_counts: %{database_resolved: 3}
           }

    assert Enum.all?(first.results, &(&1.status == :database_resolved))
    assert Enum.all?(first.results, &is_binary(&1.signature_fingerprint))
    assert first.proof_boundary.runtime_argument_values_transmitted == false
    assert first.proof_boundary.function_execution_requested == false
  end

  test "collects finite failures without converting them into success" do
    artifact = selecto(MissingAdapter) |> Suite.verify()

    refute artifact.strict_passed?
    assert artifact.summary.status_counts == %{missing_function: 3}

    assert Enum.all?(artifact.results, fn result ->
             result.status == :missing_function and
               result.diagnostics == [%{code: :function_not_found}]
           end)
  end

  test "represents malformed registry entries as static-invalid evidence" do
    selecto = selecto(ResolvedAdapter)
    malformed = %{selecto | config: Map.put(selecto.config, :functions, %{123 => :invalid})}

    artifact = Suite.verify(malformed)

    refute artifact.strict_passed?
    assert artifact.summary.status_counts == %{static_invalid: 1}

    assert [result] = artifact.results
    assert result.function_id == "123"
    assert result.status == :static_invalid
    assert result.diagnostics == [%{code: :invalid_function_spec}]
  end

  defp selecto(adapter) do
    Selecto.configure(domain(), self(), adapter: adapter, validate: false)
  end

  defp domain do
    %{
      name: "Function suite",
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :name],
        redact_fields: [],
        columns: %{id: %{type: :integer}, name: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      functions: %{
        "zeta" => %{
          kind: :predicate,
          sql_name: "public.zeta",
          args: [%{name: :value, type: :integer, source: :value}],
          returns: :boolean,
          allowed_in: [:filter]
        },
        "alpha" => %{
          kind: :scalar,
          sql_name: "public.alpha",
          allowed_in: [:select],
          overloads: [
            %{
              args: [%{name: :value, type: :string, source: :value}],
              returns: :string
            },
            %{
              args: [%{name: :value, type: :integer, source: :value}],
              returns: :integer
            }
          ]
        }
      }
    }
  end
end
