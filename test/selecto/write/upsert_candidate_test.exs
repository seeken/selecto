defmodule Selecto.Write.UpsertCandidateTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{Capabilities, Command, UpsertCandidateRequest, UpsertCandidateState}

  test "request carries actual command identity, dependencies and private receipt continuity" do
    {:ok, command} =
      Command.new(%{
        operation: :upsert,
        relation: "items",
        assignments: [%{field: "id", value: {:literal, 1}}],
        metadata: %{conflict_target: ["id"], upsert_update_fields: []},
        required_capabilities: [:upsert, :protected_upsert_candidates]
      })

    subject = make_ref()

    request = %UpsertCandidateRequest{
      command: command,
      field_types: %{"id" => :integer},
      dependencies: ["id"],
      context: %{tenant_id: 7},
      subject: subject
    }

    receipt = make_ref()
    later = %{request | prior: receipt}
    assert later.command === command
    assert later.subject === subject
    assert later.prior === receipt
    assert request.prior == nil

    ordinary = %{protocol_version: 1, upsert: true, native_rule_candidates: true}

    assert {:error, %{details: %{missing: [:protected_upsert_candidates]}}} =
             Capabilities.require(ordinary, command)

    assert :ok =
             Capabilities.require(Map.put(ordinary, :protected_upsert_candidates, true), command)
  end

  test "state distinguishes absent insert, conflict update and conflict no-op" do
    for {branch, effect, prior} <- [
          {:insert, :insert, %{}},
          {:conflict, :update, %{"id" => 1}},
          {:conflict, :nothing, %{"id" => 1}}
        ] do
      state = %UpsertCandidateState{
        values: %{"id" => 1},
        prior_values: prior,
        branch: branch,
        effect: effect,
        receipt: make_ref()
      }

      assert state.complete? == false
      assert state.protection == :unprotected
      assert state.branch == branch
      assert state.effect == effect
      assert state.prior_values == prior
    end
  end
end
