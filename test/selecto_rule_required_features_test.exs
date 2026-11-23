defmodule Selecto.Rule.RequiredFeaturesTest do
  use ExUnit.Case, async: true

  alias Selecto.Rule.Contract

  test "structural feature requirements include every nested operator" do
    test = %{
      op: "object.shape",
      required: [:quantity],
      additional: false,
      properties: %{
        quantity: %{
          op: "all",
          rules: [
            %{op: "type.is", type: "integer"},
            %{op: "number.range", min: 1, max: 16}
          ]
        },
        optional: %{
          op: "path.test",
          path: [:nested],
          test: %{
            op: "object.shape",
            additional: false,
            properties: %{
              label: %{
                op: "any",
                rules: [
                  %{op: "value.eq", value: ""},
                  %{
                    op: "not",
                    rule: %{op: "text.pattern", profile: "ascii_v1", pattern: "x", match: "full"}
                  }
                ]
              }
            }
          }
        }
      }
    }

    assert {:ok, contract} = Contract.compile_rules(rules(test))

    assert contract.required_features == [
             "rule:logic",
             "rule:number.range",
             "rule:object.shape",
             "rule:path.test",
             "rule:text.pattern",
             "rule:type.is",
             "rule:value.eq",
             "rule_stage:action_input"
           ]

    assert {:ok, recompiled} = contract |> Contract.project() |> Contract.compile_projection()
    assert recompiled.required_features == contract.required_features
    assert recompiled.fingerprint == contract.fingerprint
  end

  test "stage projections include nested conditions and exclude unrelated requirements" do
    rules =
      rules(%{op: "path.test", path: [:quantity], test: %{op: "number.gt", bound: 0}})
      |> put_in([:definitions, :unused], %{
        version: 1,
        test: %{op: "text.suffix", text: "unused"}
      })
      |> put_in([:definitions, :present], %{version: 1, test: %{op: "presence.required"}})
      |> put_in([:bindings, :configuration, :condition], %{
        op: "path.test",
        path: [:context],
        test: %{
          op: "object.shape",
          additional: false,
          properties: %{role: %{op: "text.prefix", text: "operator"}}
        }
      })
      |> put_in([:bindings, :candidate], %{
        subject: %{scope: :candidate, path: [:quantity]},
        rule: %{id: :present, version: 1}
      })

    assert {:ok, contract} = Contract.compile_rules(rules)

    assert contract.required_features == [
             "rule:condition",
             "rule:number.gt",
             "rule:object.shape",
             "rule:path.test",
             "rule:presence.required",
             "rule:text.prefix",
             "rule_stage:action_input",
             "rule_stage:candidate"
           ]

    action = Contract.project(contract, stages: [:action_input])

    assert action["required_features"] == [
             "rule:condition",
             "rule:number.gt",
             "rule:object.shape",
             "rule:path.test",
             "rule:text.prefix",
             "rule_stage:action_input"
           ]

    assert Map.keys(action["definitions"]) == ["configuration"]
    assert {:ok, _} = Contract.compile_projection(action)

    candidate = Contract.project(contract, stages: [:candidate])

    assert candidate["required_features"] == ["rule:presence.required", "rule_stage:candidate"]
    assert {:ok, _} = Contract.compile_projection(candidate)

    empty = Contract.project(contract, stages: [])
    assert empty["required_features"] == []
    assert {:ok, _} = Contract.compile_projection(empty)
  end

  test "operator-shaped literal values are data rather than nested rule requirements" do
    assert {:ok, contract} =
             rules(%{
               op: "value.eq",
               value: %{"op" => "host.call", "test" => %{"op" => "unknown"}}
             })
             |> Contract.compile_rules()

    assert contract.required_features == ["rule:value.eq", "rule_stage:action_input"]
  end

  test "a projection cannot hide an operator nested inside a structural rule" do
    assert {:ok, contract} =
             rules(%{op: "path.test", path: [:quantity], test: %{op: "number.gt", bound: 0}})
             |> Contract.compile_rules()

    projection = Contract.project(contract)
    incomplete = Map.update!(projection, "required_features", &List.delete(&1, "rule:number.gt"))

    assert {:error, [%{code: :invalid_rule_projection}]} =
             Contract.compile_projection(incomplete)
  end

  defp rules(test) do
    %{
      schema: "selecto.data_rules.v1",
      definitions: %{configuration: %{version: 1, test: test}},
      normalizers: %{},
      bindings: %{
        configuration: %{
          subject: %{scope: :action_input, action: :replace_configuration, path: [:candidate]},
          rule: %{id: :configuration, version: 1}
        }
      }
    }
  end
end
