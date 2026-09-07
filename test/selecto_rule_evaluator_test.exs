defmodule Selecto.Rule.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Selecto.Rule.{Contract, Evaluator}

  test "normalizes and evaluates numeric, regex, and collection rules" do
    assert {:ok, contract} = Contract.compile(domain())

    assert %{disposition: :passed, values: values, obligations: []} =
             Evaluator.evaluate(
               contract,
               :candidate,
               %{quantity: "0.10", reference: " ab12 ", selected: [1, 2, 3]},
               operation: :insert
             )

    assert values.reference == "AB12"

    assert %{disposition: :failed, outcomes: outcomes} =
             Evaluator.evaluate(
               contract,
               :candidate,
               %{quantity: "0.00", reference: "no!", selected: [1, 2]},
               operation: :insert
             )

    assert Enum.any?(outcomes, &(&1.code == :numeric_bound))
    assert Enum.any?(outcomes, &(&1.code == :pattern_mismatch))
    assert Enum.any?(outcomes, &(&1.code == :invalid_collection_count))
  end

  test "distinguishes missing from explicit false and null" do
    assert {:ok, required} = Contract.compile_test(%{op: "presence.required"})
    assert :passed = Evaluator.evaluate_test(required, false)
    assert :passed = Evaluator.evaluate_test(required, nil)

    assert {:ok, non_null} = Contract.compile_test(%{op: "presence.non_null"})
    assert {:failed, %{code: :null}} = Evaluator.evaluate_test(non_null, nil)

    assert {:ok, equality} = Contract.compile_test(%{op: "value.eq", value: false})
    assert :passed = Evaluator.evaluate_test(equality, false)
  end

  test "uses exact decimal comparison and deterministic logical semantics" do
    assert {:ok, test} =
             Contract.compile_test(%{
               op: "all",
               rules: [
                 %{op: "number.gt", bound: "0.10"},
                 %{op: "number.multiple_of", factor: "0.01"}
               ]
             })

    assert :passed = Evaluator.evaluate_test(test, "0.11")
    assert {:failed, %{code: :numeric_bound}} = Evaluator.evaluate_test(test, "0.10")
    assert {:failed, %{code: :invalid_type}} = Evaluator.evaluate_test(test, 0.11)
  end

  test "compares a value with a related field using exact numeric semantics" do
    assert {:ok, test} =
             Contract.compile_test(%{op: "value.compare_path", comparison: "gt", path: [:start]})

    assert :passed = Evaluator.evaluate_test(test, "2.00", values: %{start: "1.50"})

    assert {:failed, %{code: :related_value_comparison}} =
             Evaluator.evaluate_test(test, "1.50", values: %{start: "1.50"})

    assert {:failed, %{code: :missing_related_value}} =
             Evaluator.evaluate_test(test, "2.00", values: %{})

    assert {:error, %{code: :invalid_related_value_rule}} =
             Contract.compile_test(%{
               op: "value.compare_path",
               comparison: "greater",
               path: [:start]
             })
  end

  test "validates strict temporal values and compares matching temporal kinds" do
    assert {:ok, date} = Contract.compile_test(%{op: "temporal.date"})
    assert :passed = Evaluator.evaluate_test(date, "2026-09-06")

    assert {:failed, %{code: :invalid_temporal_value}} =
             Evaluator.evaluate_test(date, "2026-02-30")

    assert {:ok, instant} = Contract.compile_test(%{op: "temporal.instant"})
    assert :passed = Evaluator.evaluate_test(instant, "2026-09-06T12:30:00Z")

    assert {:failed, %{code: :invalid_temporal_value}} =
             Evaluator.evaluate_test(instant, "2026-09-06")

    assert {:ok, after_start} =
             Contract.compile_test(%{
               op: "temporal.compare_path",
               kind: "date",
               comparison: "gt",
               path: [:start_date]
             })

    assert :passed =
             Evaluator.evaluate_test(after_start, "2026-09-07",
               values: %{start_date: "2026-09-06"}
             )

    assert {:failed, %{code: :temporal_comparison}} =
             Evaluator.evaluate_test(after_start, "2026-09-06",
               values: %{start_date: "2026-09-06"}
             )
  end

  test "returns required transaction and evidence checks as pending obligations" do
    assert {:ok, contract} = Contract.compile(obligation_domain())

    assert %{disposition: :pending, obligations: obligations} =
             Evaluator.evaluate(contract, :transaction, %{reference: "ABC"})

    assert [%{binding_id: "unique_reference", stage: "transaction"}] = obligations

    assert %{disposition: :passed, obligations: []} =
             Evaluator.evaluate(contract, :transaction, %{reference: "ABCD"},
               authoritative_stage: "transaction"
             )
  end

  defp domain do
    %{
      source: %{
        source_table: "line_items",
        primary_key: :id,
        fields: [:quantity, :reference, :selected],
        columns: %{}
      },
      schemas: %{},
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{
          positive: %{version: 1, test: %{op: "number.gt", bound: "0"}},
          reference: %{
            version: 1,
            test: %{
              op: "text.pattern",
              profile: "ascii_v1",
              pattern: "[A-Z0-9]{4,12}",
              match: "full"
            }
          },
          exactly_three: %{version: 1, test: %{op: "collection.count", exact: 3}}
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
          positive: %{
            subject: %{scope: :candidate, path: [:quantity]},
            rule: %{id: :positive, version: 1}
          },
          reference: %{
            subject: %{scope: :candidate, path: [:reference]},
            normalizer: %{id: :reference, version: 1},
            rule: %{id: :reference, version: 1}
          },
          exactly_three: %{
            subject: %{scope: :candidate, path: [:selected]},
            rule: %{id: :exactly_three, version: 1}
          }
        }
      }
    }
  end

  defp obligation_domain do
    put_in(domain(), [:rules, :bindings], %{
      unique_reference: %{
        subject: %{scope: :transaction, path: [:reference]},
        rule: %{id: :reference, version: 1}
      }
    })
  end
end
