defmodule SelectoSourceRelationshipAuthorityTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain
  alias Selecto.Domain.Contract.Shared.Core

  test "source relationship capabilities must resolve in the declared registry" do
    domain = put_in(domain(), [:source_relationships, :owner, :capability], "owner.read")
    assert {:error, diagnostics} = Domain.validate(domain)

    assert %{path: [:source_relationships, :owner, :capability], capability: "owner.read"} =
             error(diagnostics, :source_relationship_capability_not_found)
  end

  test "malformed capability references return typed diagnostics without executing callbacks" do
    callback = fn -> flunk("capability metadata must not execute") end

    for capability <- [123, [], %{}, callback] do
      domain = put_in(domain(), [:source_relationships, :owner, :capability], capability)
      assert {:error, diagnostics} = Domain.validate(domain)

      assert %{path: [:source_relationships, :owner, :capability]} =
               error(diagnostics, :invalid_source_relationship_capability)
    end
  end

  test "optional references and existing atom/string registry identity remain compatible" do
    for {capability, registry} <- [
          {nil, %{}},
          {:read_owner, %{"read_owner" => %{operations: [:read]}}},
          {"read_owner", %{read_owner: %{operations: [:read]}}},
          {"", %{"" => %{operations: [:read]}}}
        ] do
      domain =
        domain()
        |> Map.put(:capabilities, registry)
        |> put_in([:source_relationships, :owner, :capability], capability)

      assert {:ok, _, _} = Domain.validate(domain)
    end
  end

  test "nested aliases retain their whole declared association path" do
    domain =
      domain()
      |> put_in([:source_relationships, :owner, :source_field], "customer.region.name")
      |> put_in([:source_relationships, :owner, :virtual_join], [
        %{working_field: "customer.region.id", source_field: "owners.id", required: true}
      ])
      |> Map.put(:filters, %{region_name: %{field: "customer.region.name", type: :string}})

    assert {:ok, _, _} = Domain.validate(domain)
    assert {:ok, contract, _} = Domain.query_contract(domain)
    assert Enum.any?(contract.fields, &(&1.id == "customer.region.name"))

    index = field_index(domain)
    assert MapSet.member?(index, "customer.region.name")
    refute MapSet.member?(index, "region.name")
  end

  test "a child alias without its parent path does not acquire field authority" do
    domain = put_in(domain(), [:source_relationships, :owner, :source_field], "region.name")
    assert {:error, diagnostics} = Domain.validate(domain)
    assert error(diagnostics, :source_relationship_source_field_not_found)
  end

  test "schema name coincidences cannot manufacture undeclared join alias fields" do
    domain =
      domain()
      |> put_in([:schemas, :ghost], relation("ghosts", %{secret: %{type: :string}}))
      |> put_in([:joins, :ghost], %{type: :star_dimension, display_field: :secret})
      |> put_in([:source_relationships, :owner, :source_field], "ghost.secret")

    index = field_index(domain)
    refute MapSet.member?(index, "ghost_display")
    assert {:error, diagnostics} = Domain.validate(domain)
    assert error(diagnostics, :join_missing_association)

    # The schema itself declares ghost.secret. A distinct alias still needs an association.
    domain =
      domain
      |> put_in([:joins, :phantom], %{type: :left})
      |> put_in([:schemas, :phantom], relation("phantoms", %{secret: %{type: :string}}))
      |> update_in([:schemas], &Map.delete(&1, :ghost))

    refute MapSet.member?(field_index(domain), "ghost.secret")
  end

  test "missing or malformed association targets do not fall back to the alias schema" do
    for association <- [%{queryable: :missing}, %{}, :not_a_map] do
      domain =
        domain()
        |> put_in([:source, :associations, :customer], association)
        |> put_in([:schemas, :customer], relation("coincidence", %{secret: %{type: :string}}))

      index = field_index(domain)
      refute MapSet.member?(index, "customer.name")
      refute MapSet.member?(index, "customer.region.name")
      refute MapSet.member?(index, "customer_display")
    end
  end

  test "an explicit source self-association indexes the actual root relation" do
    domain =
      domain()
      |> put_in([:source, :associations, :parent], %{
        queryable: :source,
        owner_key: :owner_id,
        related_key: :id
      })
      |> put_in([:joins, :parent], %{type: :left})
      |> put_in([:source_relationships, :owner, :source_field], "parent.owner_id")

    assert {:ok, _, _} = Domain.validate(domain)
    assert MapSet.member?(field_index(domain), "parent.owner_id")
  end

  test "nested display aliases retain the parent prefix and require declared associations" do
    domain =
      put_in(domain(), [:joins, :customer, :joins, :region], %{
        type: :star_dimension,
        display_field: :name
      })

    assert {:ok, _, _} = Domain.validate(domain)
    assert MapSet.member?(field_index(domain), "customer.region_display")
    refute MapSet.member?(field_index(domain), "region_display")

    domain = update_in(domain, [:schemas, :customers, :associations], &Map.delete(&1, :region))
    refute MapSet.member?(field_index(domain), "customer.region_display")
  end

  test "static filters preserve pair and separate between bounds for the host resolver" do
    filters = [
      {:between, "owners.id", [1, 3]},
      ["between", "owners.id", 1, 3],
      ["and", [["eq", "owners.active", true], ["not", ["in", "owners.id", [2]]]]]
    ]

    domain =
      domain()
      |> put_in([:source_relationships, :owner, :filters], filters)
      |> Map.put(:choice_sources, %{
        owners: %{
          domain: :owners,
          value_field: :id,
          label_field: :name,
          source_relationship: :owner
        }
      })

    assert {:ok, request} = Domain.Choices.choice_source_options_request(domain, :owners)
    assert request.constraint_filters.source_relationship === filters
    assert request.source_relationship_config.filters === filters
  end

  test "the canonical example relationship descriptor and malformed diagnostics remain stable" do
    domain = Domain.Examples.work_items()
    assert {:ok, contract, _} = Domain.query_contract(domain)

    assert Enum.find(contract.source_relationships, &(&1.id == :owner)) == %{
             id: :owner,
             target_domain: :users,
             source_field: "owner_id",
             target_field: "id",
             source_path: "owners",
             filters_count: 1,
             virtual_join_count: 0
           }

    domain =
      domain
      |> put_in([:source_relationships, :owner, :source_field], :missing_owner)
      |> put_in([:source_relationships, :owner, :source_path], "")

    assert {:error, diagnostics} = Domain.validate(domain)

    assert diagnostics.errors |> Enum.map(& &1.code) |> Enum.sort() == [
             :invalid_source_relationship_source_path,
             :source_relationship_source_field_not_found
           ]
  end

  defp error(diagnostics, code), do: Enum.find(diagnostics.errors, &(&1.code == code))

  defp field_index(domain),
    do: Core.field_index(domain.source, domain.schemas, %{}, domain.joins)

  defp domain do
    source = relation("orders", %{id: %{type: :integer}, owner_id: %{type: :integer}})

    source =
      put_in(source, [:associations, :customer], %{
        queryable: :customers,
        owner_key: :owner_id,
        related_key: :id
      })

    customer = relation("customers", %{id: %{type: :integer}, name: %{type: :string}})

    customer =
      put_in(customer, [:associations, :region], %{
        queryable: :regions,
        owner_key: :id,
        related_key: :id
      })

    %{
      source: source,
      schemas: %{
        customers: customer,
        regions: relation("regions", %{id: %{type: :integer}, name: %{type: :string}})
      },
      joins: %{customer: %{type: :left, joins: %{region: %{type: :left}}}},
      source_relationships: %{
        owner: %{
          target_domain: :owners,
          source_field: :owner_id,
          target_field: :id,
          source_path: "owners"
        }
      }
    }
  end

  defp relation(table, columns),
    do: %{
      source_table: table,
      primary_key: :id,
      fields: Map.keys(columns),
      columns: columns,
      associations: %{}
    }
end
