defmodule Selecto.DomainExamplesWriteTenancyTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.{Examples, WriteContract}

  test "work_items owners are tenant data, so an owner reassignment stays in the tenant" do
    assert Examples.work_items().schemas.owners.tenant_field == :tenant_id
  end

  test "camp_registrations declares cabins as a shared reference" do
    {:ok, contract} = WriteContract.compile(Examples.camp_registrations())

    assert %{source: :input, references: references} =
             WriteContract.foreign_keys(contract)["cabin_id"]

    assert references.relation == "camp_cabins"
    assert references.tenant_field == false
  end
end
