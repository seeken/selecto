defmodule Selecto.Rule.StandaloneContractTest do
  use ExUnit.Case, async: true

  alias Selecto.Rule.{Compiler, Contract, Evaluator}

  test "standalone rules preserve nonempty IDs, undeclared action names and conditions" do
    rules = baseline()
    binding = rules.bindings.quantity

    rules =
      rules
      |> put_in([:bindings], %{
        "quantity-check" => %{
          binding
          | subject: %{scope: "action_input", action: "not.declared/✓", path: ["quantity"]}
        }
      })
      |> put_in([:bindings, "quantity-check", :condition], %{op: "value.eq", value: 1})

    assert {:ok, contract} = Compiler.compile_rules(rules, diagnostics: :portable)
    assert contract.bindings["quantity-check"].subject.action == "not.declared/✓"
    assert contract.bindings["quantity-check"].condition == %{"op" => "value.eq", "value" => 1}

    assert %{disposition: :passed} =
             Evaluator.evaluate(contract, "action_input", %{"quantity" => 1},
               action: "not.declared/✓"
             )

    assert {:error, [%{code: :unresolved_rule_subject}]} = Contract.compile(domain(rules))

    rules =
      rules
      |> put_in([:bindings], %{" " => rules.bindings["quantity-check"]})
      |> put_in([:bindings, " ", :subject, :action], " ")

    assert {:ok, contract} = Contract.compile_rules(rules)
    assert contract.bindings[" "].subject.action == " "
  end

  test "malformed host registry and reference keys return diagnostics instead of raising" do
    for id <- ["", 1, true, nil, {:invalid, :key}, %{}, []] do
      assert {:error, [%{code: :invalid_data_rules_contract}]} =
               baseline()
               |> put_in([:definitions], %{id => baseline().definitions.positive})
               |> Contract.compile_rules(diagnostics: :portable)

      assert {:error, [%{code: :invalid_data_rules_contract}]} =
               baseline()
               |> put_in([:bindings, :quantity, :rule, :id], id)
               |> Contract.compile_rules(diagnostics: :portable)
    end

    assert {:error, [%{code: :unknown_rule_option}]} =
             baseline()
             |> Map.put({:invalid, :key}, 1)
             |> Contract.compile_rules(diagnostics: :portable)
  end

  test "canonical digit-string versions stay exact and compare with integer references" do
    version = "900719925474099312345"

    rules =
      baseline()
      |> put_in([:definitions, :positive, :version], version)
      |> put_in([:bindings, :quantity, :rule, :version], 900_719_925_474_099_312_345)

    assert {:ok, contract} = Contract.compile_rules(rules)
    assert contract.definitions["positive"].version == 900_719_925_474_099_312_345
    assert contract.bindings["quantity"].rule.version == contract.definitions["positive"].version

    for version <- ["0", "01", "+1", "1.0", "1e0", " 1", "1\n", String.duplicate("1", 4097)] do
      assert {:error, [%{code: :invalid_rule_version}]} =
               baseline()
               |> put_in([:definitions, :positive, :version], version)
               |> Contract.compile_rules()
    end

    assert {:ok, integer} = Contract.compile_rules(baseline())

    assert {:ok, string} =
             baseline()
             |> put_in([:definitions, :positive, :version], "1")
             |> Contract.compile_rules()

    assert string.fingerprint == integer.fingerprint
  end

  test "numeric tokens reject lossy/nonportable syntax but finite native decimals remain exact" do
    for literal <- [
          "1e3",
          "1E-3",
          "+1",
          "01",
          ".5",
          "1.",
          " 1",
          "1\n",
          "NaN",
          "Infinity",
          1.0,
          %{type: "decimal", value: "1e3"},
          Decimal.new("NaN"),
          Decimal.new("Infinity"),
          Decimal.new("1e1000000"),
          String.duplicate("1", 4097)
        ] do
      assert {:error,
              [%{code: :invalid_data_rules_contract, legacy_code: :invalid_number_literal}]} =
               baseline()
               |> put_in([:definitions, :positive, :test, :bound], literal)
               |> Contract.compile_rules(diagnostics: :portable)
    end

    for literal <- [0, "-0", "-0.125", "900719925474099312345.0001", Decimal.new("1E-400")] do
      assert {:ok, _} =
               baseline()
               |> put_in([:definitions, :positive, :test, :bound], literal)
               |> Contract.compile_rules()
    end
  end

  test "duplicate operations and semantic uniqueness paths refuse before evaluation" do
    for operations <- [["insert", "insert"], [:insert, "insert"], [%{}], ["unknown"]] do
      assert {:error, [%{code: :invalid_rule_operations}]} =
               baseline()
               |> put_in([:bindings, :quantity, :operations], operations)
               |> Contract.compile_rules()
    end

    for paths <- [[[:sku], ["sku"]], [["sku"], ["sku"]], [["sku"], []], []] do
      assert {:error, %{code: :invalid_unique_rule}} =
               Contract.compile_test(%{op: "collection.unique_by", paths: paths})
    end

    assert {:ok, %{"paths" => [["sku"], ["variant"]]}} =
             Contract.compile_test(%{op: "collection.unique_by", paths: [[:sku], ["variant"]]})

    assert {:ok, all_operations} =
             baseline()
             |> put_in([:bindings, :quantity, :operations], [])
             |> Contract.compile_rules()

    assert all_operations.bindings["quantity"].operations == []
  end

  test "standalone parse needs registries and permits action only for action input" do
    for rules <- [nil, %{}, Map.delete(baseline(), :normalizers)] do
      assert {:error, [%{code: :invalid_data_rules_contract}]} =
               Contract.compile_rules(rules, diagnostics: :portable)
    end

    assert {:error, [%{code: :invalid_rule_subject}]} =
             baseline()
             |> put_in([:bindings, :quantity, :subject, :action], "approve")
             |> Contract.compile_rules()
  end

  test "portable diagnostics preserve detailed legacy error codes" do
    mutations = [
      {[:schema], "unknown", :invalid_rules_schema, :invalid_data_rules_contract},
      {[:definitions, :positive, :test], %{op: "host.call"}, :unsupported_rule_operator,
       :unsupported_rule_operator},
      {[:definitions, :positive, :test], %{op: "number.gt", bound: "0", remote_url: "invalid"},
       :unknown_rule_option, :unknown_rule_option},
      {[:definitions, :positive, :test], %{op: "collection.count", exact: 2, min: 1},
       :conflicting_rule_bounds, :invalid_data_rules_contract},
      {[:bindings, :quantity, :rule, :id], "absent", :unresolved_rule_reference,
       :unresolved_rule_reference},
      {[:bindings, :quantity, :normalizer], %{id: "absent", version: 1},
       :unresolved_normalizer_reference, :unresolved_rule_reference}
    ]

    for {path, value, legacy, portable} <- mutations do
      rules = put_in(baseline(), path, value)
      assert {:error, [%{code: ^legacy}]} = Contract.compile_rules(rules)

      assert {:error, [%{code: ^portable} = diagnostic]} =
               Contract.compile_rules(rules, diagnostics: :portable)

      assert Map.get(diagnostic, :legacy_code, legacy) == legacy
    end
  end

  test "conditions observe the normalized subject and preserve normalization when skipped" do
    rules = %{
      schema: "selecto.data_rules.v1",
      definitions: %{reference: %{version: 1, test: %{op: "text.prefix", text: "AB"}}},
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
        reference: %{
          subject: %{scope: :candidate, path: [:reference]},
          rule: %{id: :reference, version: 1},
          normalizer: %{id: :reference, version: 1},
          condition: %{op: "value.eq", value: "AB12"}
        }
      }
    }

    assert {:ok, contract} = Contract.compile_rules(rules)

    assert %{
             disposition: :passed,
             values: %{"reference" => "AB12"},
             outcomes: [%{disposition: :passed}]
           } =
             Evaluator.evaluate(contract, :candidate, %{"reference" => " ab12 "})

    assert %{
             disposition: :passed,
             values: %{"reference" => "ZZ99"},
             outcomes: [%{disposition: :not_applicable}]
           } =
             Evaluator.evaluate(contract, :candidate, %{"reference" => " zz99 "})

    assert %{disposition: :error, outcomes: [%{disposition: :error}]} =
             Evaluator.evaluate(contract, :candidate, %{"reference" => "éclair"})

    rules =
      put_in(rules, [:bindings, :reference, :condition], %{
        op: "all",
        rules: [
          %{op: "value.eq", value: "AB12"},
          %{op: "path.test", path: [:reference], test: %{op: "value.eq", value: "AB12"}},
          %{op: "path.test", path: [:kind], test: %{op: "value.eq", value: "coupon"}}
        ]
      })

    assert {:ok, contract} = Contract.compile_rules(rules)

    assert %{disposition: :passed, outcomes: [%{disposition: :passed}]} =
             Evaluator.evaluate(contract, :candidate, %{
               "reference" => " ab12 ",
               "kind" => "coupon"
             })

    assert %{disposition: :passed, outcomes: [%{disposition: :not_applicable}]} =
             Evaluator.evaluate(contract, :candidate, %{
               "reference" => " ab12 ",
               "kind" => "standard"
             })
  end

  defp baseline do
    %{
      schema: "selecto.data_rules.v1",
      definitions: %{positive: %{version: 1, test: %{op: "number.gt", bound: "0"}}},
      normalizers: %{},
      bindings: %{
        quantity: %{
          subject: %{scope: "candidate", path: ["quantity"]},
          operations: [:insert],
          rule: %{id: :positive, version: 1}
        }
      }
    }
  end

  defp domain(rules) do
    %{
      source: %{
        source_table: "rule_items",
        primary_key: :id,
        fields: [:id, :quantity],
        columns: %{id: %{type: :integer}, quantity: %{type: :integer}},
        associations: %{}
      },
      schemas: %{},
      rules: rules
    }
  end
end
