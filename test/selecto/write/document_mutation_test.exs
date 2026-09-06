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

  test "legacy increment struct and deterministic digest remain unchanged" do
    assert DocumentMutation.digest(mutation()) ==
             "0acd852ec0877979bc80246a47bd70b3def99681d5211142ef3f08f801b0db8a"

    refute DocumentMutation.root_patch?(mutation())
    assert DocumentMutation.capabilities(mutation()) == DocumentMutation.capabilities()
  end

  defp root_patch(entries), do: %{mutation() | mutations: entries}

  test "root scalar patches have exact entries, portable values, and operation-derived capabilities" do
    values = ["", "a\n\"\\é", 0, -9_007_199_254_740_991, 9_007_199_254_740_991, true, false, nil]

    for value <- values do
      patch = root_patch([%{op: :set, path: ["title"], value: value}])
      assert DocumentMutation.scalar_value?(value)
      assert DocumentMutation.root_patch?(patch)
      assert :ok = DocumentMutation.validate(patch)
      assert :document_set in DocumentMutation.capabilities(patch)
      refute :document_unset in DocumentMutation.capabilities(patch)
      refute :document_update_element in DocumentMutation.capabilities(patch)
    end

    unset = root_patch([%{op: :unset, path: ["schedule", "due_at"]}])
    assert :ok = DocumentMutation.validate(unset)
    assert :document_unset in DocumentMutation.capabilities(unset)
    refute :document_set in DocumentMutation.capabilities(unset)

    both = root_patch([%{op: :set, path: ["title"], value: "new"} | unset.mutations])
    assert :ok = DocumentMutation.validate(both)
    command = %{command() | metadata: %{document: both}, required_capabilities: []}
    assert :ok = Command.validate(command)
    requirements = Capabilities.requirements(command)
    assert :document_set in requirements and :document_unset in requirements

    capabilities =
      Map.new(DocumentMutation.capabilities(both), &{&1, true})
      |> Map.merge(%{protocol_version: 1, update: true})

    assert :ok = Capabilities.require(capabilities, command)

    for capability <- [:document_set, :document_unset] do
      assert {:error, %{type: :write_capability_missing}} =
               Capabilities.require(Map.delete(capabilities, capability), command)
    end
  end

  test "root patch strings and aggregate value bytes are bounded independently" do
    largest = String.duplicate("x", 16_384)
    entries = for index <- 1..4, do: %{op: :set, path: ["field#{index}"], value: largest}
    assert {:ok, 16_384} = DocumentMutation.scalar_value_bytes(largest)
    assert :ok = DocumentMutation.validate(root_patch(entries))

    assert {:error, _} =
             DocumentMutation.validate(
               root_patch(entries ++ [%{op: :set, path: ["extra"], value: 0}])
             )

    for invalid <- [
          largest <> "x",
          <<255>>,
          9_007_199_254_740_992,
          -9_007_199_254_740_992,
          1.0,
          :value,
          [],
          %{},
          %Selecto.Document.Missing{},
          fn -> nil end
        ] do
      refute DocumentMutation.scalar_value?(invalid)
      assert {:error, :invalid_document_scalar} = DocumentMutation.scalar_value_bytes(invalid)

      assert {:error, _} =
               DocumentMutation.validate(
                 root_patch([%{op: :set, path: ["title"], value: invalid}])
               )
    end

    assert {:ok, 2} = DocumentMutation.scalar_value_bytes("é")
    assert {:ok, 4} = DocumentMutation.scalar_value_bytes(nil)
    assert {:ok, 5} = DocumentMutation.scalar_value_bytes(false)
  end

  test "root patch ObjectId values require the feature even when all selectors remain strings" do
    value = Selecto.Document.Fixtures.object_id(8)
    patch = root_patch([%{op: :set, path: ["customer_id"], value: value}])
    assert {:error, _} = DocumentMutation.validate(patch)
    patch = %{patch | shape_features: ["object_id"]}
    assert :ok = DocumentMutation.validate(patch)
    assert :document_object_id in DocumentMutation.capabilities(patch)

    assert {:ok, bytes} = DocumentMutation.scalar_value_bytes(value)
    assert bytes == byte_size(Selecto.Document.Canonical.encode(value))

    for invalid <- [
          Map.put(value, "extra", true),
          Map.put(value, "value", String.upcase("abcdef0123456789abcdef01"))
        ] do
      assert {:error, _} =
               DocumentMutation.validate(%{
                 patch
                 | mutations: [%{op: :set, path: ["customer_id"], value: invalid}]
               })
    end
  end

  test "root patches reject overlapping and protected paths, mixed profiles, and extra native syntax" do
    [element] = mutation().mutations
    valid = %{op: :set, path: ["title"], value: "new"}

    for entries <- [
          [],
          [valid, valid],
          [valid, %{op: :unset, path: ["title", "child"]}],
          [valid, %{op: :unset, path: ["title"]}],
          [valid, element],
          [Map.put(valid, :native, %{"$set" => %{}})],
          [Map.delete(valid, :value)],
          [%{op: :unset, path: ["title"], value: nil}],
          [%{op: :set, path: ["title"], value: nil, __struct__: Date}],
          [%{"op" => "set", "path" => ["title"], "value" => "new"}],
          [nil],
          [1 | :invalid],
          for(index <- 1..9, do: %{op: :unset, path: ["field#{index}"]})
        ] do
      assert {:error, _} = DocumentMutation.validate(root_patch(entries))
    end

    eight = for index <- 1..8, do: %{op: :unset, path: ["field#{index}"]}
    assert :ok = DocumentMutation.validate(root_patch(eight))

    for path <- [
          ["_id"],
          ["tenant_id"],
          ["version"],
          ["_selecto_receipts"],
          ["_id", "value"],
          ["_selecto_receipts", "receipt"],
          ["$title"],
          ["a.b"],
          ["a", 0],
          [],
          "title"
        ] do
      assert {:error, _} = DocumentMutation.validate(root_patch([%{valid | path: path}]))
    end

    nested_version = %{
      root_patch([%{op: :unset, path: ["meta"]}])
      | version: %{path: ["meta", "version"], expected: 1}
    }

    assert {:error, _} = DocumentMutation.validate(nested_version)

    assert :ok = DocumentMutation.validate(root_patch([%{valid | path: ["_id_suffix"]}]))

    for invalid <- [nil, %{}, [], %{mutations: [valid]}, %{mutation() | mutations: nil}],
        do: refute(DocumentMutation.root_patch?(invalid))
  end

  test "root selected returning is bounded and cannot omit postimage or returning support" do
    patch = root_patch([%{op: :set, path: ["title"], value: "new"}])
    command = %{command() | metadata: %{document: patch}, returning: ["title", "due_at"]}
    assert :ok = Command.validate(command)
    required = Capabilities.requirements(command)
    assert :document_postimage in required
    assert {:returning, :update} in required

    # A graph's suppression of its overall returned row cannot suppress the
    # requirements of a selected postimage persisted by an inner command.
    alias Selecto.Write.Graph
    alias Selecto.Write.Graph.{Node, Row}

    graph = %Graph{
      nodes: [
        %Node{
          id: "root",
          path: [],
          relation: "work_orders",
          strategy: :ordered,
          rows: [%Row{id: "one", path: [], command: command}]
        }
      ],
      root: {"root", "one"},
      metadata: %{root_returning: :none}
    }

    assert :ok = Graph.validate(graph)
    assert :document_postimage in Capabilities.requirements(graph)
    assert {:returning, :update} in Capabilities.requirements(graph)

    capabilities =
      Map.new(DocumentMutation.capabilities(patch), &{&1, true})
      |> Map.merge(%{
        protocol_version: 1,
        update: true,
        document_postimage: true,
        returning: %{update: true}
      })

    assert :ok = Capabilities.require(capabilities, command)

    for capability <- [:document_postimage, :returning] do
      assert {:error, %{type: :write_capability_missing}} =
               Capabilities.require(Map.delete(capabilities, capability), command)
    end

    for returning <- [
          :all,
          [],
          [:title],
          ["title", "title"],
          ["$title"],
          ["a.b"],
          Enum.map(1..17, &"field#{&1}")
        ] do
      assert {:error, _} = Command.validate(%{command | returning: returning})
    end

    assert :ok = Command.validate(%{command | returning: Enum.map(1..16, &"field#{&1}")})
    refute :document_postimage in Capabilities.requirements(%{command | returning: :none})
    assert :ok = Command.validate(%{command | returning: :none})
    assert :ok = Command.validate(%{command() | returning: :all})
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
