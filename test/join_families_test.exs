defmodule Selecto.JoinFamiliesTest do
  # The join families Elixir keeps (left, inner, right, full, star_dimension,
  # the native sugar that normalises onto them, tagging and the PostgreSQL
  # adjacency-list hierarchy) and the ones it removed.
  use ExUnit.Case, async: true

  defp relation(table, columns, associations \\ %{}) do
    %{
      source_table: table,
      primary_key: :id,
      fields: Keyword.keys(columns),
      redact_fields: [],
      tenant_field: :tenant_id,
      columns: Map.new(columns, fn {name, type} -> {name, %{type: type}} end),
      associations: associations
    }
  end

  defp domain(join, association \\ %{}) do
    %{
      name: "Orders",
      source:
        relation(
          "orders",
          [id: :integer, customer_id: :integer, name: :string, tenant_id: :integer],
          %{
            customer:
              Map.merge(
                %{
                  queryable: :customers,
                  field: :customer,
                  owner_key: :customer_id,
                  related_key: :id
                },
                association
              )
          }
        ),
      schemas: %{
        customers:
          relation("customers",
            id: :integer,
            name: :string,
            active: :boolean,
            parent_id: :integer,
            tenant_id: :integer
          )
      },
      joins: %{customer: join}
    }
  end

  defp compile(domain, adapter \\ SelectoDBPostgreSQL.Adapter, fields \\ ["id", "customer.name"]) do
    domain
    |> Selecto.configure(Selecto.Runtime.Context.new(adapter, :compile_only), validate: false)
    |> Selecto.with_tenant(7)
    |> Selecto.select(fields)
    |> Selecto.to_sql()
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, v} -> {to_string(key), stringify(v)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  defp stringify(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp stringify(value), do: value

  describe "removed and unknown join types refuse on every path" do
    for {type, message} <- [
          {:cross_join, "cross_join was removed"},
          {:lateral_join, "lateral_join join type was removed"},
          {:conditional_join, "conditional_join was removed"},
          {:bogus, "unsupported join type :bogus"},
          {"no_such_type", "unsupported join type \"no_such_type\""}
        ] do
      test "#{inspect(type)}" do
        domain = domain(%{type: unquote(type)})

        assert {:error, diagnostics} = Selecto.Domain.validate(domain)
        assert [%{code: :unsupported_join_type, message: message}] = diagnostics.errors
        assert message =~ unquote(message)

        assert {:error, _diagnostics} = Selecto.Domain.validate_json(stringify(domain))

        error = assert_raise ArgumentError, fn -> compile(domain) end
        assert error.message =~ "invalid_domain: join :customer"
        assert error.message =~ unquote(message)
      end
    end

    test "a JSON type string never becomes a new atom" do
      name = "never_an_atom_#{System.unique_integer([:positive])}"

      assert {:error, _diagnostics} =
               Selecto.Domain.validate_json(stringify(domain(%{type: name})))

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "removed hierarchy kinds and snowflake normalization lists refuse" do
      for {join, message} <- [
            {%{type: :hierarchical, hierarchy_type: :materialized_path}, "materialized_path"},
            {%{type: :hierarchical, hierarchy_type: :closure_table}, "closure_table"},
            {%{type: :snowflake_dimension, normalization_joins: [%{table: "regions"}]},
             "normalization_joins"}
          ] do
        assert {:error, %{errors: [%{message: text}]}} = Selecto.Domain.validate(domain(join))
        assert text =~ message
        assert_raise ArgumentError, ~r/#{message}/, fn -> compile(domain(join)) end
      end
    end
  end

  describe "native sugar normalises onto the shared families" do
    test "self_join is an ordinary left association join, full_outer_join a full join" do
      {left, _} = compile(domain(%{type: :left}))
      assert {^left, _} = compile(domain(%{type: :self_join}))

      {full, _} = compile(domain(%{type: :full}))
      assert {^full, _} = compile(domain(%{type: :full_outer_join}))

      assert full =~
               "full join (select * from customers customer where customer.\"tenant_id\" = $1)"
    end

    test "dimension is a star_dimension whose display field is the dimension key" do
      {star, _} = compile(domain(%{type: :star_dimension, display_field: :name}))
      assert {^star, _} = compile(domain(%{type: :dimension, dimension: :name}))
    end
  end

  describe "star_dimension keeps the association's bounds" do
    test "where and the tenant pair stay in ON, and it takes an alias" do
      {sql, params} =
        domain(%{type: :star_dimension, display_field: :name, alias: "buyer"}, %{
          where: %{active: true}
        })
        |> compile(SelectoDBPostgreSQL.Adapter, ["id", "buyer.name"])

      assert sql =~ ~s(left join customers buyer on buyer."id" = selecto_root."customer_id")
      assert sql =~ ~s(buyer."tenant_id" = selecto_root."tenant_id")
      assert sql =~ ~s(buyer."active" = $1)
      assert params == [true, 7]
    end
  end

  describe "tagging and join_through read a scoped bridge" do
    defp tag_domain(association) do
      %{
        name: "Posts",
        source:
          relation("posts", [id: :integer, title: :string, tenant_id: :integer], %{
            tags:
              Map.merge(
                %{
                  queryable: :tags,
                  field: :tags,
                  cardinality: :many,
                  join_through: "post_tags",
                  join_keys: [{:post_id, :id}, {:tag_id, :id}],
                  where: %{visible: true}
                },
                association
              )
          }),
        schemas: %{
          tags:
            relation("tags", id: :integer, name: :string, visible: :boolean, tenant_id: :integer)
        },
        joins: %{tags: %{type: :tagging, tag_field: :name}}
      }
    end

    test "the bridge carries its scope key and the target its where" do
      {sql, params} =
        tag_domain(%{
          source_scope_key: :tenant_id,
          through_scope_key: :tenant_id,
          target_scope_key: :tenant_id,
          through_where: %{kind: "topic"}
        })
        |> Selecto.configure(
          Selecto.Runtime.Context.new(SelectoDBPostgreSQL.Adapter, :compile_only),
          validate: false
        )
        |> Selecto.with_tenant(7)
        |> Selecto.select(["id", "tags.name"])
        |> Selecto.to_sql()

      assert sql =~
               ~s[left join tags tags on EXISTS (SELECT 1 FROM "post_tags" tags_bridge ] <>
                 ~s[WHERE tags_bridge."post_id" = selecto_root."id" AND tags_bridge."tag_id" = tags."id" ] <>
                 ~s[AND tags_bridge."tenant_id" = selecto_root."tenant_id" ] <>
                 ~s[AND tags."tenant_id" = selecto_root."tenant_id" AND tags_bridge."kind" = $1) ] <>
                 ~s[AND tags."tenant_id" = selecto_root."tenant_id" AND tags."visible" = $2]

      assert true in params
      assert "topic" in params
    end

    test "join_keys are required" do
      domain =
        update_in(tag_domain(%{}), [:source, :associations, :tags], &Map.delete(&1, :join_keys))

      assert_raise ArgumentError, ~r/needs a join table and join_keys/, fn ->
        Selecto.configure(
          domain,
          Selecto.Runtime.Context.new(SelectoDBPostgreSQL.Adapter, :compile_only),
          validate: false
        )
      end
    end
  end

  describe "through lists" do
    test "an unknown segment refuses" do
      domain =
        domain(%{type: :left})
        |> put_in([:source, :associations, :via], %{
          queryable: :customers,
          field: :via,
          owner_key: :customer_id,
          related_key: :id,
          through: [:customer, :nowhere]
        })
        |> put_in([:joins, :via], %{type: :left})

      assert_raise ArgumentError, ~r/through segment :nowhere is not an association/, fn ->
        compile(domain)
      end
    end
  end

  describe "adjacency-list hierarchy" do
    defp tree_domain do
      domain(%{type: :hierarchical, hierarchy_type: :adjacency_list, depth_limit: 4}, %{
        where: %{active: true}
      })
    end

    test "PostgreSQL walks the tree within the association's bounds" do
      {sql, params} = compile(tree_domain())

      assert sql =~ ~s(WHERE c."parent_id" IS NULL AND c."active" = $)

      assert sql =~
               ~r/JOIN (__selecto_hierarchy_customer_\w+) h ON c."parent_id" = h."id" AND c."tenant_id" = h."tenant_id" WHERE h.level < \$2 AND c."active" = \$3/

      [_, cte] = Regex.run(~r/JOIN (__selecto_hierarchy_customer_\w+) h/, sql)

      assert sql =~
               ~s(left join #{cte} customer on customer."id" = selecto_root."customer_id" ) <>
                 ~s(AND customer."tenant_id" = selecto_root."tenant_id" AND customer."active" = $4)

      assert 4 in params
    end

    test "other adapters refuse before any SQL is sent" do
      assert_raise Selecto.Builder.ScopeRefusal, fn ->
        compile(tree_domain(), SelectoDBSQLite.Adapter)
      end
    end

    test "parent and id fields must be target fields" do
      bad = put_in(tree_domain(), [:joins, :customer, :parent_field], :nope)
      assert_raise ArgumentError, ~r/parent_field/, fn -> compile(bad) end
    end
  end
end
