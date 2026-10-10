defmodule SelectoChoiceAliasAuthorityTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain
  alias Selecto.Domain.Choices
  alias Selecto.Domain.Contract.Shared.Core

  test "joined compact choice bindings flow through every public request and descriptor" do
    domain = domain()
    assert {:ok, binding} = Choices.binding(domain, "owner.name")
    assert binding.choice_source == :owner_choices
    assert binding.path == [:schemas, :owners, :columns, :name]
    assert {:ok, request} = Choices.request(domain, "owner.name", "Ada", tenant: 7)
    assert request.field_binding == binding
    assert request.constraint_filters.source_relationship == [{:eq, "owners.active", true}]
    assert {:ok, options} = Choices.options_request(domain, "owner.name", search: "ad")
    assert options.field_binding == binding
    assert options.search == "ad"
    assert descriptor(domain, "owner.name").choice_source == :owner_choices
    assert descriptor(domain, "owner.name").source == :join
    assert {:ok, contract, _} = Domain.query_contract(domain)

    assert Enum.any?(
             contract.field_choice_bindings,
             &(&1.field == "owner.name" and &1.choice_source == :owner_choices)
           )
  end

  test "nested complete and established local aliases preserve rich reference metadata" do
    domain = nested_domain()

    for field <- ["owner.region.name", "region.name"] do
      assert {:ok, binding} = Choices.binding(domain, field)
      assert binding.path == [:schemas, :regions, :columns, :name]
      assert binding.reference == %{choice_source: :owner_choices, caption_field: :title}
      assert {:ok, request} = Choices.request(domain, field, "North")
      assert request.reference == binding.reference
      assert {:ok, options} = Choices.options_request(domain, field)
      assert options.reference == binding.reference
      assert descriptor(domain, field).choice_source == :owner_choices
      assert MapSet.member?(index(domain), field)
    end
  end

  test "projection overrides decorate an actual joined column without losing its reference" do
    domain =
      Map.put(nested_domain(), :columns, %{"owner.region.name" => %{label: "Region label"}})

    assert {:ok, binding} = Choices.binding(domain, "owner.region.name")
    assert binding.column.label == "Region label"
    assert binding.reference.choice_source == :owner_choices
    assert descriptor(domain, "owner.region.name").label == "Region label"
    assert descriptor(domain, "owner.region.name").choice_source == :owner_choices
  end

  test "self associations refer to actual root columns despite a schema named source" do
    domain = domain()
    domain = put_in(domain, [:source, :columns, :title, :choice_source], :owner_choices)

    domain =
      put_in(domain, [:source, :associations, :parent], %{
        queryable: :source,
        owner_key: :owner_id,
        related_key: :id
      })

    domain = put_in(domain, [:joins, :parent], %{type: :left})

    domain =
      put_in(
        domain,
        [:schemas, :source],
        relation("decoy", %{title: %{type: :string, choice_source: :state_choices}})
      )

    assert {:ok, binding} = Choices.binding(domain, "parent.title")
    assert binding.choice_source == :owner_choices
    assert binding.path == [:source, :columns, :title]
    assert descriptor(domain, "parent.title").choice_source == :owner_choices
  end

  test "nested self join descriptors and choice bindings share the actual root target" do
    domain = domain()
    domain = put_in(domain, [:source, :columns, :title, :choice_source], :owner_choices)

    domain =
      put_in(domain, [:schemas, :owners, :associations, :parent], %{
        queryable: :source,
        owner_key: :id,
        related_key: :id
      })

    domain = put_in(domain, [:joins, :owner, :joins], %{parent: %{type: :left}})
    assert {:ok, binding} = Choices.binding(domain, "owner.parent.title")
    assert binding.path == [:source, :columns, :title]
    assert {:ok, contract, _} = Domain.query_contract(domain)
    join = Enum.find(contract.joins, &(&1.path == ["owner", "parent"]))
    assert "title" in join.fields
    refute "active" in join.fields
    assert descriptor(domain, "owner.parent.title").choice_source == :owner_choices
  end

  test "actual join namespace wins over a coincident schema" do
    domain =
      put_in(
        domain(),
        [:schemas, :owner],
        relation("decoy", %{name: %{type: :string, choice_source: :state_choices}})
      )

    assert {:ok, binding} = Choices.binding(domain, "owner.name")
    assert binding.choice_source == :owner_choices
    assert binding.path == [:schemas, :owners, :columns, :name]
    assert descriptor(domain, "owner.name").choice_source == :owner_choices
  end

  test "missing actual join field cannot fall through to coincident schema or projection" do
    domain = domain()

    domain =
      put_in(
        domain,
        [:schemas, :owner],
        relation("decoy", %{fake: %{type: :string, choice_source: :state_choices}})
      )

    domain =
      Map.put(domain, :columns, %{"owner.fake" => %{type: :string, choice_source: :state_choices}})

    domain =
      Map.put(domain, :custom_columns, %{
        "owner.fake" => %{type: :string, choice_source: :state_choices}
      })

    assert {:error, %{code: :field_not_found}} = Choices.binding(domain, "owner.fake")
    assert {:error, %{code: :field_not_found}} = Choices.request(domain, "owner.fake", "forged")
    assert {:error, %{code: :field_not_found}} = Choices.options_request(domain, "owner.fake")
    refute descriptor(domain, "owner.fake")
    assert {:ok, contract, _} = Domain.query_contract(domain)
    refute Enum.any?(contract.field_choice_bindings, &(&1.field == "owner.fake"))
    refute MapSet.member?(index(domain), "owner.fake")

    assert {:error, %{code: :field_not_found}} =
             Choices.validate_choice(domain, "owner.fake", 1,
               resolver: fn _ -> flunk("unowned field must not reach host resolver") end
             )
  end

  test "ambiguous local namespace refuses even where only one target owns the field" do
    domain = ambiguous_domain()

    domain =
      put_in(
        domain,
        [:schemas, :region],
        relation("decoy", %{name: %{type: :string, choice_source: :state_choices}})
      )

    assert {:error, %{code: :ambiguous_join_alias}} = Choices.binding(domain, "region.name")

    assert {:error, %{code: :ambiguous_join_alias}} =
             Choices.options_request(domain, "region.name")

    refute descriptor(domain, "region.name")
    refute MapSet.member?(index(domain), "region.name")
    assert {:ok, binding} = Choices.binding(domain, "owner.region.name")
    assert binding.choice_source == :owner_choices
    assert {:ok, binding} = Choices.binding(domain, "reviewer.region.code")
    assert binding.choice_source == :state_choices
  end

  test "an explicit complete join alias outranks nested local shorthand" do
    domain = nested_domain()

    domain =
      put_in(domain, [:source, :associations, :region], %{
        queryable: :direct_regions,
        owner_key: :owner_id,
        related_key: :id
      })

    domain =
      put_in(
        domain,
        [:schemas, :direct_regions],
        relation("direct_regions", %{name: %{type: :string, choice_source: :state_choices}})
      )

    domain = put_in(domain, [:joins, :region], %{type: :left})
    assert {:ok, direct} = Choices.binding(domain, "region.name")
    assert direct.choice_source == :state_choices
    assert {:ok, nested} = Choices.binding(domain, "owner.region.name")
    assert nested.choice_source == :owner_choices
    assert descriptor(domain, "region.name").choice_source == :state_choices
    assert descriptor(domain, "owner.region.name").choice_source == :owner_choices
  end

  test "unjoined schema and projection bindings remain available outside declared alias namespaces" do
    domain =
      Map.put(domain(), :columns, %{
        "standalone" => %{type: :string, choice_source: :state_choices}
      })

    assert {:ok, schema} = Choices.binding(domain, "owners.name")
    assert schema.choice_source == :owner_choices
    assert {:ok, projected} = Choices.binding(domain, "standalone")
    assert projected.choice_source == :state_choices
    domain = put_in(domain, [:joins, :ghost], %{type: :left})

    assert {:error, %{code: :invalid_domain_contract, errors: errors}} =
             Choices.binding(domain, "ghost.name")

    assert Enum.any?(errors, &(&1.code == :join_missing_association))
    refute MapSet.member?(index(domain), "ghost.name")
  end

  test "explicit root columns retain precedence over qualified alias metadata" do
    domain =
      put_in(domain(), [:source, :columns, "owner.name"], %{
        type: :string,
        choice_source: :state_choices
      })

    assert {:ok, binding} = Choices.binding(domain, "owner.name")
    assert binding.choice_source == :state_choices
    assert binding.path == [:source, :columns, "owner.name"]
    assert descriptor(domain, "owner.name").source == :source
  end

  defp descriptor(domain, field) do
    assert {:ok, contract, _} = Domain.query_contract(domain)
    Enum.find(contract.fields, &(&1.id == field))
  end

  defp index(domain),
    do:
      Core.field_index(
        domain.source,
        domain.schemas,
        %{custom_columns: Map.get(domain, :custom_columns, %{})},
        domain.joins
      )

  defp domain do
    Domain.Examples.work_items()
    |> Map.take([
      :name,
      :source,
      :schemas,
      :joins,
      :source_relationships,
      :choice_sources,
      :capabilities
    ])
    |> put_in([:schemas, :owners, :columns, :name, :choice_source], :owner_choices)
  end

  defp nested_domain do
    domain()
    |> put_in([:schemas, :owners, :associations, :region], %{
      queryable: :regions,
      owner_key: :id,
      related_key: :id
    })
    |> put_in(
      [:schemas, :regions],
      relation("regions", %{
        name: %{type: :string, reference: %{choice_source: :owner_choices, caption_field: :title}}
      })
    )
    |> put_in([:joins, :owner, :joins], %{region: %{type: :left}})
  end

  defp ambiguous_domain do
    nested_domain()
    |> put_in([:source, :associations, :reviewer], %{
      queryable: :reviewers,
      owner_key: :owner_id,
      related_key: :id
    })
    |> put_in(
      [:schemas, :reviewers],
      Map.put(relation("reviewers", %{}), :associations, %{
        region: %{queryable: :other_regions, owner_key: :id, related_key: :id}
      })
    )
    |> put_in(
      [:schemas, :other_regions],
      relation("other_regions", %{code: %{type: :string, choice_source: :state_choices}})
    )
    |> put_in([:joins, :reviewer], %{type: :left, joins: %{region: %{type: :left}}})
  end

  defp relation(table, columns),
    do: %{
      source_table: table,
      primary_key: :id,
      fields: [:id | Map.keys(columns)],
      columns: Map.put_new(columns, :id, %{type: :integer}),
      associations: %{}
    }
end
