defmodule Selecto.Write.DocumentMutationTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{Capabilities, Command, DocumentMutation, DocumentReceipt}

  defp mutation do
    %DocumentMutation{
      identity: %{path: ["_id"], value: "wo-1"},
      tenant: %{path: ["tenant_id"], value: "tenant-a"},
      version: %{path: ["version"], expected: 1},
      action: "reserve_part",
      idempotency_key: "request-1",
      payload_digest: DocumentMutation.digest("payload"),
      scope_digest: DocumentMutation.digest("scope"),
      shape_version: "work-orders/v1",
      shape_digest: DocumentMutation.digest("shape"),
      mutations: [
        %{
          op: :update_element,
          path: ["parts"],
          identity: %{path: ["part_id"], value: "part-1"},
          patch: [%{op: :increment, path: ["reserved"], value: 2}]
        }
      ],
      effects: ["work_orders.part_reserved/v1"]
    }
  end

  defp command do
    %Command{
      operation: :update,
      relation: "work_orders",
      predicate: {:eq, "id", "wo-1"},
      metadata: %{document: mutation()}
    }
  end

  test "requirements cannot be omitted from caller-supplied capability lists" do
    command = command()
    assert :ok = Command.validate(command)

    assert {:error, %{type: :write_capability_missing}} =
             Capabilities.require(%{protocol_version: 1, update: true}, command)

    assert Enum.all?(DocumentMutation.capabilities(), &(&1 in Capabilities.requirements(command)))

    capabilities =
      Map.new(DocumentMutation.capabilities(), &{&1, true})
      |> Map.merge(%{protocol_version: 1, update: true})

    assert :ok = Capabilities.require(capabilities, command)
  end

  test "document commands cannot weaken cardinality or combine scalar mutations" do
    for invalid <- [
          %{command() | operation: :delete},
          %{command() | expected_cardinality: :many},
          %{command() | assignments: [%{field: "version", value: 20}]}
        ] do
      assert {:error, _} = Command.validate(invalid)
    end
  end

  test "shape features require adapter support while original mutation capabilities remain unchanged" do
    original = mutation()
    assert original.shape_features == []
    assert DocumentMutation.capabilities(original) == DocumentMutation.capabilities()

    refined = %{original | shape_features: ["scalar_array"]}
    assert :ok = DocumentMutation.validate(refined)
    assert :document_scalar_array in DocumentMutation.capabilities(refined)
    command = %{command() | metadata: %{document: refined}}
    assert :ok = Command.validate(command)

    original_capabilities =
      Map.new(DocumentMutation.capabilities(), &{&1, true})
      |> Map.merge(%{protocol_version: 1, update: true})

    assert {:error, %{type: :write_capability_missing}} =
             Capabilities.require(original_capabilities, command)

    assert :ok =
             Capabilities.require(
               Map.put(original_capabilities, :document_scalar_array, true),
               command
             )

    for features <- [
          nil,
          "scalar_array",
          [:scalar_array],
          ["unknown"],
          ["scalar_array", "scalar_array"]
        ] do
      invalid = %{original | shape_features: features}
      assert {:error, _} = DocumentMutation.validate(invalid)
      assert {:error, _} = Command.validate(%{command | metadata: %{document: invalid}})
    end
  end

  test "finite path and amount matrix rejects protected, raw, positional and unsupported mutations" do
    paths = [
      ["parts"],
      ["_id"],
      ["tenant_id"],
      ["version"],
      ["_selecto_receipts"],
      ["parts.0"],
      ["parts", 0],
      ["$parts"],
      [],
      "parts"
    ]

    for path <- paths, amount <- [-1, 0, 1, 100, 101, nil, 1.5] do
      [entry] = mutation().mutations

      value = %{
        mutation()
        | mutations: [
            %{entry | path: path, patch: [%{op: :increment, path: ["reserved"], value: amount}]}
          ]
      }

      expected = path == ["parts"] and amount in [1, 100]
      assert DocumentMutation.validate(value) == :ok == expected
    end
  end

  test "owned object and combined shape refinements cannot bypass capability checks" do
    for features <- [["object_relation"], ["object_relation", "scalar_array"]] do
      mutation = %{mutation() | shape_features: features}
      assert :ok = DocumentMutation.validate(mutation)
      command = %{command() | metadata: %{document: mutation}}
      assert :document_object_relation in Capabilities.requirements(command)

      capabilities =
        Map.new(DocumentMutation.capabilities(mutation), &{&1, true})
        |> Map.merge(%{protocol_version: 1, update: true})

      assert :ok = Capabilities.require(capabilities, command)

      assert {:error, _} =
               Capabilities.require(Map.delete(capabilities, :document_object_relation), command)
    end

    for features <- [
          ["object_relation", "object_relation"],
          ["scalar_array", "object_relation"],
          ["object_relation", "unknown"]
        ] do
      assert {:error, _} = DocumentMutation.validate(%{mutation() | shape_features: features})
    end
  end

  test "explicit ObjectId selectors require their feature and preserve the existing tenant boundary" do
    alias Selecto.Document.Fixtures
    original = mutation()
    [element] = original.mutations

    value = %{
      original
      | identity: %{original.identity | value: Fixtures.object_id(1)},
        mutations: [%{element | identity: %{element.identity | value: Fixtures.object_id(101)}}],
        shape_features: ["object_id"]
    }

    assert :ok = DocumentMutation.validate(value)
    command = %{command() | metadata: %{document: value}}
    assert :document_object_id in Capabilities.requirements(command)

    capabilities =
      Map.new(DocumentMutation.capabilities(value), &{&1, true})
      |> Map.merge(%{protocol_version: 1, update: true})

    assert :ok = Capabilities.require(capabilities, command)

    assert {:error, _} =
             Capabilities.require(Map.delete(capabilities, :document_object_id), command)

    assert {:error, _} = DocumentMutation.validate(%{value | shape_features: []})

    assert {:error, _} =
             DocumentMutation.validate(%{
               value
               | tenant: %{value.tenant | value: Fixtures.object_id(9)}
             })

    assert :ok =
             DocumentMutation.validate(%{
               value
               | shape_features: ["object_id", "object_relation", "scalar_array"]
             })

    assert {:error, _} =
             DocumentMutation.validate(%{
               value
               | shape_features: ["object_relation", "object_id"]
             })

    assert {:error, _} =
             DocumentMutation.validate(%{value | shape_features: ["object_id", "object_id"]})

    for sample <- Enum.reject(Fixtures.object_id_cases(), & &1.valid), is_map(sample.value) do
      assert {:error, _} =
               DocumentMutation.validate(%{
                 value
                 | identity: %{value.identity | value: sample.value}
               })
    end

    # A typed declaration also requires support when no selected value uses it.
    assert :document_object_id in DocumentMutation.capabilities(%{
             original
             | shape_features: ["object_id"]
           })
  end

  test "metadata selectors, version and child identity remain protected" do
    [entry] = mutation().mutations

    for invalid <- [
          %{mutation() | version: %{path: ["version"], expected: -1}},
          %{mutation() | version: %{path: ["version"], expected: 9_223_372_036_854_775_807}},
          %{mutation() | tenant: %{path: ["_id", "tenant"], value: "tenant-a"}},
          %{
            mutation()
            | mutations: [%{entry | patch: [%{op: :increment, path: ["part_id"], value: 1}]}]
          },
          %{mutation() | mutations: [%{entry | identity: %{path: [0], value: "part-1"}}]},
          %{mutation() | effects: ["fact/v1", "fact/v1"]}
        ] do
      assert {:error, _} = DocumentMutation.validate(invalid)
    end
  end

  test "normalized receipt and effect identities are deterministic and scope bound" do
    receipt = DocumentReceipt.new(mutation(), %{name: "test", profile: "single_document"})
    assert receipt == DocumentReceipt.new(mutation(), %{name: "test", profile: "single_document"})
    assert receipt.matched == 1 and receipt.modified == 1 and receipt.version == 2
    assert [%{receipt_id: id, name: "work_orders.part_reserved/v1"}] = receipt.effects
    assert id == receipt.id

    other =
      DocumentReceipt.new(%{mutation() | scope_digest: DocumentMutation.digest("other")}, %{})

    refute other.id == receipt.id
  end
end
