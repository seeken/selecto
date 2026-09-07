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
    assert first.bindings["quantity_on_write"].subject_type == "integer"
    assert first.bindings["reference_on_write"].subject_type == "string"
  end

  test "projects deterministic consumer rules with explicit authority markers" do
    assert {:ok, contract} = Contract.compile(domain())
    projection = Contract.project(contract, stages: [:candidate])

    assert projection["schema"] == "selecto.data_rules.v1"
    assert String.starts_with?(projection["fingerprint"], "sha256:")
    assert Map.keys(projection["bindings"]) == ["quantity_on_write", "reference_on_write"]
    assert projection["bindings"]["quantity_on_write"]["normalizer"] == nil
    assert projection["bindings"]["quantity_on_write"]["condition"] == nil
    assert projection["definitions"]["positive_quantity"]["test"]["bound"]["decimal"] == "0"
    assert projection["evaluation"]["client_results_authoritative"] == false
    assert projection["evaluation"]["server_revalidation_required"] == true

    assert Enum.all?(projection["evaluation"]["bindings"], fn marker ->
             marker["stage"] == "candidate" and marker["local_eligible"] == false and
               marker["server_required"] == true
           end)
  end

  test "includes the compiled canonical rule projection in domain inspection" do
    assert {:ok, inspection, _diagnostics} = Domain.describe(domain())

    assert inspection.counts.rules == %{definitions: 2, normalizers: 1, bindings: 2}
    assert inspection.registries.rule_definitions == [:positive_quantity, :reference_shape]
    assert inspection.registries.rule_normalizers == [:reference]
    assert inspection.registries.rule_bindings == [:quantity_on_write, :reference_on_write]
    assert inspection.rules["schema"] == "selecto.data_rules.v1"
    assert "rule:number.gt" in inspection.rules["required_features"]
    assert inspection.rules["bindings"]["quantity_on_write"]["stage"] == "candidate"
    assert inspection.rules["evaluation"]["server_revalidation_required"]
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

    assert {:error, [%{code: :invalid_normalizer_profile}]} =
             domain()
             |> put_in(
               [:rules, :normalizers, :reference, :steps, Access.at(1), :profile],
               "ascii_whitespace_v1"
             )
             |> Contract.compile()
  end

  test "rejects rules and normalizers that conflict with a known subject type" do
    assert {:error, [%{code: :rule_subject_type_mismatch, subject_type: "string"}]} =
             domain()
             |> put_in([:rules, :bindings, :reference_on_write, :rule], %{
               id: :positive_quantity,
               version: 1
             })
             |> Contract.compile()

    assert {:error, [%{code: :rule_subject_type_mismatch, subject_type: "integer"}]} =
             domain()
             |> put_in([:rules, :bindings, :quantity_on_write, :normalizer], %{
               id: :reference,
               version: 1
             })
             |> Contract.compile()
  end

  test "compiles a strict native constraint declaration into the canonical binding" do
    native = %{
      adapter: "postgresql",
      constraint: "line_items_quantity_positive",
      category: "check_violation"
    }

    assert {:ok, contract} =
             domain()
             |> put_in([:rules, :bindings, :quantity_on_write, :native_constraint], native)
             |> Contract.compile()

    assert contract.bindings["quantity_on_write"].native_constraint == %{
             adapter: "postgresql",
             constraint: "line_items_quantity_positive",
             category: "check_violation"
           }

    assert "native_constraint:postgresql" in contract.required_features

    assert {:error, [%{code: :unknown_rule_option, path: path}]} =
             domain()
             |> put_in([:rules, :bindings, :quantity_on_write, :native_constraint], %{
               adapter: "postgresql",
               constraint: "line_items_quantity_positive",
               category: "check_violation",
               unsafe: true
             })
             |> Contract.compile()

    assert path == [:rules, :bindings, "quantity_on_write", :native_constraint]
  end

  test "rejects unbounded or non-portable regex syntax" do
    assert {:error, %{code: :invalid_text_pattern}} =
             Contract.compile_test(%{
               op: "text.pattern",
               profile: "ascii_v1",
               pattern: "(?=VIN)",
               match: "search"
             })

    for pattern <- ["\\p{L}+", "a+?", "[[:alpha:]]"] do
      assert {:error, %{code: :invalid_text_pattern}} =
               Contract.compile_test(%{
                 op: "text.pattern",
                 profile: "ascii_v1",
                 pattern: pattern,
                 match: "search"
               })
    end
  end

  test "resolves canonical rules bound to writable relationship collections" do
    relationship = %{
      enabled: true,
      cardinality: :many,
      allowed_ops: [:insert],
      ownership: :owned,
      child_key: :order_id,
      parent_key: :id,
      identity_fields: [:id],
      domain: domain()
    }

    nested =
      domain()
      |> put_in([:writes], %{
        operations: %{insert: %{enabled: true}},
        fields: %{quantity: %{insertable: true}, reference: %{insertable: true}},
        relationships: %{items: relationship}
      })
      |> put_in([:rules, :definitions, :three_items], %{
        version: 1,
        test: %{op: "collection.count", exact: 3}
      })
      |> put_in([:rules, :bindings, :three_items], %{
        subject: %{scope: :input, path: [:items]},
        operations: [:insert],
        rule: %{id: :three_items, version: 1}
      })

    assert {:ok, contract} = Contract.compile(nested)
    assert contract.bindings["three_items"].subject.path == ["items"]
    assert contract.bindings["three_items"].subject_type == "collection"

    assert {:error, [%{code: :unresolved_rule_subject}]} =
             nested
             |> put_in([:rules, :bindings, :three_items, :subject, :path], [:missing_items])
             |> Contract.compile()
  end

  test "semantic fingerprints use stable canonical JSON bytes" do
    domain = %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id, :value],
        columns: %{id: %{type: :integer}, value: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{present: %{version: 1, test: %{op: "presence.required"}}},
        normalizers: %{},
        bindings: %{
          value: %{
            subject: %{scope: :candidate, path: [:value]},
            rule: %{id: :present, version: 1}
          }
        }
      }
    }

    assert {:ok, contract} = Contract.compile(domain)

    assert contract.fingerprint ==
             "sha256:99b53d0df797657c165281d70b4f3a29001f8a5b9b072b5a48ae4712d19dc2a0"
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
