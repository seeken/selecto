defmodule ExternalAdapterTest do
  use ExUnit.Case, async: true

  @domain %{
    name: "External adapter fixture",
    source: %{
      source_table: "widgets",
      primary_key: :id,
      fields: [:id],
      redact_fields: [],
      columns: %{id: %{type: :integer}},
      associations: %{}
    },
    schemas: %{},
    joins: %{}
  }

  test "an independently compiled adapter uses the normal public boundary" do
    assert Selecto.DB.Adapter.contract_version() == 1
    assert AcmeSelectoAdapter.adapter_contract_version() == 1

    selecto =
      @domain
      |> Selecto.configure(:external_fixture_connection,
        adapter: AcmeSelectoAdapter,
        validate: false
      )
      |> Selecto.select(["id"])
      |> Selecto.filter({"id", 9})

    assert selecto.adapter == AcmeSelectoAdapter
    assert AcmeSelectoAdapter.supports?(:external_adapter_fixture)
    refute AcmeSelectoAdapter.supports?(:stream)

    {sql, _aliases, params} = Selecto.gen_sql(selecto, [])
    assert sql =~ "from widgets"
    assert sql =~ "@acme1"
    assert params == [9]

    assert {:ok, {[[42]], ["id"], [_alias]}} =
             Selecto.execute(selecto, analyze_complexity: false)
  end

  test "an explicitly incompatible adapter fails at injection time" do
    assert_raise ArgumentError, ~r/declares contract version 2.*requires 1/, fn ->
      Selecto.configure(@domain, :must_not_connect,
        adapter: Elixir.AcmeIncompatibleSelectoAdapter,
        validate: false
      )
    end
  end
end
