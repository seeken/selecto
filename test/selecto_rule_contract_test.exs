defmodule Selecto.Rule.ContractTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain
  alias Selecto.Rule.Contract

  test "rules are canonical and appear on write, ui, and api projections" do
    domain = domain()
    assert {:ok, normalized, diagnostics} = Domain.normalize(domain)
    assert :rules in diagnostics.canonical_sections
    assert normalized.rules == domain.rules
    assert Domain.project(normalized, :write).rules == domain.rules
    assert Domain.project(normalized, :api).rules == domain.rules
  end

  test "compiles registries, references, exact numbers, features, and a stable fingerprint" do
    assert {:ok, first} = Contract.compile(domain())
    assert {:ok, second} = Contract.compile(string_key_domain())

    assert first.fingerprint == second.fingerprint
    assert String.starts_with?(first.fingerprint, "sha256:")
    assert first.definitions["positive_quantity"].test["bound"].value == "0"
    assert "rule:number.gt" in first.required_features
    assert "rule:text.pattern" in first.required_features
    assert "normalizer:text.trim" in first.required_features
    assert "rule_stage:candidate" in first.required_features
    assert first.bindings["quantity_on_write"].stage == "candidate"
  end

  test "projects deterministic consumer rules with explicit authority markers" do
    assert {:ok, contract} = Contract.compile(domain())
    projection = Contract.project(contract, stages: [:candidate])

    assert projection["schema"] == "selecto.data_rules.v1"
    assert String.starts_with?(projection["fingerprint"], "sha256:")
    assert Map.keys(projection["bindings"]) == ["quantity_on_write", "reference_on_write"]
    assert projection["definitions"]["positive_quantity"]["test"]["bound"]["decimal"] == "0"
    assert projection["evaluation"]["client_results_authoritative"] == false
    assert projection["evaluation"]["server_revalidation_required"] == true

    assert Enum.all?(projection["evaluation"]["bindings"], fn marker ->
             marker["stage"] == "candidate" and marker["local_eligible"] == false and
               marker["server_required"] == true
           end)
  end

  test "rejects unknown operators, options, and unresolved versions" do
    assert {:error, [%{code: :unsupported_rule_operator}]} =
             domain()
             |> put_in([:rules, :definitions, :positive_quantity, :test], %{op: "host.call"})
             |> Contract.compile()

    assert {:error, [%{code: :unknown_rule_option}]} =
             domain()
             |> put_in([:rules, :extra], true)
             |> Contract.compile()

    assert {:error, [%{code: :unresolved_rule_reference}]} =
             domain()
             |> put_in([:rules, :bindings, :quantity_on_write, :rule, :version], 2)
             |> Contract.compile()

    assert {:error, [%{code: :unresolved_rule_subject}]} =
             domain()
             |> put_in([:rules, :bindings, :quantity_on_write, :subject, :path], [:unknown])
             |> Contract.compile()

    assert {:error, [%{code: :unknown_rule_option}]} =
             domain()
             |> put_in([:rules, :normalizers, :reference, :steps, Access.at(0), :locale], "en")
             |> Contract.compile()
  end

  test "rejects unbounded or non-portable regex syntax" do
    assert {:error, %{code: :invalid_text_pattern}} =
             Contract.compile_test(%{
               op: "text.pattern",
               profile: "ascii_v1",
               pattern: "(?=VIN)",
               match: "search"
             })
  end

  defp domain do
    %{
      source: %{
        source_table: "line_items",
        primary_key: :id,
        fields: [:id, :quantity, :reference],
        columns: %{
          id: %{type: :integer},
          quantity: %{type: :integer},
          reference: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{
          positive_quantity: %{version: 1, test: %{op: "number.gt", bound: "0"}},
          reference_shape: %{
            version: 1,
            test: %{
              op: "text.pattern",
              profile: "ascii_v1",
              pattern: "[A-Z0-9]{4,12}",
              match: "full"
            }
          }
        },
        normalizers: %{
          reference: %{
            version: 1,
            steps: [
              %{op: "text.trim", profile: "ascii_whitespace_v1"},
              %{op: "text.uppercase", profile: "ascii_v1"}
            ]
          }
        },
        bindings: %{
          quantity_on_write: %{
            subject: %{scope: :candidate, path: [:quantity]},
            operations: [:insert, :update],
            rule: %{id: :positive_quantity, version: 1}
          },
          reference_on_write: %{
            subject: %{scope: :candidate, path: [:reference]},
            normalizer: %{id: :reference, version: 1},
            rule: %{id: :reference_shape, version: 1}
          }
        }
      }
    }
  end

  defp string_key_domain do
    domain()
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
