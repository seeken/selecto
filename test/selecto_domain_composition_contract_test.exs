defmodule Selecto.Domain.CompositionContractTest do
  use ExUnit.Case, async: true

  alias Selecto.Domain
  alias Selecto.Domain.CompositionContract
  alias Selecto.Domain.CompositionFixtures
  alias Selecto.Domain.ConsumerProjectionRelease

  test "reference fixtures independently satisfy and compile the formal contract" do
    for {name, domain} <- CompositionFixtures.all() do
      assert match?({:ok, _normalized, _diagnostics}, Domain.validate(domain)), to_string(name)
      assert {:ok, contract} = CompositionContract.compile(domain)
      assert contract["schema"] == "selecto.composition_contract.v1"
      assert is_map(contract["relationships"])

      for {_id, relationship} <- contract["relationships"] do
        assert is_boolean(relationship["read"]["allowed"])
        assert is_boolean(relationship["offline"]["eligible"])
      end
    end
  end

  test "legacy owned sync metadata compiles to canonical full-set composition semantics" do
    domain =
      CompositionFixtures.order_document()
      |> update_in([:writes, :relationships, "items"], fn spec ->
        spec
        |> Map.put(:ownership, :owned)
        |> Map.put(:strategy, :sync)
        |> Map.put(:delete_missing, true)
        |> Map.delete(:write)
      end)

    assert {:ok, contract} = CompositionContract.compile(domain)
    items = contract["relationships"]["items"]

    assert items["ownership"] == "composition"
    assert items["write"]["modes"] == ["full_set"]
    assert items["write"]["omission"] == "delete_missing"
  end

  test "unsafe ownership, identity, read-bound, and offline combinations fail closed" do
    domain = CompositionFixtures.shared_tags()

    invalid =
      update_in(domain, [:writes, :relationships, "tags"], fn spec ->
        spec
        |> put_in([:write, :delete], true)
        |> put_in([:read, :max_rows], nil)
        |> Map.put(:identity_fields, [])
        |> Map.put(:offline, %{eligible: true})
        |> Map.delete(:idempotency)
        |> Map.delete(:conflict)
      end)

    assert {:error, diagnostics} = Domain.validate(invalid)
    codes = MapSet.new(diagnostics.errors, & &1.code)

    assert MapSet.member?(codes, :shared_relationship_target_mutation)
    assert MapSet.member?(codes, :nested_identity_required)
    assert MapSet.member?(codes, :nested_read_bounds_required)
    assert MapSet.member?(codes, :offline_nested_controls_required)
  end

  test "full-set omission and cardinality semantics cannot be inferred" do
    domain =
      CompositionFixtures.order_document()
      |> update_in([:writes, :relationships, "items", :write], &Map.delete(&1, :omission))
      |> update_in([:writes, :relationships, "items"], &Map.put(&1, :cardinality, :one))

    assert {:error, diagnostics} = Domain.validate(domain)
    codes = MapSet.new(diagnostics.errors, & &1.code)

    assert MapSet.member?(codes, :nested_omission_policy_required)
    assert MapSet.member?(codes, :invalid_relationship_cardinality_mode)
  end

  test "Order composition publishes field, cross-child, and aggregate validation policy" do
    assert {:ok, contract} =
             CompositionFixtures.order_document()
             |> CompositionContract.compile()

    validation = contract["relationships"]["items"]["validation"]

    assert validation["unique_fields"] == ["product_id"]

    assert validation["aggregate_rules"] == [
             %{
               "field" => "quantity",
               "maximum" => 100,
               "operation" => "sum",
               "representations" => ["full_set"]
             }
           ]

    features = CompositionContract.required_features(contract)
    assert "ordering_policy" not in features
    assert "validation:field_rules" in features
    assert "validation:unique_fields" in features
    assert "validation:aggregate_rules" in features
  end

  test "unknown validation concepts block a certified execution projection" do
    domain =
      CompositionFixtures.order_document()
      |> put_in(
        [:writes, :relationships, "items", :validation, :future_remote_rule],
        %{provider: "later"}
      )

    assert {:error,
            %{
              code: :unsupported_consumer_projection,
              missing_features: ["validation:future_remote_rule"]
            }} =
             ConsumerProjectionRelease.compile(domain,
               runtime: "selecto_updato",
               adapter: "postgresql",
               feature_scope: :execution
             )
  end

  test "unknown relationship concepts survive compilation and block execution publication" do
    domain =
      update_in(
        CompositionFixtures.vehicle_inspection(),
        [:writes, :relationships, "photos"],
        &Map.put(&1, :future_attachment_policy, %{mode: :quarantined})
      )

    assert {:ok, composition} = CompositionContract.compile(domain)

    assert composition["relationships"]["photos"]["extensions"] == %{
             "future_attachment_policy" => %{"mode" => "quarantined"}
           }

    assert {:error, %{code: :unsupported_nested_extensions}} =
             ConsumerProjectionRelease.compile(domain)

    assert {:ok, release} =
             ConsumerProjectionRelease.compile(domain,
               supported_extensions: ["future_attachment_policy"]
             )

    assert release["composition"] == composition
  end

  test "consumer releases are deterministic and reject incomplete target capability profiles" do
    domain = CompositionFixtures.order_document()
    assert {:ok, composition} = CompositionContract.compile(domain)
    features = CompositionContract.required_features(composition)

    assert {:error,
            %{
              code: :unsupported_consumer_projection,
              missing_features: missing
            }} =
             ConsumerProjectionRelease.compile(domain,
               projection_id: "order-editor",
               runtime: "selecto_updato",
               adapter: "postgresql"
             )

    assert "idempotency_policy" in missing

    assert {:ok, execution_release} =
             ConsumerProjectionRelease.compile(domain,
               projection_id: "order-executor",
               runtime: "selecto_updato",
               adapter: "postgresql",
               feature_scope: :execution
             )

    assert execution_release["feature_scope"] == "execution"
    assert "mutation:delta" in execution_release["required_features"]
    refute "nested_read" in execution_release["required_features"]

    opts = [
      projection_id: "order-editor",
      consumer: "components",
      runtime: "certified-order-client",
      adapter: "postgresql",
      supported_features: features
    ]

    assert {:ok, first} = ConsumerProjectionRelease.compile(domain, opts)
    assert {:ok, second} = ConsumerProjectionRelease.compile(domain, Enum.reverse(opts))
    assert first == second
    assert first["fingerprint"] =~ "sha256:"
  end

  test "consumer releases publish canonical operation and experience registries" do
    domain =
      CompositionFixtures.order_document()
      |> Map.put(:operations, %{
        approve: %{version: "1.0.0", fingerprint: "sha256:approve"}
      })
      |> Map.put(:experiences, %{
        "order-editor" => %{operation: :approve, layout: :document}
      })

    assert {:ok, release} = ConsumerProjectionRelease.compile(domain)

    assert release["operations"] == %{
             "approve" => %{"fingerprint" => "sha256:approve", "version" => "1.0.0"}
           }

    assert release["experiences"] == %{
             "order-editor" => %{"layout" => "document", "operation" => "approve"}
           }

    assert release["dependencies"]["operations"] == [
             %{
               "fingerprint" => "sha256:approve",
               "id" => "approve",
               "version" => "1.0.0"
             }
           ]
  end

  test "published capability profiles name finite live evidence and proof boundaries" do
    profiles = Domain.nested_capability_matrix()

    assert Enum.map(profiles, &{&1["runtime"], &1["adapter"]}) ==
             Enum.sort(Enum.map(profiles, &{&1["runtime"], &1["adapter"]}))

    assert postgresql =
             Enum.find(
               profiles,
               &(&1["runtime"] == "selecto_updato" and &1["adapter"] == "postgresql")
             )

    assert postgresql["implementation_status"] == "implemented"
    assert postgresql["live_certified_depth"] == 2
    assert postgresql["live_certified_graph_rows"] == 3
    assert postgresql["live_evidence"] != []
    assert postgresql["proof_boundary"] =~ "finite"
    refute "operation:reorder" in postgresql["implemented_features"]

    assert {:ok, release} =
             ConsumerProjectionRelease.compile(CompositionFixtures.order_document(),
               projection_id: "order-executor",
               runtime: "selecto_updato",
               adapter: "postgresql",
               feature_scope: :execution
             )

    assert release["target"]["certification"]["live_evidence"] ==
             postgresql["live_evidence"]
  end

  test "projection compatibility is relationship-specific and classifies breaking semantics" do
    domain = CompositionFixtures.order_document()
    assert {:ok, previous} = ConsumerProjectionRelease.compile(domain)

    narrowed =
      domain
      |> put_in([:writes, :relationships, "items", :write, :modes], [:delta])
      |> put_in([:writes, :relationships, "items", :write, :max_items], 50)

    assert {:ok, current} = ConsumerProjectionRelease.compile(narrowed)
    diff = ConsumerProjectionRelease.diff(previous, current)

    assert diff.classification == :breaking
    assert Enum.any?(diff.changes, &(&1.path == "items.write.modes"))
    assert Enum.any?(diff.changes, &(&1.path == "items.write.max_items"))
  end

  test "repeated physical targets retain distinct stable relationship roles" do
    assert {:ok, contract} =
             CompositionFixtures.deep_repeated_roles()
             |> CompositionContract.compile()

    bill_to = contract["relationships"]["bill_to"]
    ship_to = contract["relationships"]["ship_to"]

    assert bill_to["target"] == ship_to["target"]
    assert bill_to["path_id"] == "document.bill_to"
    assert ship_to["path_id"] == "document.ship_to"

    assert bill_to["relationships"]["addresses"]["path_id"] ==
             "document.bill_to.addresses"

    assert ship_to["relationships"]["addresses"]["path_id"] ==
             "document.ship_to.addresses"

    refute bill_to["path_id"] == ship_to["path_id"]
  end

  test "duplicate authored composition paths are rejected even when relationship ids differ" do
    domain =
      CompositionFixtures.deep_repeated_roles()
      |> put_in([:writes, :relationships, "ship_to", :path_id], "document.bill_to")

    assert {:error, [%{code: :duplicate_composition_path_id, path_ids: path_ids}]} =
             CompositionContract.compile(domain)

    assert path_ids == ["document.bill_to", "document.bill_to.addresses"]
  end
end
