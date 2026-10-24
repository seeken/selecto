defmodule Selecto.QueryMemberExactTest do
  # A query member's GROUP BY and its pairing with the root are host
  # identity on exact-compare adapters (MySQL, MariaDB): every text or
  # unknown group key also groups by its utf8mb4 bytes (an aliased key
  # included), and a join on a key a host predicate reads pairs exactly.
  # Other adapters compile as before.
  use ExUnit.Case, async: true

  defmodule ExactAdapter do
    @moduledoc false
    def name, do: :exact_test
    def supports?(feature), do: feature in [:exact_tenant_compare, :cte]
    def quote_identifier(identifier), do: "`#{String.replace(identifier, "`", "``")}`"
    def placeholder(_index), do: "?"
  end

  defp rel(table, cols, tenant_field) do
    %{
      source_table: table,
      primary_key: :id,
      fields: cols |> Map.keys() |> Enum.sort(),
      redact_fields: [],
      columns: Map.new(cols, fn {n, t} -> {n, %{type: t}} end),
      associations: %{}
    }
    |> then(&if(tenant_field, do: Map.put(&1, :tenant_field, tenant_field), else: &1))
  end

  defp domain(required) do
    sum = %{"as" => "s", "aggregate" => "sum", "field" => "amount"}

    %{
      name: "MG",
      source: rel("mg_root", %{id: :integer, org_key: :string}, nil),
      schemas: %{
        use: rel("mg_use", %{id: :integer, org_key: :string, amount: :integer, n: :integer}, nil)
      },
      joins: %{},
      required_filters: required,
      query_members: %{
        ctes: %{
          tot: %{
            source: "use",
            query: %{"select" => ["org_key", "n", sum], "group_by" => ["org_key", "n"]},
            join: %{owner_key: "org_key", related_key: "org_key", type: "left"}
          },
          ali: %{
            source: "use",
            query: %{
              "select" => [%{"as" => "k", "value" => ["field", "org_key"]}, sum],
              "group_by" => ["org_key"]
            },
            join: %{owner_key: "org_key", related_key: "k", type: "left"}
          }
        }
      }
    }
  end

  defp sql(adapter, cte, required \\ [{"org_key", "t1"}]) do
    domain(required)
    |> Selecto.configure(Selecto.Runtime.Context.new(adapter, :compile_only), validate: false)
    |> Selecto.with_cte(cte)
    |> Selecto.select(["id", "#{cte}.s"])
    |> Selecto.to_sql()
    |> elem(0)
    |> String.replace(~r/\s+/, " ")
  end

  test "member text group keys also group by their bytes; integer keys stay plain" do
    for cte <- [:tot, :ali] do
      text = sql(ExactAdapter, cte)
      assert text =~ "CAST(CONVERT(cte_#{cte}.org_key USING utf8mb4) AS BINARY)", text
      refute text =~ "CONVERT(cte_#{cte}.n USING"
      refute sql(SelectoDBSQLite.Adapter, cte) =~ "BINARY"
    end
  end

  test "a join on a key a host predicate reads pairs exactly" do
    text = sql(ExactAdapter, :tot)

    assert text =~
             "(tot.org_key = selecto_root.org_key AND CAST(CONVERT(tot.org_key USING utf8mb4) AS BINARY) = CAST(CONVERT(selecto_root.org_key USING utf8mb4) AS BINARY))"

    # Without a host predicate on the key the join keeps the collation.
    refute sql(ExactAdapter, :tot, []) =~ "CONVERT(selecto_root.org_key"
  end
end
