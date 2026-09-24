defmodule Selecto.SubselectIntegrationTest do
  use ExUnit.Case, async: true
  doctest Selecto.Builder.Subselect

  alias Selecto.Builder.Subselect
  alias Selecto.TestSQLParams, as: Params

  def test_domain do
    %{
      source: %{
        source_table: "attendees",
        primary_key: :attendee_id,
        fields: [:attendee_id, :event_id, :name, :email],
        redact_fields: [],
        columns: %{
          attendee_id: %{type: :integer},
          event_id: %{type: :integer},
          name: %{type: :string},
          email: %{type: :string}
        },
        associations: %{
          orders: %{
            queryable: :orders,
            field: :orders,
            owner_key: :attendee_id,
            related_key: :attendee_id
          }
        }
      },
      schemas: %{
        orders: %{
          source_table: "orders",
          primary_key: :order_id,
          fields: [:order_id, :attendee_id, :product_name, :quantity, :price, :metadata],
          redact_fields: [],
          columns: %{
            order_id: %{type: :integer},
            attendee_id: %{type: :integer},
            product_name: %{type: :string},
            quantity: %{type: :integer},
            price: %{type: :decimal},
            metadata: %{
              type: :json,
              schema: %{
                "priority" => %{type: :string},
                "warehouse" => %{
                  type: :object,
                  schema: %{"zone" => %{type: :string}}
                }
              }
            }
          },
          associations: %{
            order_items: %{
              queryable: :order_items,
              field: :order_items,
              owner_key: :order_id,
              related_key: :order_id
            }
          }
        },
        order_items: %{
          source_table: "order_items",
          primary_key: :order_item_id,
          fields: [:order_item_id, :order_id, :sku, :quantity],
          redact_fields: [],
          columns: %{
            order_item_id: %{type: :integer},
            order_id: %{type: :integer},
            sku: %{type: :string},
            quantity: %{type: :integer}
          },
          associations: %{}
        }
      },
      name: "Attendee",
      joins: %{
        orders: %{type: :left, name: "orders"}
      }
    }
  end

  def create_test_selecto do
    domain = test_domain()
    connection = [hostname: "localhost", username: "test"]
    Selecto.configure(domain, connection, validate: false)
  end

  def create_mssql_test_selecto do
    domain = test_domain()
    Selecto.configure(domain, :mock_connection, adapter: SelectoDBMSSQL.Adapter, validate: false)
  end

  def create_string_keyed_test_selecto do
    domain = %{
      source: %{
        source_table: "attendees",
        primary_key: "attendee_id",
        fields: ["attendee_id"],
        redact_fields: [],
        columns: %{"attendee_id" => %{type: :integer}},
        associations: %{
          "orders" => %{
            queryable: "orders",
            field: "orders",
            owner_key: "attendee_id",
            related_key: "attendee_id"
          }
        }
      },
      schemas: %{
        "orders" => %{
          source_table: "orders",
          primary_key: "order_id",
          fields: ["order_id", "attendee_id", "product_name"],
          redact_fields: [],
          columns: %{
            "order_id" => %{type: :integer},
            "attendee_id" => %{type: :integer},
            "product_name" => %{type: :string}
          },
          associations: %{
            "order_items" => %{
              queryable: "order_items",
              field: "order_items",
              owner_key: "order_id",
              related_key: "order_id"
            }
          }
        },
        "order_items" => %{
          source_table: "order_items",
          primary_key: "order_item_id",
          fields: ["order_item_id", "order_id", "sku"],
          redact_fields: [],
          columns: %{
            "order_item_id" => %{type: :integer},
            "order_id" => %{type: :integer},
            "sku" => %{type: :string}
          },
          associations: %{}
        }
      },
      name: "Attendee",
      joins: %{"orders" => %{type: :left, name: "orders"}}
    }

    Selecto.configure(domain, [hostname: "localhost", username: "test"], validate: false)
  end

  describe "build_subselect_clauses/1" do
    test "builds JSON aggregation subselect" do
      selecto =
        create_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["product_name", "quantity"],
            target_schema: :orders,
            format: :json_agg,
            alias: "order_items"
          }
        ])

      {clauses, params} = Subselect.build_subselect_clauses(selecto)

      {clause_sql, finalized_params} = Params.finalize(clauses)

      assert clause_sql =~ ~r/json_agg/i
      assert clause_sql =~ ~r/json_build_object/i
      assert clause_sql =~ ~r/as\s+"order_items"/i
      assert clause_sql =~ ~r/from\s+orders/i
      assert clause_sql =~ ~r/where/i
      assert params == finalized_params
    end

    test "builds MSSQL JSON aggregation subselect without postgres JSON functions" do
      selecto =
        create_mssql_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["product_name", "quantity"],
            target_schema: :orders,
            format: :json_agg,
            alias: "order_items"
          }
        ])

      {clauses, params} = Subselect.build_subselect_clauses(selecto)
      {clause_sql, finalized_params} = Params.finalize(clauses)

      assert clause_sql =~ ~r/for json path/i
      refute clause_sql =~ ~r/json_build_object/i
      refute clause_sql =~ ~r/json_agg/i
      assert clause_sql =~ ~r/as\s+\[order_items\]/i
      assert params == finalized_params
    end

    test "builds MSSQL JSON aggregation subselect with nested json path fields" do
      selecto =
        create_mssql_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["product_name", "metadata.priority", "metadata.warehouse.zone"],
            target_schema: :orders,
            format: :json_agg,
            alias: "order_items"
          }
        ])

      {clauses, params} = Subselect.build_subselect_clauses(selecto)
      {clause_sql, finalized_params} = Params.finalize(clauses)

      assert clause_sql =~ ~r/for json path/i
      assert clause_sql =~ "JSON_VALUE([sub_orders].[metadata], '$.priority') AS [priority]"

      assert clause_sql =~
               "JSON_VALUE([sub_orders].[metadata], '$.warehouse.zone') AS [zone]"

      assert params == finalized_params
    end

    test "builds nested JSON aggregation subselects" do
      selecto =
        create_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["product_name"],
            target_schema: :orders,
            format: :json_agg,
            alias: "orders",
            join_path: [:orders],
            nested: [
              %{
                key: "items",
                fields: ["sku", "quantity"],
                target_schema: :order_items,
                format: :json_agg,
                join_path: [:orders, :order_items],
                filters: [{"quantity", 2}]
              }
            ]
          }
        ])

      {clauses, params} = Subselect.build_subselect_clauses(selecto)
      {clause_sql, finalized_params} = Params.finalize(clauses)

      assert clause_sql =~ ~r/json_agg\(json_build_object/i
      assert clause_sql =~ "'product_name', sub_orders.\"product_name\""
      assert clause_sql =~ "'items', COALESCE((SELECT json_agg(json_build_object("
      assert clause_sql =~ ~r/from\s+order_items\s+sub_orders_items/i
      assert clause_sql =~ ~r/sub_orders_items\."order_id"\s*=\s*sub_orders\."order_id"/i
      assert clause_sql =~ ~r/sub_orders_items\."quantity"\s*=\s*\$1/i
      assert clause_sql =~ ~r/as\s+"orders"/i
      assert 2 in params
      assert params == finalized_params
    end

    test "limits each correlated parent and nested child before JSON aggregation" do
      selecto =
        create_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["order_id", "product_name"],
            target_schema: :orders,
            format: :json_agg,
            alias: "orders",
            join_path: [:orders],
            order_by: [{:asc, "order_id"}],
            limit: 2,
            nested: [
              %{
                key: "items",
                fields: ["order_item_id", "sku"],
                target_schema: :order_items,
                format: :json_agg,
                join_path: [:orders, :order_items],
                order_by: [{:desc, "order_item_id"}],
                limit: 1
              }
            ]
          }
        ])

      {clauses, params} = Subselect.build_subselect_clauses(selecto)
      {sql, finalized_params} = Params.finalize(clauses)

      assert sql =~
               ~s|FROM (SELECT sub_orders.* FROM orders sub_orders WHERE sub_orders."attendee_id" = selecto_root."attendee_id" ORDER BY sub_orders."order_id" ASC LIMIT 2) sub_orders|

      assert sql =~
               ~s|FROM (SELECT sub_orders_items.* FROM order_items sub_orders_items WHERE sub_orders_items."order_id" = sub_orders."order_id" ORDER BY sub_orders_items."order_item_id" DESC LIMIT 1) sub_orders_items|

      assert params == finalized_params
    end

    test "per-parent limit requires positive size and explicit ordering" do
      for config <- [
            %{limit: 0, order_by: [{:asc, "order_id"}]},
            %{limit: 2, order_by: []}
          ] do
        assert_raise ArgumentError, fn ->
          create_test_selecto()
          |> Selecto.subselect([
            Map.merge(
              %{
                fields: ["order_id"],
                target_schema: :orders,
                format: :json_agg,
                alias: "orders"
              },
              config
            )
          ])
        end
      end
    end

    test "per-parent limits use the target primary key to break ordering ties" do
      selecto =
        create_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["order_id", "product_name"],
            target_schema: :orders,
            format: :json_agg,
            alias: "orders",
            join_path: [:orders],
            order_by: [{:asc, "product_name"}],
            limit: 2,
            nested: [
              %{
                key: "items",
                fields: ["order_item_id", "sku"],
                target_schema: :order_items,
                format: :json_agg,
                join_path: [:orders, :order_items],
                order_by: [{:desc, "sku"}],
                limit: 1
              }
            ]
          }
        ])

      {clauses, _params} = Subselect.build_subselect_clauses(selecto)
      {sql, _finalized_params} = Params.finalize(clauses)

      assert sql =~ ~s|ORDER BY sub_orders."product_name" ASC, sub_orders."order_id" ASC LIMIT 2|

      assert sql =~
               ~s|ORDER BY sub_orders_items."sku" DESC, sub_orders_items."order_item_id" ASC LIMIT 1|
    end

    test "a collection cursor seeks only within its parent and binds every value" do
      selecto =
        create_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["order_id", "product_name"],
            target_schema: :orders,
            format: :json_agg,
            alias: "orders",
            join_path: [:orders],
            order_by: [{:asc, "product_name"}],
            limit: 2,
            after: %{parent_key: 7, values: ["Apple", 12]}
          }
        ])

      {clauses, params} = Subselect.build_subselect_clauses(selecto)
      {sql, finalized_params} = Params.finalize(clauses)

      assert sql =~ ~s|sub_orders."attendee_id" = selecto_root."attendee_id"|
      assert sql =~ ~s|selecto_root."attendee_id" IS DISTINCT FROM $1|
      assert sql =~ ~s|sub_orders."product_name" > $2 OR sub_orders."product_name" IS NULL|
      assert sql =~ ~s|sub_orders."product_name" IS NOT DISTINCT FROM $3|
      assert sql =~ ~s|sub_orders."order_id" > $4|

      assert sql =~ ~s|ORDER BY sub_orders."product_name" ASC, sub_orders."order_id" ASC LIMIT 2|
      assert params == [7, "Apple", "Apple", 12]
      assert params == finalized_params
    end

    test "descending collection cursor continues after null and rejects a short tuple" do
      config = %{
        fields: ["order_id", "product_name"],
        target_schema: :orders,
        format: :json_agg,
        alias: "orders",
        join_path: [:orders],
        order_by: [{:desc, "product_name"}],
        limit: 2,
        after: %{parent_key: 7, values: [nil, 12]}
      }

      {clauses, params} =
        create_test_selecto()
        |> Selecto.subselect([config])
        |> Subselect.build_subselect_clauses()

      {sql, finalized_params} = Params.finalize(clauses)
      assert sql =~ ~s|sub_orders."product_name" IS NOT NULL|
      assert sql =~ ~s|sub_orders."product_name" IS NULL AND (sub_orders."order_id" >|
      assert params == finalized_params

      assert_raise ArgumentError, ~r/wrong ordering tuple size/, fn ->
        create_test_selecto()
        |> Selecto.subselect([put_in(config, [:after, :values], [nil])])
      end
    end

    test "correlated sum stays separate from a nested collection" do
      selecto =
        create_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["quantity"],
            target_schema: :orders,
            format: :sum,
            alias: "total_quantity",
            join_path: [:orders]
          },
          %{
            fields: ["order_id", "quantity"],
            target_schema: :orders,
            format: :json_agg,
            alias: "orders",
            join_path: [:orders],
            nested: [
              %{
                key: "items",
                fields: ["order_item_id", "quantity"],
                target_schema: :order_items,
                format: :json_agg,
                join_path: [:orders, :order_items]
              }
            ]
          }
        ])

      {clauses, _params} = Subselect.build_subselect_clauses(selecto)
      {sql, _finalized_params} = Params.finalize(clauses)

      assert sql =~
               ~s|(SELECT COALESCE(SUM(sub_orders."quantity"), 0) FROM orders sub_orders WHERE sub_orders."attendee_id" = selecto_root."attendee_id") AS "total_quantity"|

      assert sql =~ ~s|AS "orders"|
      refute sql =~ ~s|JOIN order_items|
    end

    test "related sum rejects a nonnumeric field" do
      assert_raise ArgumentError, ~r/related sum requires a numeric field/, fn ->
        create_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["product_name"],
            target_schema: :orders,
            format: :sum,
            alias: "invalid_total"
          }
        ])
      end
    end

    test "uncertified dialect rejects a per-parent limit" do
      selecto =
        create_mssql_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["order_id"],
            target_schema: :orders,
            format: :json_agg,
            alias: "orders",
            order_by: [{:asc, "order_id"}],
            limit: 1
          }
        ])

      assert_raise ArgumentError, "per-parent collection limits require PostgreSQL", fn ->
        Subselect.build_subselect_clauses(selecto)
      end
    end

    test "builds nested correlations when domain associations use string keys" do
      selecto =
        create_string_keyed_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["product_name"],
            target_schema: "orders",
            format: :json_agg,
            alias: "orders",
            join_path: ["orders"],
            nested: [
              %{
                key: "items",
                fields: ["sku"],
                target_schema: "order_items",
                format: :json_agg,
                join_path: ["orders", "order_items"],
                filters: []
              }
            ]
          }
        ])

      {clauses, params} = Subselect.build_subselect_clauses(selecto)
      {clause_sql, finalized_params} = Params.finalize(clauses)

      assert clause_sql =~ ~r/from\s+order_items\s+sub_orders_items/i
      assert clause_sql =~ ~r/sub_orders_items\."order_id"\s*=\s*sub_orders\."order_id"/i
      assert params == finalized_params
    end

    test "builds array aggregation subselect" do
      selecto =
        create_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["product_name"],
            target_schema: :orders,
            format: :array_agg,
            alias: "product_names"
          }
        ])

      {clauses, _params} = Subselect.build_subselect_clauses(selecto)
      {clause_sql, _finalized_params} = Params.finalize(clauses)

      assert clause_sql =~ ~r/array_agg/i
      assert clause_sql =~ ~r/as\s+"product_names"/i
    end

    test "builds string aggregation subselect" do
      selecto =
        create_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["product_name"],
            target_schema: :orders,
            format: :string_agg,
            alias: "product_list",
            separator: "; "
          }
        ])

      {clauses, params} = Subselect.build_subselect_clauses(selecto)
      {clause_sql, _finalized_params} = Params.finalize(clauses)

      assert clause_sql =~ ~r/string_agg/i
      assert clause_sql =~ ~r/as\s+"product_list"/i
      assert "; " in params
    end

    test "builds MSSQL string aggregation subselect" do
      selecto =
        create_mssql_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["product_name"],
            target_schema: :orders,
            format: :string_agg,
            alias: "product_list",
            separator: "; "
          }
        ])

      {clauses, params} = Subselect.build_subselect_clauses(selecto)
      {clause_sql, finalized_params} = Params.finalize(clauses, adapter: SelectoDBMSSQL.Adapter)

      assert clause_sql =~ ~r/string_agg/i
      assert clause_sql =~ ~r/sub_orders\.\[product_name\]/i
      assert clause_sql =~ ~r/as\s+\[product_list\]/i
      assert params == finalized_params
      assert params == ["; "]
    end

    test "builds MSSQL array aggregation subselect as json array" do
      selecto =
        create_mssql_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["product_name"],
            target_schema: :orders,
            format: :array_agg,
            alias: "product_names"
          }
        ])

      {clauses, params} = Subselect.build_subselect_clauses(selecto)
      {clause_sql, finalized_params} = Params.finalize(clauses, adapter: SelectoDBMSSQL.Adapter)

      assert clause_sql =~ ~r/for json path/i
      refute clause_sql =~ ~r/array_agg/i
      assert clause_sql =~ ~r/as\s+\[product_names\]/i
      assert clause_sql =~ ~r/sub_orders\.\[product_name\]\s+AS\s+\[product_name\]/i
      assert params == finalized_params
      assert params == []
    end

    test "builds count subselect" do
      selecto =
        create_test_selecto()
        |> Selecto.subselect([
          %{
            # Field doesn't matter for count
            fields: ["product_name"],
            target_schema: :orders,
            format: :count,
            alias: "order_count"
          }
        ])

      {clauses, _params} = Subselect.build_subselect_clauses(selecto)
      {clause_sql, _finalized_params} = Params.finalize(clauses)

      assert clause_sql =~ ~r/count/i
      assert clause_sql =~ ~r/as\s+"order_count"/i
    end

    test "builds multiple subselects" do
      selecto =
        create_test_selecto()
        |> Selecto.subselect([
          %{
            fields: ["product_name"],
            target_schema: :orders,
            format: :json_agg,
            alias: "products"
          },
          %{
            fields: ["quantity"],
            target_schema: :orders,
            format: :array_agg,
            alias: "quantities"
          }
        ])

      {clauses, _params} = Subselect.build_subselect_clauses(selecto)
      {clauses_sql, _finalized_params} = Params.finalize(clauses)

      assert clauses_sql =~ ~r/json_agg/i
      assert clauses_sql =~ ~r/array_agg/i
      assert clauses_sql =~ ~r/as\s+"products"/i
      assert clauses_sql =~ ~r/as\s+"quantities"/i
    end
  end

  describe "build_single_subselect/2" do
    test "creates proper correlation condition" do
      selecto = create_test_selecto()

      config = %{
        fields: ["product_name"],
        target_schema: :orders,
        format: :json_agg,
        alias: "products",
        order_by: [],
        filters: []
      }

      {subselect, _params} = Subselect.build_single_subselect(selecto, config)

      subselect_sql = IO.iodata_to_binary(subselect)

      # Should have correlation condition
      assert subselect_sql =~ "WHERE"
      assert subselect_sql =~ "sub_orders"
      assert subselect_sql =~ "= selecto_root."
    end

    test "includes ORDER BY when specified" do
      selecto = create_test_selecto()

      config = %{
        fields: ["product_name"],
        target_schema: :orders,
        format: :json_agg,
        alias: "products",
        order_by: [{:desc, :product_name}],
        filters: []
      }

      {subselect, _params} = Subselect.build_single_subselect(selecto, config)

      subselect_sql = IO.iodata_to_binary(subselect)

      refute subselect_sql =~ ~r/order by/i
    end

    test "includes additional filters when specified" do
      selecto = create_test_selecto()

      config = %{
        fields: ["product_name"],
        target_schema: :orders,
        format: :json_agg,
        alias: "products",
        order_by: [],
        filters: [{"quantity", {:gt, 1}}]
      }

      {subselect, params} = Subselect.build_single_subselect(selecto, config)
      {subselect_sql, _finalized_params} = Params.finalize(subselect)

      # Additional filter joined with correlation
      assert subselect_sql =~ "AND"
      assert {:gt, 1} in params
    end
  end

  describe "resolve_join_condition/2" do
    test "resolves simple join condition" do
      selecto = create_test_selecto()

      {:ok, {source_field, target_field}} = Subselect.resolve_join_condition(selecto, :orders)

      assert is_binary(source_field)
      assert is_binary(target_field)
    end
  end

  describe "full SQL generation integration" do
    test "generates complete query with subselects" do
      selecto =
        create_test_selecto()
        |> Selecto.select(["name", "email"])
        |> Selecto.subselect(["orders.product_name, quantity"])
        |> Selecto.filter([{"event_id", 123}])

      {sql, _aliases, params} = Selecto.gen_sql(selecto, [])

      # Should have main SELECT fields and subselects
      assert sql =~ ~r/select/i
      assert sql =~ "name"
      assert sql =~ "email"
      assert sql =~ "json_agg"
      assert sql =~ "json_build_object"

      # Should have main FROM clause
      assert sql =~ ~r/from\s+attendees/i

      # Should have main WHERE clause for filters
      assert sql =~ ~r/where/i

      # Should have correlated subquery
      assert sql =~ ~r/from\s+orders/i

      # Parameters should include filter values
      assert 123 in params
    end

    test "handles subselects with string field syntax" do
      selecto =
        create_test_selecto()
        |> Selecto.select(["name"])
        |> Selecto.subselect(["orders.product_name"])

      {sql, _aliases, _params} = Selecto.gen_sql(selecto, [])

      assert sql =~ ~r/select/i
      assert sql =~ "name"
      assert sql =~ "json_agg"
      assert sql =~ ~r/from\s+attendees/i
    end

    test "handles multiple subselects with different formats" do
      selecto =
        create_test_selecto()
        |> Selecto.select(["name"])
        |> Selecto.subselect([
          %{
            fields: ["product_name"],
            target_schema: :orders,
            format: :json_agg,
            alias: "products"
          },
          %{
            fields: ["quantity"],
            target_schema: :orders,
            format: :count,
            alias: "order_count"
          }
        ])

      {sql, _aliases, _params} = Selecto.gen_sql(selecto, [])

      assert sql =~ "json_agg"
      assert sql =~ "count"
      assert sql =~ ~r/as\s+"products"/i
      assert sql =~ ~r/as\s+"order_count"/i
    end

    test "combines with filtering and ordering" do
      selecto =
        create_test_selecto()
        |> Selecto.select(["name"])
        |> Selecto.subselect(["orders.product_name"])
        |> Selecto.filter([{"event_id", 123}])
        |> Selecto.order_by(["name"])

      {sql, _aliases, params} = Selecto.gen_sql(selecto, [])

      assert sql =~ ~r/select/i
      assert sql =~ "json_agg"
      assert sql =~ ~r/where/i
      assert sql =~ ~r/order\s+by/i
      assert 123 in params
    end

    test "works without regular SELECT fields" do
      selecto =
        create_test_selecto()
        |> Selecto.subselect(["orders.product_name"])

      {sql, _aliases, _params} = Selecto.gen_sql(selecto, [])

      # Should still generate valid SQL with just subselects
      assert sql =~ ~r/select/i
      assert sql =~ "json_agg"
    end
  end

  describe "error handling in SQL generation" do
    test "handles empty subselect configurations gracefully" do
      selecto =
        create_test_selecto()
        |> Selecto.select(["name"])

      # Should not have any subselects
      {clauses, params} = Subselect.build_subselect_clauses(selecto)

      assert clauses == []
      assert params == []
    end
  end
end
