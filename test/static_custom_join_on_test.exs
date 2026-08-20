defmodule Selecto.StaticCustomJoinOnTest do
  use ExUnit.Case, async: true

  test "static non-association joins preserve compound on conditions" do
    domain = %{
      name: "Tenant orders",
      source: %{
        source_table: "orders",
        primary_key: "id",
        fields: ["id", "tenant_id"],
        columns: %{
          "id" => %{type: :integer},
          "tenant_id" => %{type: :integer}
        },
        associations: %{
          line_items: %{
            queryable: :line_items,
            field: :line_items,
            owner_key: "id",
            related_key: "order_id"
          }
        }
      },
      schemas: %{
        line_items: %{
          source_table: "line_items",
          primary_key: "id",
          fields: ["id", "order_id", "tenant_id"],
          columns: %{
            "id" => %{type: :integer},
            "order_id" => %{type: :integer},
            "tenant_id" => %{type: :integer}
          },
          associations: %{}
        }
      },
      joins: %{
        line_items: %{
          non_assoc: true,
          source: "line_items",
          type: :left,
          owner_key: "id",
          related_key: "order_id",
          on: [
            %{left: "id", right: "order_id"},
            %{left: "tenant_id", right: "tenant_id"}
          ],
          fields: %{
            "line_items.id" => %{
              colid: "line_items.id",
              name: "Line item ID",
              field: "id",
              requires_join: :line_items,
              type: :integer
            }
          },
          joins: %{}
        }
      },
      default_selected: ["id"],
      filters: %{}
    }

    {sql, []} =
      domain
      |> Selecto.configure(:mock_connection)
      |> Selecto.select(["id", "line_items.id"])
      |> Selecto.to_sql()

    normalized = sql |> String.replace(~r/\s+/, " ") |> String.trim()

    assert normalized =~
             "left join line_items line_items on selecto_root.id = line_items.order_id and selecto_root.tenant_id = line_items.tenant_id"
  end
end
