defmodule Selecto.Rule.ProtocolFixtureTest do
  use ExUnit.Case, async: true

  alias Selecto.Rule.{Contract, Evaluator}

  @fixture_root System.get_env("SELECTO_DATA_RULE_FIXTURES")
  @moduletag :protocol
  @moduletag skip: is_nil(@fixture_root)

  test "Elixir matches the normative data-rules evaluator corpus" do
    contract_fixture = read_json("baseline.contract.json")
    cases_fixture = read_json("baseline.cases.json")
    assert {:ok, contract} = Contract.compile(domain(contract_fixture))

    for fixture <- cases_fixture["cases"] do
      opts =
        [operation: fixture["operation"]]
        |> maybe_put(:action, fixture["action"])
        |> maybe_put(:authoritative_stage, fixture["authoritative_stage"])

      result = Evaluator.evaluate(contract, fixture["stage"], fixture["subject"], opts)
      expected = fixture["expected"]

      assert to_string(result.disposition) == expected["state"], fixture["id"]

      if expected["code"] do
        assert Enum.any?(result.outcomes, &(to_string(&1.code) == expected["code"])),
               fixture["id"]
      end

      if Map.has_key?(expected, "normalized") do
        assert result.values == expected["normalized"], fixture["id"]
      end
    end
  end

  test "Elixir matches the normative invalid compiler corpus" do
    baseline = read_json("baseline.contract.json")
    invalid = read_json("invalid.cases.json")

    for fixture <- invalid["cases"] do
      rules = deep_merge(baseline, fixture["patch"])
      assert {:error, errors} = Contract.compile(domain(rules)), fixture["id"]
      assert Enum.any?(errors, &(to_string(&1.code) == fixture["expected_code"])), fixture["id"]
    end
  end

  test "Elixir reproduces the normative compiled semantic fingerprint" do
    authored = read_json("baseline.contract.json")
    compiled = read_json("baseline.compiled.json")
    assert {:ok, contract} = Contract.compile(domain(authored))
    assert contract.fingerprint == compiled["fingerprint"]
    assert Contract.project(contract) == compiled
  end

  defp domain(rules) do
    fields = ~w(id quantity reference selected items verdict)

    %{
      source: %{
        source_table: "rules",
        primary_key: "id",
        fields: fields,
        columns: Map.new(fields, &{&1, %{type: :string}}),
        associations: %{}
      },
      schemas: %{},
      rules: rules
    }
  end

  defp read_json(name) do
    (@fixture_root || "")
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
