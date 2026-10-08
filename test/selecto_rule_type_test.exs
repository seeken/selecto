defmodule Selecto.Rule.TypeTest do
  use ExUnit.Case, async: true
  alias Selecto.Rule.{Contract, Evaluator}

  test "type predicates preserve text even when it is an exact numeric operand" do
    for value <- ["0.1", "1", "-2", "1e3", "+1", " 2 "] do
      assert {:failed, %{code: :invalid_type}} = check("decimal", value)
      assert {:failed, %{code: :invalid_type}} = check("integer", value)
      assert :passed = check("text", value)
    end

    {:ok, positive} = Contract.compile_test(%{op: "number.gt", bound: "0"})
    assert :passed = Evaluator.evaluate_test(positive, "0.1")
  end

  test "genuine numeric kinds retain decimal membership without changing integer membership" do
    for value <- [0, -2, 0.1, Decimal.new("0.1")] do
      assert :passed = check("decimal", value)
      assert {:failed, %{code: :invalid_type}} = check("text", value)
    end

    assert :passed = check("integer", 1)
    assert {:failed, %{code: :invalid_type}} = check("integer", 1.0)
    assert {:failed, %{code: :invalid_type}} = check("integer", Decimal.new(1))
  end

  test "native scalar structs do not acquire portable object membership" do
    assert :passed = check("object", %{"quantity" => 1})
    assert {:failed, %{code: :invalid_type}} = check("object", Decimal.new("0.1"))
    assert {:failed, %{code: :invalid_type}} = check("object", ~D[2026-10-08])
  end

  test "null and boolean are distinct from numeric types" do
    for value <- [nil, true, false] do
      assert {:failed, %{code: :invalid_type}} = check("decimal", value)
      assert {:failed, %{code: :invalid_type}} = check("integer", value)
    end

    assert :passed = check("boolean", false)
  end

  test "numeric kind checks preserve the evaluator resource guard" do
    assert {:error, %{code: :evaluation_limit}} = check("decimal", Decimal.new("1e5000"))
    assert {:error, %{code: :evaluation_limit}} = check("decimal", String.duplicate("1", 17000))
  end

  defp check(type, value) do
    {:ok, test} = Contract.compile_test(%{op: "type.is", type: type})
    Evaluator.evaluate_test(test, value)
  end
end
