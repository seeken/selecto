defmodule Selecto.OuterJoinsTest do
  use ExUnit.Case, async: true

  defmodule OuterAdapter do
    def connect(connection), do: {:ok, connection}
    def supports?(feature), do: feature in [:right_join, :full_join]
    def placeholder(index), do: "$#{index}"
    def quote_identifier(identifier), do: ~s("#{identifier}")

    def execute(_connection, sql, _params, _opts) do
      send(self(), {:executed, sql})
      {:ok, %{rows: [], columns: []}}
    end
  end

  # RIGHT JOIN only, and a catalog read before compiling (as MySQL's).
  defmodule RightOnlyAdapter do
    def connect(connection), do: {:ok, connection}
    def supports?(feature), do: feature == :right_join
    def placeholder(_index), do: "?"
    def quote_identifier(identifier), do: "`#{identifier}`"

    def prepare_read(selecto, _connection) do
      send(self(), :catalog_read)
      {:ok, selecto}
    end

    def execute(_connection, sql, _params, _opts) do
      send(self(), {:executed, sql})
      {:ok, %{rows: [], columns: []}}
    end
  end

  defp domain(join, association \\ %{}) do
    %{
      name: "Orders",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :customer_id, :region],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          customer_id: %{type: :integer},
          region: %{type: :string}
        },
        associations: %{
          customer:
            Map.merge(
              %{
                queryable: :customers,
                field: :customer,
                owner_key: :customer_id,
                related_key: :id,
                where: %{"active" => 1}
              },
              association
            )
        }
      },
      schemas: %{
        customers: %{
          source_table: "customers",
          primary_key: :id,
          fields: [:id, :name, :active],
          redact_fields: [],
          columns: %{
            id: %{type: :integer},
            name: %{type: :string},
            active: %{type: :integer}
          },
          associations: %{}
        }
      },
      joins: %{customer: join}
    }
  end

  defp sql(domain, adapter \\ OuterAdapter) do
    {sql, params} =
      domain
      |> Selecto.configure(:mock_connection, adapter: adapter, validate: false)
      |> Selecto.select(["id", "customer.name"])
      |> Selecto.to_sql()

    {sql, params}
  end

  describe "rendering" do
    test "a right join filters the target in a derived table before the join" do
      {sql, params} = sql(domain(%{type: :right}))

      assert sql =~
               ~s|right join (select * from customers customer where customer."active" = $1) customer on customer."id" = selecto_root."customer_id"|

      assert params == [1]
    end

    test "a full join, and the root's required filter after the join in WHERE" do
      {sql, params} =
        %{type: "full"}
        |> domain()
        |> Map.put(:required_filters, [{"region", "east"}])
        |> sql()

      assert sql =~ "full join (select * from customers customer where"
      assert [_target, after_join] = String.split(sql, ") customer on ", parts: 2)
      assert after_join =~ ~r/ where .*selecto_root\."?region"? = \$2/s
      assert params == [1, "east"]
    end

    test "a left join keeps its where in ON" do
      {sql, _params} = sql(domain(%{type: :left}))
      assert sql =~ ~s|left join customers customer on |
      refute sql =~ "(select * from"
    end

    test "an alias names the join's correlation everywhere" do
      {sql, _params} = sql(domain(%{type: :right, alias: "buyer_row"}))

      assert sql =~ "select selecto_root.id, buyer_row.name"

      assert sql =~
               ~s|right join (select * from customers buyer_row where buyer_row."active" = $1) buyer_row on buyer_row."id" = selecto_root."customer_id"|

      refute sql =~ ~r/\bcustomer\./
    end

    test "filters, orderings and groupings on the join's fields use the alias" do
      {sql, params} =
        %{type: :left, alias: "buyer_row"}
        |> domain()
        |> Selecto.configure(:mock_connection, adapter: OuterAdapter, validate: false)
        |> Selecto.select(["customer.name", {:count, "*"}])
        |> Selecto.filter({"customer.name", "ann"})
        |> Selecto.group_by(["customer.name"])
        |> Selecto.order_by(["customer.name"])
        |> Selecto.to_sql()

      assert sql =~ ~r/where .*buyer_row\.name = \$2/s
      assert sql =~ ~r/group by\s+buyer_row\.name/
      assert sql =~ ~r/order by\s+buyer_row\.name/
      refute sql =~ ~r/\bcustomer\./
      assert params == [1, "ann"]
    end

    test "a mixed-case alias correlates in lower case, as SQL reads it unquoted" do
      {sql, _params} = sql(domain(%{type: :left, alias: "BuyerRow"}))
      assert sql =~ "buyerrow.name"

      assert sql =~
               ~s|left join customers buyerrow on buyerrow."id" = selecto_root."customer_id" AND buyerrow."active" = $1|
    end
  end

  describe "adapter capability" do
    test "a dialect without the join refuses with unsupported_feature before any SQL" do
      selecto =
        %{type: :full}
        |> domain()
        |> Selecto.configure(:mock_connection, adapter: RightOnlyAdapter, validate: false)
        |> Selecto.select(["id", "customer.name"])

      assert {:error, %Selecto.Error{details: %{unsupported_feature: :full_join}}} =
               Selecto.execute(selecto)

      refute_received :catalog_read
      refute_received {:executed, _}

      assert_raise Selecto.Builder.ScopeRefusal, ~r/FULL JOIN/, fn -> Selecto.to_sql(selecto) end
    end

    test "the same adapter runs a right join, and a query not reaching the full join" do
      right =
        %{type: :right}
        |> domain()
        |> Selecto.configure(:mock_connection, adapter: RightOnlyAdapter, validate: false)
        |> Selecto.select(["id", "customer.name"])

      assert {:ok, _} = Selecto.execute(right)
      assert {sql, _params} = Selecto.to_sql(right)
      assert sql =~ "right join (select * from"

      assert {:ok, _} =
               %{type: :full}
               |> domain()
               |> Selecto.configure(:mock_connection, adapter: RightOnlyAdapter, validate: false)
               |> Selecto.select(["id", "region"])
               |> Selecto.execute()
    end
  end

  describe "domain refusals" do
    test "right and full joins take a direct association only" do
      for type <- [:right, "full"],
          association <- [
            %{through: %{table: "links", owner_key: :order_id, related_key: :customer_id}},
            %{join_strategy: "lateral_lookup"}
          ] do
        domain = domain(%{type: type}, association)

        assert {:error, diagnostics} = Selecto.Domain.validate(domain)

        assert Enum.any?(
                 diagnostics.errors,
                 &(&1.code == :outer_join_requires_direct_association)
               )

        assert_raise ArgumentError, ~r/^invalid_domain: .*direct association/, fn ->
          Selecto.configure(domain, :mock_connection, adapter: OuterAdapter, validate: false)
        end
      end
    end

    test "aliases are unique ignoring case, identifiers, and outside Selecto's names" do
      base = domain(%{type: :left, alias: "Buyer"})

      duplicate =
        base
        |> put_in([:source, :associations, :buyer], base.source.associations.customer)
        |> put_in([:joins, :buyer], %{type: :left, alias: "buyer"})

      colliding = put_in(base, [:joins, :customer, :alias], "selecto_root")
      generated = put_in(base, [:joins, :customer, :alias], "_selecto_join_0")
      invalid = put_in(base, [:joins, :customer, :alias], "buyer row")
      reserved_word = put_in(base, [:joins, :customer, :alias], "Order")

      other_name =
        base
        |> put_in([:source, :associations, :buyer], base.source.associations.customer)
        |> put_in([:joins, :buyer], %{type: :left, alias: "Customer"})

      for {domain, code} <- [
            {duplicate, :duplicate_join_alias},
            {colliding, :invalid_join_alias},
            {generated, :invalid_join_alias},
            {invalid, :invalid_join_alias},
            {reserved_word, :invalid_join_alias},
            {other_name, :duplicate_join_alias}
          ] do
        assert {:error, diagnostics} = Selecto.Domain.validate(domain)
        assert Enum.any?(diagnostics.errors, &(&1.code == code)), inspect(diagnostics.errors)

        assert_raise ArgumentError, ~r/^invalid_domain: join /, fn ->
          Selecto.configure(domain, :mock_connection, adapter: OuterAdapter, validate: false)
        end
      end

      assert {:ok, _normalized, _diagnostics} = Selecto.Domain.validate(base)
    end

    test "the canonical JSON form validates and refuses the same way" do
      json = %{
        "name" => "Orders",
        "source" => %{
          "source_table" => "orders",
          "primary_key" => "id",
          "fields" => ["id", "customer_id"],
          "columns" => %{"id" => %{"type" => "integer"}, "customer_id" => %{"type" => "integer"}},
          "associations" => %{
            "customer" => %{
              "queryable" => "customers",
              "owner_key" => "customer_id",
              "related_key" => "id"
            },
            "buyer" => %{
              "queryable" => "customers",
              "owner_key" => "customer_id",
              "related_key" => "id"
            }
          }
        },
        "schemas" => %{
          "customers" => %{
            "source_table" => "customers",
            "primary_key" => "id",
            "fields" => ["id", "name"],
            "columns" => %{"id" => %{"type" => "integer"}, "name" => %{"type" => "string"}},
            "associations" => %{}
          }
        },
        "joins" => %{
          "customer" => %{"type" => "right", "alias" => "buyer_row"},
          "buyer" => %{"type" => "left"}
        }
      }

      assert {:ok, _normalized, _diagnostics} = Selecto.Domain.validate(json)

      duplicate = put_in(json, ["joins", "buyer", "alias"], "BUYER_ROW")
      assert {:error, diagnostics} = Selecto.Domain.validate(duplicate)
      assert Enum.any?(diagnostics.errors, &(&1.code == :duplicate_join_alias))
    end
  end
end
