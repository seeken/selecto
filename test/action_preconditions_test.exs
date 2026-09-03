defmodule Selecto.Domain.ActionPreconditionsTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.ActionPreconditions

  test "map comparator aliases only default when absent or nil" do
    for key <- [:comparator, :operator, :op], invalid <- [false, 0, "", %{}, []] do
      assert {:error, %{code: :invalid_action_precondition_comparator}} =
               ActionPreconditions.normalize([%{key => invalid, :field => :id, :value => 7}])
    end

    assert {:ok, [%{comparator: :eq}]} =
             ActionPreconditions.normalize([%{field: :id, value: 7}])

    assert {:ok, [%{comparator: :gte}]} =
             ActionPreconditions.normalize([%{field: :id, value: 7, comparator: nil, op: ">="}])
  end
end
