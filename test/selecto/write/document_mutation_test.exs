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
