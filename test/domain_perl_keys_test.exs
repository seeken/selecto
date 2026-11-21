defmodule Selecto.DomainPerlKeysTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain

  defp relation(table) do
    %{
      "source_table" => table,
      "primary_key" => "id",
      "fields" => ["id", "maker_id"],
      "columns" => %{"id" => %{"type" => "integer"}, "maker_id" => %{"type" => "integer"}},
      "associations" => %{}
    }
  end

  defp base do
    %{
      "schema_version" => 1,
      "name" => "Keys",
      "source" =>
        put_in(relation("items"), ["associations"], %{
          "maker" => %{"queryable" => "makers", "owner_key" => "maker_id", "related_key" => "id"}
        }),
      "schemas" => %{"makers" => relation("makers")},
      "joins" => %{}
    }
  end

  defp codes(domain) do
    case Domain.validate(domain) do
      {:ok, _normalized, diagnostics} -> {:ok, diagnostics.unknown_sections}
      {:error, diagnostics} -> {:error, Enum.map(diagnostics.errors, & &1.code)}
    end
  end

  test "top-level associations and jsonb_schemas are recognised opaque metadata" do
    domain =
      base()
      |> Map.put("associations", %{"legacy" => %{"queryable" => "anything"}})
      |> Map.put("jsonb_schemas", %{"payload" => %{"fields" => %{"a" => "string"}}})

    assert {:ok, []} = codes(domain)
    assert {:ok, export} = Domain.contract_json(domain)
    assert export["jsonb_schemas"] == domain["jsonb_schemas"]
    assert export["associations"] == domain["associations"]
  end

  test "tenant_required and require_tenant: booleans or 0/1, and the aliases agree" do
    for value <- [true, false, 0, 1, "0", "1", nil],
        key <- ["tenant_required", "require_tenant"],
        do: assert({:ok, _} = codes(Map.put(base(), key, value)))

    assert {:error, [:invalid_tenant_requirement]} =
             codes(Map.put(base(), "tenant_required", "maybe"))

    assert {:error, [:invalid_tenant_requirement]} =
             codes(base() |> Map.put("tenant_required", 1) |> Map.put("require_tenant", false))

    assert {:ok, _} =
             codes(base() |> Map.put("tenant_required", 1) |> Map.put("require_tenant", true))
  end

  test "a domain's 0/1 tenant requirement is read as a boolean" do
    assert Selecto.Tenant.domain_requirement(%{tenant_required: 1}) == {:ok, true}
    assert Selecto.Tenant.domain_requirement(%{"require_tenant" => "0"}) == {:ok, false}

    assert Selecto.Tenant.domain_requirement(%{tenant_required: nil, require_tenant: 1}) ==
             {:ok, true}

    assert Selecto.Tenant.domain_requirement(%{}) == :error
  end

  test "an association's join_strategy is lateral_lookup on a direct association" do
    strategy = fn value ->
      put_in(base(), ["source", "associations", "maker", "join_strategy"], value)
    end

    assert {:ok, _} = codes(strategy.("lateral_lookup"))
    assert {:ok, _} = codes(strategy.("LATERAL_LOOKUP"))
    assert {:error, [:invalid_association_join_strategy]} = codes(strategy.("hash"))
    assert {:error, [:invalid_association_join_strategy]} = codes(strategy.(nil))

    through =
      strategy.("lateral_lookup")
      |> put_in(["source", "associations", "maker", "through"], %{
        "table" => "links",
        "owner_key" => "item_id",
        "related_key" => "maker_id"
      })

    assert {:error, codes} = codes(through)
    assert :invalid_association_join_strategy in codes
  end
end
