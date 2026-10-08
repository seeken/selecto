defmodule Selecto.NestedSubselectPathTest do
  use ExUnit.Case, async: true

  test "nested JSON follows both suffix edges and each immediate tenant declaration" do
    {sql, []} = domain() |> nested_query() |> Selecto.to_sql()

    assert sql =~ "EXISTS (SELECT 1 FROM nodes j_members"
    assert sql =~ ~s(j_members."parent_id" = sub_parents."id")
    assert sql =~ ~s(j_members."tenant_id" = sub_parents."organization_id")
    assert sql =~ ~s(sub_parents_children."predecessor_id" = j_members."id")
    assert sql =~ ~s(sub_parents_children."tenant_id" = j_members."tenant_id")
    refute sql =~ ~s(sub_parents_children."parent_id" = sub_parents."id")
  end

  test "the terminal child alias is bound directly without a duplicate target self join" do
    {sql, []} = domain() |> nested_query() |> Selecto.to_sql()

    assert sql =~ "FROM nodes sub_parents_children WHERE EXISTS"
    assert sql =~ ~s(sub_parents_children."predecessor_id" = j_members."id")
    refute sql =~ "j_next"
  end

  test "a complete authored final pair overrides tenant inference on that edge only" do
    authored =
      domain()
      |> put_in([:schemas, :member_nodes, :associations, :next, :source_scope_key], :permit_key)
      |> put_in([:schemas, :member_nodes, :associations, :next, :target_scope_key], :incoming_key)

    {sql, []} = authored |> nested_query() |> Selecto.to_sql()

    assert sql =~ ~s(j_members."tenant_id" = sub_parents."organization_id")
    assert sql =~ ~s(sub_parents_children."incoming_key" = j_members."permit_key")
    refute sql =~ ~s(sub_parents_children."tenant_id" = j_members."tenant_id")
  end

  test "a scalar child filter binds at the final child while retaining all suffix edges" do
    literal = "leaf' OR 1=1 --"

    {sql, [^literal]} =
      domain()
      |> nested_query(child: %{filters: [{"name", literal}]})
      |> Selecto.to_sql()

    assert sql =~ ~s(sub_parents_children."name" = $1)
    assert sql =~ ~s(sub_parents_children."predecessor_id" = j_members."id")
    refute sql =~ literal
  end

  test "string authored schema keys and full paths resolve the same two suffix edges" do
    authored = string_domain(domain())

    {sql, []} =
      authored
      |> nested_query(
        parent: %{target_schema: "parents", join_path: ["parent"]},
        child: %{
          target_schema: "terminal_nodes",
          join_path: ["parent", "members", "next"]
        }
      )
      |> Selecto.to_sql()

    assert sql =~ ~s(j_members."tenant_id" = sub_parents."organization_id")
    assert sql =~ ~s(sub_parents_children."predecessor_id" = j_members."id")
    assert sql =~ ~s(sub_parents_children."tenant_id" = j_members."tenant_id")
  end

  test "omitted paths resolve the full root path before deriving the child suffix" do
    {sql, []} =
      domain()
      |> nested_query(parent: %{join_path: nil}, child: %{join_path: nil})
      |> Selecto.to_sql()

    assert sql =~ ~s(j_members."parent_id" = sub_parents."id")
    assert sql =~ ~s(sub_parents_children."predecessor_id" = j_members."id")
  end

  test "a full root path for a direct nested child retains the direct correlation" do
    {sql, []} =
      domain()
      |> nested_query(child: %{target_schema: :member_nodes, join_path: [:parent, :members]})
      |> Selecto.to_sql()

    assert sql =~ ~s(sub_parents_children."parent_id" = sub_parents."id")
    assert sql =~ ~s(sub_parents_children."tenant_id" = sub_parents."organization_id")
    refute sql =~ "EXISTS (SELECT 1 FROM nodes j_members"
  end

  test "a child-relative path is refused by the public root-relative path validator" do
    assert_raise ArgumentError,
                 ~r/Invalid subselect configuration: join members does not follow an association/,
                 fn ->
                   domain()
                   |> nested_query(child: %{target_schema: :member_nodes, join_path: [:members]})
                 end
  end

  test "a root-valid child path through another parent cannot replace its enclosing path" do
    authored =
      put_in(domain(), [:source, :associations, :other], %{
        queryable: :parents,
        owner_key: :parent_id,
        related_key: :id,
        cardinality: :one
      })

    query = nested_query(authored, child: %{join_path: [:other, :members, :next]})

    assert_raise ArgumentError, ~r/Nested subselect path .* must extend its parent path/, fn ->
      Selecto.to_sql(query)
    end
  end

  test "a child path equal to its parent path is refused instead of guessing a suffix" do
    query =
      nested_query(domain(),
        parent: %{target_schema: :member_nodes, join_path: [:parent, :members]},
        child: %{target_schema: :member_nodes, join_path: [:parent, :members]}
      )

    assert_raise ArgumentError, ~r/Nested subselect path .* must extend its parent path/, fn ->
      Selecto.to_sql(query)
    end
  end

  test "the lower-level builder preserves its existing one-edge relative correlation" do
    query = Selecto.configure(domain(), :mock_connection) |> Selecto.select(["id"])

    parent = %{
      fields: ["id", "name"],
      target_schema: :parents,
      format: :json_agg,
      alias: "items",
      join_path: [:parent],
      filters: [],
      nested: [
        %{
          key: "children",
          fields: ["id", "name"],
          target_schema: :member_nodes,
          format: :json_agg,
          join_path: [:members],
          filters: []
        }
      ]
    }

    {clauses, []} =
      Selecto.Builder.Subselect.build_subselect_clauses(%{
        query
        | set: Map.put(query.set, :subselected, [parent])
      })

    {sql, []} = Selecto.SQL.Params.finalize(clauses, adapter: query.adapter)
    assert sql =~ ~s(sub_parents_children."parent_id" = sub_parents."id")
    assert sql =~ ~s(sub_parents_children."tenant_id" = sub_parents."organization_id")
  end

  test "every unprocessed suffix edge validates a partially authored pair" do
    for scope_key <- [:source_scope_key, :target_scope_key] do
      authored =
        put_in(domain(), [:schemas, :member_nodes, :associations, :next, scope_key], :id)

      query = nested_query(authored, configure: [validate: false])

      assert_raise ArgumentError, ~r/requires both :source_scope_key and :target_scope_key/, fn ->
        Selecto.to_sql(query)
      end
    end
  end

  test "final scope fields must be declared even when domain validation is disabled" do
    authored =
      domain()
      |> put_in([:schemas, :member_nodes, :associations, :next, :source_scope_key], :missing)
      |> put_in([:schemas, :member_nodes, :associations, :next, :target_scope_key], :incoming_key)

    query = nested_query(authored, configure: [validate: false])

    assert_raise ArgumentError, ~r/source scope field :missing is not declared/, fn ->
      Selecto.to_sql(query)
    end
  end

  test "the final physical endpoint must match the child schema" do
    authored =
      put_in(domain(), [:schemas, :unrelated], relation("unrelated_nodes", :tenant_id))

    query = nested_query(authored, child: %{target_schema: :unrelated})

    assert_raise ArgumentError, ~r/Join path terminates at .* does not match target schema/, fn ->
      Selecto.to_sql(query)
    end
  end

  test "a tenantless immediate member does not inherit a scope from distant relations" do
    authored = update_in(domain(), [:schemas, :member_nodes], &Map.delete(&1, :tenant_field))
    {sql, []} = authored |> nested_query() |> Selecto.to_sql()

    assert sql =~ ~s(j_members."parent_id" = sub_parents."id")
    assert sql =~ ~s(sub_parents_children."predecessor_id" = j_members."id")
    refute sql =~ ~s(j_members."tenant_id" = sub_parents."organization_id")
    refute sql =~ ~s(sub_parents_children."tenant_id" = j_members."tenant_id")
    assert sql =~ ~s(sub_parents."organization_id" = selecto_root."tenant_id")
  end

  test "a nested parent with a two-edge root path retains both of its child suffix edges" do
    authored =
      domain()
      |> put_in([:schemas, :terminal_nodes, :associations, :more], %{
        queryable: :final_nodes,
        owner_key: :id,
        related_key: :predecessor_id,
        cardinality: :many
      })
      |> put_in([:schemas, :final_nodes], relation("nodes", :tenant_id))

    {sql, []} =
      authored
      |> nested_query(
        parent: %{target_schema: :member_nodes, join_path: [:parent, :members]},
        child: %{
          target_schema: :final_nodes,
          join_path: [:parent, :members, :next, :more]
        }
      )
      |> Selecto.to_sql()

    assert sql =~ ~s(j_next."predecessor_id" = sub_member_nodes."id")
    assert sql =~ ~s(j_next."tenant_id" = sub_member_nodes."tenant_id")
    assert sql =~ ~s(sub_member_nodes_children."predecessor_id" = j_next."id")
    assert sql =~ ~s(sub_member_nodes_children."tenant_id" = j_next."tenant_id")
  end

  defp nested_query(authored, opts \\ []) do
    child =
      Map.merge(
        %{
          key: "children",
          fields: ["id", "name"],
          target_schema: :terminal_nodes,
          format: :json_agg,
          join_path: [:parent, :members, :next],
          filters: [],
          order_by: [{:asc, "id"}]
        },
        Keyword.get(opts, :child, %{})
      )

    parent =
      Map.merge(
        %{
          fields: ["id", "name"],
          target_schema: :parents,
          format: :json_agg,
          alias: "items",
          join_path: [:parent],
          filters: [],
          nested: [child]
        },
        Keyword.get(opts, :parent, %{})
      )

    Selecto.configure(authored, :mock_connection, Keyword.get(opts, :configure, []))
    |> Selecto.select(["id"])
    |> Selecto.subselect([parent])
  end

  defp domain do
    %{
      name: "NestedSuffixPaths",
      filters: %{},
      joins: %{},
      source:
        relation("roots", :tenant_id)
        |> Map.put(:associations, %{
          parent: %{
            queryable: :parents,
            owner_key: :parent_id,
            related_key: :id,
            cardinality: :one
          }
        }),
      schemas: %{
        parents:
          relation("parents", :organization_id)
          |> Map.put(:associations, %{
            members: %{
              queryable: :member_nodes,
              owner_key: :id,
              related_key: :parent_id,
              cardinality: :many
            }
          }),
        member_nodes:
          relation("nodes", :tenant_id)
          |> Map.put(:associations, %{
            next: %{
              queryable: :terminal_nodes,
              owner_key: :id,
              related_key: :predecessor_id,
              cardinality: :many
            }
          }),
        terminal_nodes: relation("nodes", :tenant_id)
      }
    }
  end

  defp relation(table, tenant) do
    fields = [
      :id,
      :tenant_id,
      :organization_id,
      :parent_id,
      :predecessor_id,
      :name,
      :permit_key,
      :incoming_key
    ]

    %{
      source_table: table,
      primary_key: :id,
      tenant_field: tenant,
      fields: fields,
      redact_fields: [],
      columns: Map.new(fields, &{&1, %{type: if(&1 == :name, do: :string, else: :integer)}}),
      associations: %{}
    }
  end

  defp string_domain(authored) do
    %{
      authored
      | source: string_relation(authored.source),
        schemas:
          Map.new(authored.schemas, fn {key, relation} ->
            {to_string(key), string_relation(relation)}
          end)
    }
  end

  defp string_relation(relation) do
    %{
      relation
      | primary_key: to_string(relation.primary_key),
        tenant_field: to_string(relation.tenant_field),
        fields: Enum.map(relation.fields, &to_string/1),
        columns: Map.new(relation.columns, fn {key, value} -> {to_string(key), value} end),
        associations:
          Map.new(relation.associations, fn {key, association} ->
            {to_string(key),
             Map.new(association, fn
               {:cardinality, value} -> {:cardinality, value}
               {field, value} -> {field, to_string(value)}
             end)}
          end)
    }
  end
end
