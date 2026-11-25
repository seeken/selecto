defmodule Selecto.APIUniqueKeyMappingTest do
  use ExUnit.Case, async: true
  alias Selecto.Write.UniqueKeys

  defp error(details) do
    %{
      type: :execution_failed,
      message: "private database value",
      details: Map.put(details, :category, :unique_violation)
    }
  end

  test "an exact declared constraint wins over another key with the same fields" do
    domain = %{writes: %{unique_keys: %{a: ["owner", "name"], z: ["owner", "name"]}}}
    result = UniqueKeys.normalize(error(%{constraint: "z", fields: ["name", "owner"]}), domain)
    assert result.details.key == "z"
    assert result.details.fields == ["name", "owner"]
    refute inspect(result) =~ "private database value"
  end

  test "ambiguous field-only evidence leaves the declared key unnamed" do
    domain = %{writes: %{unique_keys: %{a: ["owner", "name"], z: ["owner", "name"]}}}
    result = UniqueKeys.normalize(error(%{fields: ["name", "owner"]}), domain)
    assert result.type == :database_unique_violation
    assert result.details.key == nil
    assert result.details.fields == []
  end

  test "one matching field list identifies the declared key safely" do
    domain = %{writes: %{unique_keys: %{owner_name: ["owner", "name"], id: ["id"]}}}
    result = UniqueKeys.normalize(error(%{column: "records.name, records.owner"}), domain)
    assert result.details.key == "owner_name"
    assert result.details.fields == ["name", "owner"]
  end
end
