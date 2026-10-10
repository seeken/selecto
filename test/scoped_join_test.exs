defmodule Selecto.ScopedJoinTest do
  use ExUnit.Case, async: true

  test "adds the association tenant scope to a direct join" do
    query =
      scoped_domain()
      |> Selecto.configure(:mock_connection)
      |> Selecto.select(["id", "customer.company_name"])

    {sql, []} = Selecto.to_sql(query)

    assert sql =~
             "customer.id = selecto_root.customer_id and selecto_root.tenant_id = customer.tenant_id"
  end

  test "adds the association tenant scope to a correlated collection subselect" do
    query =
      scoped_domain()
      |> Selecto.configure(:mock_connection)
      |> Selecto.select(["id"])
      |> Selecto.subselect([
        %{
          fields: ["id", "company_name"],
          target_schema: :customers,
          format: :json_agg,
          alias: "customers",
          join_path: [:customer]
        }
      ])

    {sql, []} = Selecto.to_sql(query)

    assert sql =~
             ~s(sub_customers."id" = selecto_root."customer_id" AND sub_customers."tenant_id" = selecto_root."tenant_id")
  end

  test "rejects an association with only one scope key even when validation is disabled" do
    domain =
      update_in(
        scoped_domain(),
        [:source, :associations, :customer],
        &Map.delete(&1, :target_scope_key)
      )

    assert_raise ArgumentError, ~r/requires both :source_scope_key and :target_scope_key/, fn ->
      Selecto.configure(domain, :mock_connection, validate: false)
    end

    assert {:error, errors} = Selecto.DomainValidator.validate_domain(domain)
    assert {:association_scope_incomplete, {:source, :customer}} in errors
  end

  test "rejects an association scope key that is not a declared field" do
    domain =
      put_in(
        scoped_domain(),
        [:source, :associations, :customer, :target_scope_key],
        :missing_tenant
      )

    assert_raise ArgumentError, ~r/target scope field :missing_tenant is not declared/, fn ->
      Selecto.configure(domain, :mock_connection, validate: false)
    end

    assert {:error, errors} = Selecto.DomainValidator.validate_domain(domain)

    assert {:association_scope_field_missing, {:source, :customer, :target, :missing_tenant}} in errors
  end

  test "declared tenant fields guard a join with differently named tenant columns" do
    query =
      inferred_domain()
      |> Selecto.configure(:mock_connection)
      |> Selecto.select(["id", "customer.company_name"])

    {sql, []} = Selecto.to_sql(query)

    assert sql =~
             "customer.id = selecto_root.customer_id and selecto_root.tenant_id = customer.organization_id"
  end

  test "explicit association scope remains authoritative over declared tenant defaults" do
    domain =
      inferred_domain()
      |> put_in([:source, :associations, :customer, :source_scope_key], :id)
      |> put_in([:source, :associations, :customer, :target_scope_key], :id)

    query =
      Selecto.configure(domain, :mock_connection) |> Selecto.select(["customer.company_name"])

    {sql, []} = Selecto.to_sql(query)
    assert sql =~ "selecto_root.id = customer.id"
    refute sql =~ "selecto_root.tenant_id = customer.organization_id"
  end

  test "an intentionally tenantless target keeps its ordinary join" do
    domain = update_in(inferred_domain(), [:schemas, :customers], &Map.delete(&1, :tenant_field))

    query =
      Selecto.configure(domain, :mock_connection) |> Selecto.select(["customer.company_name"])

    {sql, []} = Selecto.to_sql(query)
    assert sql =~ "customer.id = selecto_root.customer_id"
    refute sql =~ "selecto_root.tenant_id = customer.organization_id"
  end

  test "tenant inference cannot complete a partially authored scope or use an undeclared field" do
    for key <- [:source_scope_key, :target_scope_key] do
      domain = put_in(inferred_domain(), [:source, :associations, :customer, key], :id)

      assert_raise ArgumentError, ~r/requires both :source_scope_key and :target_scope_key/, fn ->
        Selecto.configure(domain, :mock_connection, validate: false)
      end
    end

    domain = put_in(inferred_domain(), [:schemas, :customers, :tenant_field], :not_declared)

    assert_raise ArgumentError, ~r/target scope field :not_declared is not declared/, fn ->
      Selecto.configure(domain, :mock_connection, validate: false)
    end
  end

  test "correlated JSON and count infer scope through an association alias" do
    for format <- [:json_agg, :count] do
      query = correlated_query(inferred_domain(), format)
      {sql, []} = Selecto.to_sql(query)

      assert sql =~
               ~s(sub_customers."id" = selecto_root."customer_id" AND sub_customers."organization_id" = selecto_root."tenant_id")
    end
  end

  test "correlated explicit scope overrides inferred scope and preserves filter binds" do
    domain =
      inferred_domain()
      |> put_in([:source, :associations, :customer, :source_scope_key], :id)
      |> put_in([:source, :associations, :customer, :target_scope_key], :id)

    query = correlated_query(domain, :json_agg, filters: [{"company_name", "Owned"}])
    {sql, ["Owned"]} = Selecto.to_sql(query)
    assert sql =~ ~s(sub_customers."id" = selecto_root."id")
    refute sql =~ ~s(sub_customers."organization_id" = selecto_root."tenant_id")
  end

  test "correlated scope accepts authored string keys and field names" do
    domain =
      update_in(inferred_domain(), [:source, :associations, :customer], fn association ->
        Map.merge(association, %{"source_scope_key" => "id", "target_scope_key" => "id"})
      end)

    {sql, []} = domain |> correlated_query(:json_agg) |> Selecto.to_sql()
    assert sql =~ ~s(sub_customers."id" = selecto_root."id")
    refute sql =~ ~s(sub_customers."organization_id" = selecto_root."tenant_id")
  end

  test "correlation stays tenantless when either relation has no declared tenant field" do
    for path <- [[:source], [:schemas, :customers]] do
      domain = update_in(inferred_domain(), path, &Map.delete(&1, :tenant_field))
      {sql, []} = domain |> correlated_query(:json_agg) |> Selecto.to_sql()
      assert sql =~ ~s(sub_customers."id" = selecto_root."customer_id")
      refute sql =~ ~s(sub_customers."organization_id" = selecto_root."tenant_id")
    end
  end

  test "correlation validates unprocessed associations with validation disabled" do
    domain = Map.put(inferred_domain(), :joins, %{})

    for key <- [:source_scope_key, :target_scope_key] do
      invalid = put_in(domain, [:source, :associations, :customer, key], :id)
      query = correlated_query(invalid, :json_agg, [], validate: false)

      assert_raise ArgumentError, ~r/requires both :source_scope_key and :target_scope_key/, fn ->
        Selecto.to_sql(query)
      end
    end

    for {path, side} <- [
          {[:source, :tenant_field], "source"},
          {[:schemas, :customers, :tenant_field], "target"},
          {[:source, :associations, :customer, :source_scope_key], "source"},
          {[:source, :associations, :customer, :target_scope_key], "target"}
        ] do
      invalid =
        if List.last(path) in [:source_scope_key, :target_scope_key] do
          domain
          |> put_in([:source, :associations, :customer, :source_scope_key], :tenant_id)
          |> put_in([:source, :associations, :customer, :target_scope_key], :organization_id)
        else
          domain
        end

      query =
        invalid |> put_in(path, :missing_scope) |> correlated_query(:count, [], validate: false)

      assert_raise ArgumentError, ~r/#{side} scope field :missing_scope is not declared/, fn ->
        Selecto.to_sql(query)
      end
    end
  end

  test "nested correlation uses its immediate parent tenant declaration" do
    domain =
      inferred_domain()
      |> put_in([:schemas, :customers, :associations], %{
        orders: %{
          queryable: :child_orders,
          field: :orders,
          owner_key: :id,
          related_key: :customer_id
        }
      })
      |> put_in([:schemas, :child_orders], %{
        source_table: "child_orders",
        primary_key: :id,
        tenant_field: :child_tenant,
        fields: [:id, :child_tenant, :customer_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          child_tenant: %{type: :integer},
          customer_id: %{type: :integer}
        },
        associations: %{}
      })

    query =
      correlated_query(domain, :json_agg,
        nested: [
          %{
            key: "orders",
            fields: ["id"],
            target_schema: :child_orders,
            format: :json_agg,
            join_path: [:customer, :orders]
          }
        ]
      )

    {sql, []} = Selecto.to_sql(query)
    assert sql =~ ~s(sub_customers_orders."customer_id" = sub_customers."id")
    assert sql =~ ~s(sub_customers_orders."child_tenant" = sub_customers."organization_id")
    refute sql =~ ~s(sub_customers_orders."child_tenant" = selecto_root."tenant_id")
  end

  test "flattened two-hop JSON and count guard the selected target through association aliases" do
    for format <- [:json_agg, :count] do
      {sql, []} = flattened_domain() |> flattened_query(format) |> Selecto.to_sql()

      assert sql =~ "FROM customers j_customer"

      assert sql =~
               ~s(j_customer."id" = selecto_root."customer_id" AND j_customer."organization_id" = selecto_root."tenant_id")

      assert sql =~
               ~s(sub_child_orders."customer_id" = j_customer."id" AND sub_child_orders."child_tenant" = j_customer."organization_id")

      refute sql =~ "INNER JOIN child_orders"
      refute sql =~ ~s(j_orders."id" = sub_child_orders."id")
    end
  end

  test "flattened three-hop correlation guards every immediate edge" do
    {sql, []} =
      flattened_domain()
      |> flattened_query(:json_agg,
        target_schema: :order_items,
        join_path: [:customer, :orders, :items]
      )
      |> Selecto.to_sql()

    assert sql =~ "INNER JOIN child_orders j_orders"

    assert sql =~
             ~s(j_orders."customer_id" = j_customer."id" AND j_orders."child_tenant" = j_customer."organization_id")

    assert sql =~
             ~s(sub_order_items."order_id" = j_orders."id" AND sub_order_items."item_tenant" = j_orders."child_tenant")

    refute sql =~ "INNER JOIN order_items"
    refute sql =~ ~s(sub_order_items."item_tenant" = selecto_root."tenant_id")
    refute sql =~ ~s(j_items."id" = sub_order_items."id")
  end

  test "two-hop target-named association uses its queryable intermediate relation" do
    domain =
      update_in(flattened_domain(), [:schemas, :customers, :associations], fn associations ->
        %{child_orders: Map.fetch!(associations, :orders)}
      end)

    {sql, []} =
      domain
      |> flattened_query(:count, join_path: [:customer, :child_orders])
      |> Selecto.to_sql()

    assert sql =~ "FROM customers j_customer"

    assert sql =~
             ~s(j_customer."organization_id" = selecto_root."tenant_id")

    assert sql =~
             ~s(sub_child_orders."customer_id" = j_customer."id" AND sub_child_orders."child_tenant" = j_customer."organization_id")
  end

  test "flattened final row binding uses its FK and authored scope rather than a matching target ID" do
    domain =
      flattened_domain()
      |> put_in([:schemas, :customers, :associations, :orders, :source_scope_key], :company_name)
      |> put_in([:schemas, :customers, :associations, :orders, :target_scope_key], :name)

    {sql, []} = domain |> flattened_query(:json_agg) |> Selecto.to_sql()

    assert sql =~
             ~s(sub_child_orders."customer_id" = j_customer."id" AND sub_child_orders."name" = j_customer."company_name")

    refute sql =~ ~s(sub_child_orders."child_tenant" = j_customer."organization_id")
    refute sql =~ ~s(j_orders."id" = sub_child_orders."id")
    refute sql =~ "INNER JOIN child_orders"
  end

  test "flattened complete non-tenant scope pairs override each inferred edge and preserve binds" do
    domain =
      flattened_domain()
      |> put_in([:source, :associations, :customer, :source_scope_key], :id)
      |> put_in([:source, :associations, :customer, :target_scope_key], :id)
      |> update_in([:schemas, :customers, :associations, :orders], fn association ->
        Map.merge(association, %{
          "source_scope_key" => "company_name",
          "target_scope_key" => "name"
        })
      end)

    for {target_schema, join_path, target_alias} <- [
          {:child_orders, [:customer, :orders], "sub_child_orders"},
          {:order_items, [:customer, :orders, :items], "sub_order_items"}
        ] do
      domain =
        domain
        |> put_in([:schemas, :child_orders, :associations, :items, :source_scope_key], :name)
        |> put_in([:schemas, :child_orders, :associations, :items, :target_scope_key], :name)

      {sql, ["O'Brien"]} =
        domain
        |> flattened_query(:json_agg,
          target_schema: target_schema,
          join_path: join_path,
          filters: [{"name", "O'Brien"}]
        )
        |> Selecto.order_by(["id"])
        |> Selecto.to_sql()

      assert sql =~ ~s(j_customer."id" = selecto_root."id")
      assert sql =~ "order by selecto_root.id"
      refute sql =~ ~s(j_customer."organization_id" = selecto_root."tenant_id")
      refute sql =~ "O'Brien"

      if target_schema == :child_orders do
        assert sql =~ ~s(#{target_alias}."name" = j_customer."company_name")
        refute sql =~ ~s(#{target_alias}."child_tenant" = j_customer."organization_id")
      else
        assert sql =~ ~s(j_orders."name" = j_customer."company_name")
        assert sql =~ ~s(#{target_alias}."name" = j_orders."name")
        refute sql =~ ~s(j_orders."child_tenant" = j_customer."organization_id")
        refute sql =~ ~s(#{target_alias}."item_tenant" = j_orders."child_tenant")
      end
    end
  end

  test "flattened tenantless intermediate relation does not infer transitive tenant scope" do
    domain =
      update_in(flattened_domain(), [:schemas, :customers], &Map.delete(&1, :tenant_field))

    {sql, []} = domain |> flattened_query(:json_agg) |> Selecto.to_sql()
    assert sql =~ ~s(j_customer."id" = selecto_root."customer_id")
    assert sql =~ ~s(sub_child_orders."customer_id" = j_customer."id")
    refute sql =~ ~s(j_customer."organization_id" = selecto_root."tenant_id")
    refute sql =~ ~s(sub_child_orders."child_tenant" = j_customer."organization_id")
    refute sql =~ ~s(sub_child_orders."child_tenant" = selecto_root."tenant_id")
  end

  test "flattened tenantless final target retains its parent FK without an inferred guard" do
    domain =
      update_in(flattened_domain(), [:schemas, :child_orders], &Map.delete(&1, :tenant_field))

    {sql, []} = domain |> flattened_query(:count) |> Selecto.to_sql()
    assert sql =~ ~s(j_customer."organization_id" = selecto_root."tenant_id")
    assert sql =~ ~s(sub_child_orders."customer_id" = j_customer."id")
    refute sql =~ ~s(sub_child_orders."child_tenant" = j_customer."organization_id")
    refute sql =~ ~s(j_orders."id" = sub_child_orders."id")
  end

  test "flattened unprocessed edges reject partial scopes with domain validation disabled" do
    for path <- flattened_association_paths(), key <- [:source_scope_key, :target_scope_key] do
      domain = put_in(flattened_domain(), path ++ [key], :id)

      query =
        flattened_query(
          domain,
          :count,
          [target_schema: :order_items, join_path: [:customer, :orders, :items]],
          validate: false
        )

      assert_raise ArgumentError, ~r/requires both :source_scope_key and :target_scope_key/, fn ->
        Selecto.to_sql(query)
      end
    end

    {sql, []} =
      flattened_query(flattened_domain(), :count, [], validate: false) |> Selecto.to_sql()

    assert sql =~ ~s(sub_child_orders."child_tenant" = j_customer."organization_id")
  end

  test "flattened unprocessed edges reject unavailable authored and inferred scope fields" do
    for path <- flattened_association_paths(), key <- [:source_scope_key, :target_scope_key] do
      domain =
        flattened_domain()
        |> put_in(path ++ [:source_scope_key], :id)
        |> put_in(path ++ [:target_scope_key], :id)
        |> put_in(path ++ [key], :missing_scope)

      query =
        flattened_query(
          domain,
          :count,
          [target_schema: :order_items, join_path: [:customer, :orders, :items]],
          validate: false
        )

      assert_raise ArgumentError, ~r/scope field :missing_scope is not declared/, fn ->
        Selecto.to_sql(query)
      end
    end

    for path <- [
          [:source, :tenant_field],
          [:schemas, :customers, :tenant_field],
          [:schemas, :child_orders, :tenant_field],
          [:schemas, :order_items, :tenant_field]
        ] do
      domain = put_in(flattened_domain(), path, :missing_scope)

      query =
        flattened_query(
          domain,
          :json_agg,
          [target_schema: :order_items, join_path: [:customer, :orders, :items]],
          validate: false
        )

      assert_raise ArgumentError, ~r/scope field :missing_scope is not declared/, fn ->
        Selecto.to_sql(query)
      end
    end
  end

  test "flattened target schema aliases may name the same physical relation" do
    domain = flattened_domain()
    domain = put_in(domain, [:schemas, :child_alias], domain.schemas.child_orders)

    {sql, []} =
      domain |> flattened_query(:json_agg, target_schema: :child_alias) |> Selecto.to_sql()

    assert sql =~ "FROM child_orders sub_child_alias"

    assert sql =~
             ~s(sub_child_alias."customer_id" = j_customer."id" AND sub_child_alias."child_tenant" = j_customer."organization_id")
  end

  test "flattened correlation refuses a path ending at an unrelated physical target" do
    domain = flattened_domain()

    domain =
      put_in(
        domain,
        [:schemas, :unrelated],
        Map.put(domain.schemas.child_orders, :source_table, "unrelated_orders")
      )

    query = flattened_query(domain, :count, target_schema: :unrelated)

    assert_raise ArgumentError, ~r/Join path terminates at .*does not match target schema/, fn ->
      Selecto.to_sql(query)
    end
  end

  test "direct and nested correlation refuse an unrelated configured target table" do
    domain = flattened_domain()

    direct = flattened_query(domain, :count, join_path: [:customer])

    assert_raise ArgumentError, ~r/does not match target schema/, fn ->
      Selecto.to_sql(direct)
    end

    nested =
      correlated_query(domain, :json_agg,
        nested: [
          %{
            key: "items",
            fields: ["id"],
            target_schema: :order_items,
            format: :json_agg,
            join_path: [:customer, :orders]
          }
        ]
      )

    assert_raise ArgumentError, ~r/does not match target schema/, fn ->
      Selecto.to_sql(nested)
    end
  end

  test "flattened repeated association aliases cannot collide with authored suffixes or outer aliases" do
    base = flattened_domain()

    domain =
      base
      |> put_in([:source, :associations], %{link: base.source.associations.customer})
      |> put_in([:schemas, :customers, :associations], %{
        link_2: base.schemas.customers.associations.orders
      })
      |> put_in([:schemas, :child_orders, :associations], %{
        link: base.schemas.child_orders.associations.items
      })
      |> put_in([:schemas, :order_items, :associations], %{
        leaf: %{queryable: :leaf_items, owner_key: :id, related_key: :item_id, cardinality: :many}
      })
      |> put_in([:schemas, :leaf_items], %{
        source_table: "leaf_items",
        primary_key: :id,
        tenant_field: :leaf_tenant,
        fields: [:id, :leaf_tenant, :item_id, :name],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          leaf_tenant: %{type: :integer},
          item_id: %{type: :integer},
          name: %{type: :string}
        },
        associations: %{}
      })

    path = [:link, :link_2, :link, :leaf]

    for format <- [:json_agg, :count] do
      {sql, []} =
        domain
        |> flattened_query(format, target_schema: :leaf_items, join_path: path)
        |> Selecto.to_sql()

      aliases = intermediate_aliases(sql)
      assert length(aliases) == 3
      assert length(Enum.uniq(aliases)) == 3
      [first, second, third] = aliases
      assert first == "j_link"
      assert second == "j_link_2"
      assert sql =~ ~s(#{third}."order_id" = #{second}."id")
      assert sql =~ ~s(#{third}."item_tenant" = #{second}."child_tenant")
      assert sql =~ ~s(sub_leaf_items."item_id" = #{third}."id")
      assert sql =~ ~s(sub_leaf_items."leaf_tenant" = #{third}."item_tenant")
      refute sql =~ "INNER JOIN leaf_items"
    end

    configured = Selecto.configure(domain, :mock_connection)

    for outer_alias <- ["j_link", "j_link_2"] do
      {:ok, correlation} =
        Selecto.Builder.Subselect.resolve_join_condition_with_path(
          configured,
          :leaf_items,
          outer_alias,
          path
        )

      sql = IO.iodata_to_binary(correlation)
      aliases = intermediate_aliases(sql)
      assert length(Enum.uniq(aliases)) == 3
      refute outer_alias in aliases
      assert sql =~ ~s(#{hd(aliases)}."id" = #{outer_alias}."customer_id")
      assert sql =~ ~s(#{hd(aliases)}."organization_id" = #{outer_alias}."tenant_id")
    end
  end

  test "flattened case-distinct association aliases remain unique as unquoted identifiers" do
    base = flattened_domain()

    domain =
      base
      |> put_in([:source, :associations], %{link: base.source.associations.customer})
      |> put_in([:schemas, :customers, :associations], %{
        link_2: base.schemas.customers.associations.orders
      })
      |> put_in([:schemas, :child_orders, :associations], %{
        link: base.schemas.child_orders.associations.items
      })
      |> put_in([:schemas, :order_items, :associations], %{
        leaf: %{queryable: :leaf_items, owner_key: :id, related_key: :item_id, cardinality: :many}
      })
      |> put_in([:schemas, :leaf_items], %{
        source_table: "leaf_items",
        primary_key: :id,
        tenant_field: :leaf_tenant,
        fields: [:id, :leaf_tenant, :item_id, :name],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          leaf_tenant: %{type: :integer},
          item_id: %{type: :integer},
          name: %{type: :string}
        },
        associations: %{}
      })

    case_distinct_domain =
      put_in(domain, [:source, :associations], %{Link: domain.source.associations.link})

    for format <- [:json_agg, :count],
        {configured_domain, path} <- [
          {domain, [:link, :link_2, :link, :leaf]},
          {case_distinct_domain, [:Link, :link_2, :link, :leaf]}
        ] do
      {sql, []} =
        configured_domain
        |> flattened_query(format, target_schema: :leaf_items, join_path: path)
        |> Selecto.to_sql()

      aliases = intermediate_aliases(sql)
      assert length(aliases) == 3
      assert length(Enum.uniq_by(aliases, &String.downcase/1)) == 3

      if hd(path) == :link do
        assert aliases == ["j_link", "j_link_2", "j_link_1"]
      end

      [first, second, third] = aliases
      assert sql =~ ~s(#{first}."id" = selecto_root."customer_id")
      assert sql =~ ~s(#{first}."organization_id" = selecto_root."tenant_id")
      assert sql =~ ~s(#{second}."customer_id" = #{first}."id")
      assert sql =~ ~s(#{second}."child_tenant" = #{first}."organization_id")
      assert sql =~ ~s(#{third}."order_id" = #{second}."id")
      assert sql =~ ~s(#{third}."item_tenant" = #{second}."child_tenant")
      assert sql =~ ~s(sub_leaf_items."item_id" = #{third}."id")
      assert sql =~ ~s(sub_leaf_items."leaf_tenant" = #{third}."item_tenant")
      refute sql =~ "INNER JOIN leaf_items"
      refute sql =~ ~s(#{third}."id" = sub_leaf_items."id")
    end
  end

  defp intermediate_aliases(sql) do
    ~r/(?:FROM customers|INNER JOIN child_orders|INNER JOIN order_items) (j_[A-Za-z0-9_]+)/
    |> Regex.scan(sql, capture: :all_but_first)
    |> List.flatten()
  end

  defp flattened_query(domain, format, subselect_opts \\ [], configure_opts \\ []) do
    domain
    |> Selecto.configure(:mock_connection, configure_opts)
    |> Selecto.select(["id"])
    |> Selecto.subselect([
      Map.merge(
        %{
          fields: ["id", "name"],
          target_schema: :child_orders,
          format: format,
          alias: "flattened",
          join_path: [:customer, :orders]
        },
        Map.new(subselect_opts)
      )
    ])
  end

  defp flattened_association_paths do
    [
      [:source, :associations, :customer],
      [:schemas, :customers, :associations, :orders],
      [:schemas, :child_orders, :associations, :items]
    ]
  end

  defp flattened_domain do
    inferred_domain()
    |> Map.put(:joins, %{})
    |> put_in([:schemas, :customers, :associations], %{
      orders: %{
        queryable: :child_orders,
        field: :orders,
        owner_key: :id,
        related_key: :customer_id,
        cardinality: :many
      }
    })
    |> put_in([:schemas, :child_orders], %{
      source_table: "child_orders",
      primary_key: :id,
      tenant_field: :child_tenant,
      fields: [:id, :child_tenant, :customer_id, :name],
      redact_fields: [],
      columns: %{
        id: %{type: :integer},
        child_tenant: %{type: :integer},
        customer_id: %{type: :integer},
        name: %{type: :string}
      },
      associations: %{
        items: %{
          queryable: :order_items,
          field: :items,
          owner_key: :id,
          related_key: :order_id,
          cardinality: :many
        }
      }
    })
    |> put_in([:schemas, :order_items], %{
      source_table: "order_items",
      primary_key: :id,
      tenant_field: :item_tenant,
      fields: [:id, :item_tenant, :order_id, :name],
      redact_fields: [],
      columns: %{
        id: %{type: :integer},
        item_tenant: %{type: :integer},
        order_id: %{type: :integer},
        name: %{type: :string}
      },
      associations: %{}
    })
  end

  defp correlated_query(domain, format, subselect_opts \\ [], configure_opts \\ []) do
    domain
    |> Selecto.configure(:mock_connection, configure_opts)
    |> Selecto.select(["id"])
    |> Selecto.subselect([
      Map.merge(
        %{
          fields: ["id", "company_name"],
          target_schema: :customers,
          format: format,
          alias: "customers",
          join_path: [:customer]
        },
        Map.new(subselect_opts)
      )
    ])
  end

  test "inferred tenant scope survives an association policy on a flat join and a collection" do
    domain =
      update_in(inferred_domain(), [:source, :associations, :customer], fn association ->
        Map.put(association, :where, %{company_name: "acme"})
      end)

    {join_sql, join_params} =
      domain
      |> Selecto.configure(:mock_connection)
      |> Selecto.select(["id", "customer.company_name"])
      |> Selecto.to_sql()

    assert join_sql =~
             ~s(customer."id" = selecto_root."customer_id" AND customer."organization_id" = selecto_root."tenant_id" AND customer."company_name" = $1)

    assert join_params == ["acme"]

    {subselect_sql, subselect_params} =
      domain
      |> Selecto.configure(:mock_connection)
      |> Selecto.select(["id"])
      |> Selecto.subselect([
        %{
          fields: ["id", "company_name"],
          target_schema: :customers,
          format: :json_agg,
          alias: "customers",
          join_path: [:customer]
        }
      ])
      |> Selecto.to_sql()

    assert subselect_sql =~
             ~s(sub_customers."id" = selecto_root."customer_id" AND sub_customers."organization_id" = selecto_root."tenant_id" AND sub_customers."company_name" = $1)

    assert subselect_params == ["acme"]
  end

  defp inferred_domain do
    scoped_domain()
    |> put_in([:source, :tenant_field], :tenant_id)
    |> update_in([:source, :associations, :customer], fn association ->
      Map.drop(association, [:source_scope_key, :target_scope_key])
    end)
    |> update_in([:schemas, :customers], fn schema ->
      schema
      |> Map.put(:tenant_field, :organization_id)
      |> Map.put(:fields, [:id, :organization_id, :company_name])
      |> Map.put(:columns, %{
        id: %{type: :integer},
        organization_id: %{type: :integer},
        company_name: %{type: :string}
      })
    end)
  end

  defp scoped_domain do
    %{
      name: "Orders",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :tenant_id, :customer_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          customer_id: %{type: :integer}
        },
        associations: %{
          customer: %{
            queryable: :customers,
            field: :customer,
            owner_key: :customer_id,
            related_key: :id,
            source_scope_key: :tenant_id,
            target_scope_key: :tenant_id
          }
        }
      },
      schemas: %{
        customers: %{
          source_table: "customers",
          primary_key: :id,
          fields: [:id, :tenant_id, :company_name],
          redact_fields: [],
          columns: %{
            id: %{type: :integer},
            tenant_id: %{type: :integer},
            company_name: %{type: :string}
          },
          associations: %{}
        }
      },
      joins: %{customer: %{type: :left}},
      filters: %{}
    }
  end
end
