defmodule Selecto.QueryEnhancementsTest do
  use ExUnit.Case, async: true

  defp domain do
    %{
      name: "Orders",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :order_number, :status, :total, :customer_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          order_number: %{type: :string},
          status: %{type: :string},
          total: %{type: :decimal},
          customer_id: %{type: :integer}
        },
        associations: %{
          order_items: %{
            queryable: :order_items,
            field: :order_items,
            owner_key: :id,
            related_key: :order_id
          }
        }
      },
      schemas: %{
        order_items: %{
          source_table: "order_items",
          primary_key: :id,
          fields: [:id, :order_id, :quantity],
          redact_fields: [],
          columns: %{
            id: %{type: :integer},
            order_id: %{type: :integer},
            quantity: %{type: :integer}
          },
          associations: %{}
        }
      },
      joins: %{
        order_items: %{
          type: :left,
          name: "order_items"
        }
      }
    }
  end

  defp product_domain do
    %{
      name: "Products",
      source: %{
        source_table: "products",
        primary_key: :id,
        fields: [:id, :name, :price, :metadata],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          price: %{type: :decimal},
          metadata: %{type: :json}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp selecto(domain_map),
    do: Selecto.configure(domain_map, [hostname: "localhost"], validate: false)

  test "to_sql supports pretty formatting and highlighting" do
    query =
      domain()
      |> selecto()
      |> Selecto.select(["order_number", "status", "total"])
      |> Selecto.filter({"status", "delivered"})
      |> Selecto.order_by({"total", :desc})

    {plain_sql, _plain_params} = Selecto.to_sql(query)
    {pretty_sql, _pretty_params} = Selecto.to_sql(query, pretty: true)
    {highlighted_sql, _hl_params} = Selecto.to_sql(query, pretty: true, highlight: :ansi)

    assert is_binary(plain_sql)
    assert String.starts_with?(pretty_sql, "SELECT")
    assert String.contains?(pretty_sql, "\nFROM")
    assert String.contains?(pretty_sql, "\nWHERE")
    assert String.contains?(highlighted_sql, "\e[")
  end

  test "pre_retarget_filter and post_retarget_filter address the context and the target" do
    query =
      domain()
      |> selecto()
      |> Selecto.pre_retarget_filter({"status", "delivered"})
      |> Selecto.retarget(:order_items)
      |> Selecto.post_retarget_filter({"quantity", {:gt, 2}})
      |> Selecto.pre_retarget_filter({"total", {:gt, 10}})

    assert Selecto.pre_retarget_filters(query) == [
             {"status", "delivered"},
             {"total", {:gt, 10}}
           ]

    assert Selecto.post_retarget_filters(query) == [{"quantity", {:gt, 2}}]
    assert query.set.filtered == [{"quantity", {:gt, 2}}]
  end

  test "post_retarget_filter resolves fields against the target root" do
    query =
      domain()
      |> selecto()
      |> Selecto.retarget(:order_items)

    assert_raise ArgumentError, ~r/order_items/, fn ->
      Selecto.post_retarget_filter(query, {"order_items.quantity", {:gt, 2}})
    end
  end

  test "filter after retarget validates against the target root" do
    query =
      domain()
      |> selecto()
      |> Selecto.retarget(:order_items)
      |> Selecto.filter({"quantity", 2})

    assert query.set.filtered == [{"quantity", 2}]
    assert Selecto.pre_retarget_filters(query) == []
  end

  test "query_filters exposes unified filters and refuses a retargeted query" do
    query =
      domain()
      |> selecto()
      |> Selecto.filter({"status", "delivered"})

    assert Selecto.query_filters(query) == [{"status", "delivered"}]
    assert Selecto.query_filters(query, include_post_retarget: false) == [{"status", "delivered"}]

    assert_raise ArgumentError, ~r/retarget context/, fn ->
      query |> Selecto.retarget(:order_items) |> Selecto.query_filters()
    end
  end

  test "missing field error includes computed alias hint" do
    query =
      product_domain()
      |> selecto()
      |> Selecto.json_select([{:json_extract_text, "metadata", "$.price_band", as: "price_band"}])
      |> Selecto.select(["price_band"])

    assert_raise RuntimeError, ~r/matches a computed alias/, fn ->
      Selecto.to_sql(query)
    end
  end

  test "select_shape expands json alias leaf into explicit field selector" do
    query =
      product_domain()
      |> selecto()
      |> Selecto.json_select([{:json_extract_text, "metadata", "$.price_band", as: "price_band"}])
      |> Selecto.select_shape(["name", "price_band"])

    assert {:field, "metadata.price_band", "price_band"} in query.set.selected
    assert "name" in query.set.selected
  end

  test "diagnostics builds EXPLAIN SQL with selected flags" do
    explain_sql =
      Selecto.Diagnostics.build_explain_sql(
        "SELECT 1",
        analyze: true,
        buffers: true,
        timing: false,
        format: :json
      )

    assert String.starts_with?(explain_sql, "EXPLAIN (")
    assert String.contains?(explain_sql, "ANALYZE")
    assert String.contains?(explain_sql, "BUFFERS")
    assert String.contains?(explain_sql, "TIMING false")
    assert String.contains?(explain_sql, "FORMAT JSON")
  end
end
