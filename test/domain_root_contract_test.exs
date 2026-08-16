defmodule Selecto.DomainRootContractTest do
  use ExUnit.Case, async: true

  test "the domain owns the query root and query composition cannot override it" do
    refute function_exported?(Selecto, :from, 1)
    refute function_exported?(Selecto, :from, 2)

    orders_sql = compile_from("domain_root_orders")
    archive_sql = compile_from("domain_root_archived_orders")

    assert orders_sql =~ "from domain_root_orders selecto_root"
    refute orders_sql =~ "domain_root_archived_orders"
    assert archive_sql =~ "from domain_root_archived_orders selecto_root"
  end

  defp compile_from(source_table) do
    domain = %{
      name: "Domain-owned root",
      source: %{
        source_table: source_table,
        primary_key: :id,
        fields: [:id, :status],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          status: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    query =
      domain
      |> Selecto.configure(:compile_only)
      |> Selecto.select(["id"])
      |> Selecto.filter({"status", "open"})

    {sql, _aliases, _params} = Selecto.gen_sql(query, [])
    String.downcase(sql)
  end
end
