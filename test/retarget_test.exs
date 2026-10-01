defmodule Selecto.RetargetTest do
  use ExUnit.Case, async: true

  alias Selecto.Retarget

  defp relation(table, primary_key, columns, associations \\ %{}) do
    %{
      source_table: table,
      primary_key: primary_key,
      fields: Map.keys(columns),
      redact_fields: [],
      columns: Map.new(columns, fn {name, type} -> {name, %{type: type}} end),
      associations: associations
    }
  end

  defp association(queryable, owner_key, related_key) do
    %{queryable: queryable, field: queryable, owner_key: owner_key, related_key: related_key}
  end

  def domain do
    %{
      name: "Events",
      source:
        relation(
          "events",
          :event_id,
          %{event_id: :integer, name: :string, region: :string, tenant_id: :integer},
          %{attendees: association(:attendees, :event_id, :event_id)}
        ),
      schemas: %{
        attendees:
          relation(
            "attendees",
            :attendee_id,
            %{attendee_id: :integer, event_id: :integer, name: :string},
            %{orders: association(:orders, :attendee_id, :attendee_id)}
          ),
        orders:
          relation(
            "orders",
            :order_id,
            %{order_id: :integer, attendee_id: :integer, product_id: :integer, total: :decimal},
            %{product: %{association(:products, :product_id, :product_id) | field: :product}}
          ),
        products: relation("products", :product_id, %{product_id: :integer, name: :string})
      },
      joins: %{
        attendees: %{
          type: :left,
          name: "Attendees",
          joins: %{
            orders: %{
              type: :left,
              name: "Orders",
              joins: %{product: %{type: :left, name: "Product"}}
            }
          }
        }
      }
    }
  end

  defp configure(domain \\ domain()) do
    Selecto.configure(
      domain,
      Selecto.Runtime.Context.new(SelectoDBPostgreSQL.Adapter, :compile_only)
    )
  end

  defp sql(selecto) do
    {sql, params} = Selecto.to_sql(selecto)
    {String.replace(sql, ~r/\s+/, " "), params}
  end

  defp error_code(fun) do
    fun.()
    :ok
  rescue
    error in Retarget.Error -> error.code
  end

  describe "retarget/3" do
    test "roots the query at the target relation and keeps the origin as context" do
      origin = configure() |> Selecto.filter({"region", "west"})
      retargeted = Selecto.retarget(origin, "attendees.orders")

      assert Retarget.has_retarget?(retargeted)
      refute Retarget.has_retarget?(origin)
      assert Selecto.source_table(retargeted) == "orders"

      assert %{path: "attendees.orders", join: :orders, primary_key: :order_id, strategy: :in} =
               Retarget.get_retarget_config(retargeted)

      assert Retarget.reset_retarget(retargeted) == origin
    end

    test "a join id resolves to its path in the join tree" do
      assert Retarget.get_retarget_config(Selecto.retarget(configure(), :orders)).path ==
               "attendees.orders"
    end

    test "compiles the context as a subquery over the original joins" do
      {sql, params} =
        configure()
        |> Selecto.filter({"region", "west"})
        |> Selecto.filter({"attendees.name", "Ann"})
        |> Selecto.retarget("attendees.orders")
        |> Selecto.select(["order_id", "total", "product.name"])
        |> Selecto.filter({"total", {:gt, 10}})
        |> Selecto.order_by([{:desc, "total"}])
        |> Selecto.limit(5)
        |> sql()

      assert sql =~ "from orders selecto_root left join products product"
      assert sql =~ "selecto_root.total > $1"

      assert sql =~
               "selecto_root.order_id in ( select orders.order_id from events subq_root_events " <>
                 "left join attendees attendees"

      assert sql =~ "attendees.name = $3"
      assert sql =~ "order by selecto_root.total desc"
      assert sql =~ "limit 5"
      assert params == [10, "west", "Ann"]
    end

    test "the exists strategy correlates the context with the target key" do
      {sql, _params} =
        configure()
        |> Selecto.filter({"region", "west"})
        |> Selecto.retarget(:orders, strategy: :exists)
        |> Selecto.select(["order_id"])
        |> sql()

      assert sql =~
               "exists (select 1 from ( select orders.order_id from events selecto_root"

      assert sql =~ "selecto_retarget_context.order_id = selecto_root.order_id"
    end

    test "groups and aggregates at the target grain" do
      {sql, _params} =
        configure()
        |> Selecto.retarget(:orders)
        |> Selecto.select(["product.name", {:count, "*"}])
        |> Selecto.group_by(["product.name"])
        |> sql()

      assert sql =~ "group by product.name"
      assert sql =~ "from orders selecto_root"
    end
  end

  describe "context and target filters" do
    test "pre_retarget_filter adds to the context and post_retarget_filter to the target" do
      retargeted =
        configure()
        |> Selecto.retarget(:orders)
        |> Selecto.pre_retarget_filter({"region", "east"})
        |> Selecto.post_retarget_filter({"total", {:gt, 5}})

      assert Selecto.pre_retarget_filters(retargeted) == [{"region", "east"}]
      assert Selecto.post_retarget_filters(retargeted) == [{"total", {:gt, 5}}]
      {sql, params} = retargeted |> Selecto.select(["order_id"]) |> sql()
      assert sql =~ "subq_root_events.region = $2"
      assert params == [5, "east"]
    end

    test "a query that has not been retargeted has no target to filter" do
      assert_raise ArgumentError, ~r/requires a retargeted query/, fn ->
        Selecto.post_retarget_filter(configure(), {"region", "west"})
      end

      assert Selecto.post_retarget_filters(configure()) == []
    end

    test "query filters refuse a retargeted query so it cannot scope writes" do
      assert_raise ArgumentError, ~r/retarget context/, fn ->
        configure() |> Selecto.retarget(:orders) |> Selecto.query_filters()
      end
    end
  end

  describe "rejections" do
    test "unknown joins, repeated retargets, and unknown options fail closed" do
      assert error_code(fn -> Selecto.retarget(configure(), :nowhere) end) == :unknown_association

      assert error_code(fn -> Selecto.retarget(configure(), "orders.attendees") end) ==
               :unknown_association

      assert error_code(fn ->
               configure() |> Selecto.retarget(:orders) |> Selecto.retarget(:product)
             end) == :invalid_query

      assert error_code(fn -> Selecto.retarget(configure(), :orders, strategy: :join) end) ==
               :invalid_query

      assert error_code(fn -> Selecto.retarget(configure(), :orders, preserve_filters: false) end) ==
               :invalid_query
    end

    test "declared targets form an allow-list" do
      governed =
        Map.put(domain(), :retarget, %{targets: %{"attendees.orders" => %{label: "Orders"}}})
        |> configure()

      assert Retarget.get_retarget_config(Selecto.retarget(governed, :orders)).path ==
               "attendees.orders"

      assert error_code(fn -> Selecto.retarget(governed, :attendees) end) ==
               :retarget_not_allowed

      invalid_default =
        Map.put(domain(), :retarget, %{
          targets: %{"attendees.orders" => %{}},
          default_target: "attendees"
        })
        |> configure()

      assert error_code(fn -> Selecto.retarget(invalid_default, :orders) end) ==
               :invalid_retarget
    end
  end

  describe "tenant scope" do
    defp tenant_domain do
      domain()
      |> put_in([:source, :tenant_field], :tenant_id)
      |> put_in([:schemas, :orders, :tenant_field], :tenant_id)
      |> update_in([:schemas, :orders], fn orders ->
        %{
          orders
          | fields: [:tenant_id | orders.fields],
            columns: Map.put(orders.columns, :tenant_id, %{type: :integer})
        }
      end)
    end

    test "the root tenant is carried to a tenant-scoped target" do
      {sql, params} =
        tenant_domain()
        |> configure()
        |> Selecto.Tenant.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
        |> Selecto.Tenant.apply_tenant_scope()
        |> Selecto.retarget(:orders)
        |> Selecto.select(["order_id"])
        |> sql()

      assert sql =~ "selecto_root.tenant_id = $1"
      assert sql =~ "subq_root_events.tenant_id = $2"
      assert params == [7, 7]
    end

    test "a retarget before any filter keeps domain required filters and the tenant" do
      {sql, params} =
        tenant_domain()
        |> Map.put(:required_filters, [{"region", "west"}])
        |> configure()
        |> Selecto.Tenant.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
        |> Selecto.Tenant.apply_tenant_scope()
        |> Selecto.retarget(:orders)
        |> Selecto.filter({"total", {:gt, 5}})
        |> Selecto.select(["order_id"])
        |> sql()

      assert sql =~ "selecto_root.tenant_id = $1"
      assert sql =~ "selecto_root.total > $2"
      assert sql =~ "subq_root_events.region = $3"
      assert sql =~ "subq_root_events.tenant_id = $4"
      assert params == [7, 5, "west", 7]
    end

    test "an attached tenant that was never applied still fails closed after a retarget" do
      for target <- [:orders, :product] do
        retargeted =
          tenant_domain()
          |> configure()
          |> Selecto.Tenant.with_tenant(%{tenant_id: 7, tenant_field: "tenant_id"})
          |> Selecto.retarget(target)
          |> Selecto.Tenant.apply_tenant_scope()

        assert_raise RuntimeError, ~r/Tenant scope is required but missing/, fn ->
          Selecto.to_sql(retargeted)
        end
      end
    end

    test "a scope that cannot reach a tenant-scoped target fails closed" do
      scoped =
        tenant_domain()
        |> configure()
        |> Selecto.Tenant.require_tenant_filter({"region", "west"})

      assert error_code(fn -> Selecto.retarget(scoped, :orders) end) == :missing_tenant_scope
    end

    test "a target without a tenant field is bounded by the context" do
      {sql, _params} =
        tenant_domain()
        |> configure()
        |> Selecto.Tenant.require_tenant_filter({"tenant_id", 7})
        |> Selecto.retarget(:product)
        |> Selecto.select(["name"])
        |> sql()

      assert sql =~ "from products selecto_root where"
      refute sql =~ "selecto_root.tenant_id"
      assert sql =~ "subq_root_events.tenant_id = $1"
    end
  end

  describe "join paths" do
    test "calculate_join_path follows the join tree" do
      assert Retarget.calculate_join_path(configure(), :orders) == {:ok, [:attendees, :orders]}
      assert {:error, _} = Retarget.calculate_join_path(configure(), :nowhere)
    end

    test "validate_retarget_path checks each association" do
      assert Retarget.validate_retarget_path(configure(), [:attendees, :orders]) == :ok
      assert {:error, _} = Retarget.validate_retarget_path(configure(), [:orders])
    end
  end
end
