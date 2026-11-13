defmodule SelectoUpdato.ExampleDomainsWriteTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain.Examples
  alias Selecto.Write.Command
  alias SelectoUpdato.PortableCommand

  @member [choice_source_membership_resolver: &__MODULE__.member/1]

  def member(_request), do: Selecto.Domain.Choices.valid(:example_member)

  test "work_items reassigns an owner inside the trusted tenant" do
    operation =
      Examples.work_items()
      |> SelectoUpdato.new([tenant: %{tenant_id: 7}] ++ @member)
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{owner_id: 42})

    assert {:ok, %Command{metadata: %{foreign_key_guards: [guard]}}, _context} =
             PortableCommand.compile(operation)

    assert %{field: "owner_id", tenant_field: "tenant_id", tenant_value: 7} = guard
  end

  test "camp_registrations assigns and clears a shared cabin" do
    assign =
      Examples.camp_registrations()
      |> SelectoUpdato.new([tenant: %{tenant_id: 7}] ++ @member)
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{cabin_id: 3})

    assert {:ok, %Command{metadata: %{foreign_key_guards: [guard]}}, _context} =
             PortableCommand.compile(assign)

    assert %{field: "cabin_id", relation: "camp_cabins"} = guard
    refute Map.has_key?(guard, :tenant_field)

    clear =
      Examples.camp_registrations()
      |> SelectoUpdato.new([tenant: %{tenant_id: 7}] ++ @member)
      |> SelectoUpdato.filter({:id, 1})
      |> SelectoUpdato.update(%{cabin_id: nil})

    assert {:ok, %Command{metadata: metadata}, _context} = PortableCommand.compile(clear)
    assert Map.get(metadata, :foreign_key_guards, []) == []
  end
end
