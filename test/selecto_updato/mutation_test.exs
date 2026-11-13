defmodule SelectoUpdato.MutationTest do
  use ExUnit.Case, async: true
  alias SelectoUpdato.{Mutation, PortableCommand}

  test "root expressions preserve native intent and require adapter support" do
    operation =
      domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.update(%{"quantity" => Mutation.divide(Mutation.field("quantity"), 2)})

    assert {:ok, command, _} = PortableCommand.compile(operation)

    assert [
             %{
               value:
                 {:mutation,
                  {:divide, [{:field, "quantity", :integer}, {:literal, 2, :integer}], :integer}}
             }
           ] = command.assignments

    assert_raise ArgumentError, fn -> Mutation.literal(Mutation.field("quantity")) end
    assert :mutation_expressions in command.required_capabilities

    assert {:error, %{type: :write_capability_missing}} =
             Selecto.Write.Capabilities.require(%{protocol_version: 1, update: true}, command)
  end

  test "string domain upsert targets preserve unfamiliar declared field names without atoms" do
    key = "selecto_unfamiliar_owned_key_48019"
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

    authored = %{
      "source" => %{
        "source_table" => "items",
        "primary_key" => key,
        "fields" => [key, "name"],
        "columns" => %{key => %{"type" => "integer"}, "name" => %{"type" => "string"}}
      },
      "schemas" => %{},
      "writes" => %{
        "operations" => %{"upsert" => %{"enabled" => true, "conflict_targets" => [[key]]}},
        "fields" => %{
          key => %{"insertable" => true},
          "name" => %{"insertable" => true, "updatable" => true}
        }
      }
    }

    operation =
      authored
      |> SelectoUpdato.new()
      |> SelectoUpdato.upsert(%{key => 1, "name" => "ok"})
      |> SelectoUpdato.conflict_target([key])

    assert {:ok, command, _} = PortableCommand.compile(operation)
    assert command.metadata.conflict_target == [key]

    assert {:error, %{details: %{code: :conflict_target_not_declared}}} =
             PortableCommand.compile(%{operation | conflict_target: [%{"forged" => "key"}]})

    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  test "typed null and closed operator admission retain their precise failures" do
    operation =
      domain()
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.update(%{"name" => Mutation.null(:string)})

    assert {:ok, command, _} = PortableCommand.compile(operation)
    assert [%{value: {:mutation, {:literal, nil, :string}}}] = command.assignments

    for expression <- [
          Mutation.field("other.name"),
          Mutation.null(:unknown),
          %{"$mutation" => "coalesce", "args" => [Mutation.field("ghost"), "no"]},
          %{"$mutation" => "default"},
          %Mutation{node: {:literal, Mutation.field("name")}},
          %{"$mutation" => "literal", "value" => %{"$mutation" => "field", "name" => "name"}},
          Mutation.add("text", 1)
        ] do
      assert {:error, _} =
               PortableCommand.compile(%{operation | changes: %{"name" => expression}})
    end
  end

  test "a claimed protected record cannot authorize an unevaluated expression" do
    authored =
      Map.put(domain(), "rules", %{
        "schema" => "selecto.data_rules.v1",
        "definitions" => %{
          "nonnull" => %{"version" => 1, "test" => %{"op" => "presence.non_null"}}
        },
        "normalizers" => %{},
        "bindings" => %{
          "nonnull" => %{
            "subject" => %{"scope" => "candidate", "path" => ["quantity"]},
            "operations" => ["update"],
            "rule" => %{"id" => "nonnull", "version" => 1}
          }
        }
      })

    {:ok, contract} = Selecto.Domain.WriteContract.compile(authored)

    assignment = %{
      field: "quantity",
      value:
        {:mutation, {:add, [{:field, "quantity", :integer}, {:literal, 1, :integer}], :integer}}
    }

    assert {:error, %{details: %{code: :required_data_rule_pending}}} =
             SelectoUpdato.RuleValidation.validate_storage_candidate(
               :update,
               contract,
               [assignment],
               rule_candidate_types: %{
                 "id" => :integer,
                 "quantity" => :integer,
                 "name" => :string
               },
               native_rule_candidate?: false,
               record_state_provider: fn _ ->
                 {:ok,
                  %Selecto.Write.RecordState{
                    values: %{"quantity" => nil},
                    complete?: true,
                    protection: :serializable
                  }}
               end,
               record_state_request: :claimed
             )
  end

  defp domain do
    %{
      "source" => %{
        "source_table" => "items",
        "primary_key" => "id",
        "fields" => ["id", "quantity", "name"],
        "columns" => %{
          "id" => %{"type" => "integer"},
          "quantity" => %{"type" => "integer"},
          "name" => %{"type" => "string"}
        }
      },
      "schemas" => %{},
      "writes" => %{
        "operations" => %{"insert" => %{"enabled" => true}, "update" => %{"enabled" => true}},
        "fields" => %{
          "id" => %{"insertable" => true},
          "quantity" => %{"insertable" => true, "updatable" => true},
          "name" => %{"insertable" => true, "updatable" => true}
        }
      }
    }
  end
end
