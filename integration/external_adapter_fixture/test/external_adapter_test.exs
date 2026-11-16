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

  test "an explicitly selected missing adapter fails before connecting" do
    refute Code.ensure_loaded?(Tds)

    assert_raise ArgumentError,
                 ~r/adapter .* is unavailable; install its separate adapter package/,
                 fn ->
                   Selecto.configure(@domain, :compile_only,
                     adapter: UninstalledCommercialAdapter,
                     validate: false
                   )
                 end
  end

  test "an explicitly incompatible adapter fails at injection time" do
    assert_raise ArgumentError, ~r/declares contract version 2.*requires 1/, fn ->
      Selecto.configure(@domain, :must_not_connect,
        adapter: Elixir.AcmeIncompatibleSelectoAdapter,
        validate: false
      )
    end
  end

  test "installed dialect hooks use only public compiled fragments and ordered binds" do
    assert Selecto.DB.Dialect.contract_version() == 1

    assert Selecto.DialectSupport.query_strategy(AcmeSelectoAdapter, :recursive_cte, %{}) ==
             :plain

    fragment = %Selecto.Dialect.Query.Predicate{expression: "@acme1 = @acme2", params: [7, 9]}

    assert {:ok, {rendered, [7, 9]}} =
             Selecto.DialectSupport.render_scalar_predicate(AcmeSelectoAdapter, fragment, %{})

    assert IO.iodata_to_binary(rendered) == "TRUTH(@acme1 = @acme2)"

    collection = %Selecto.Dialect.Query.Collection{
      format: :json_agg,
      fields: [],
      table: "widgets",
      table_alias: "w",
      where: "1=1",
      params: []
    }

    assert {:error, :external_collection_refusal} =
             Selecto.DialectSupport.render_collection_query(AcmeSelectoAdapter, collection, %{})
  end

  test "normal query compilation invokes the installed external dialect" do
    query =
      @domain
      |> Selecto.configure(:external_fixture_connection,
        adapter: AcmeSelectoAdapter,
        validate: false
      )
      |> Selecto.select([{:stddev, "id"}])

    {sql, _aliases, []} = Selecto.gen_sql(query, [])
    assert sql =~ "ACME_STDDEV("
  end
end
