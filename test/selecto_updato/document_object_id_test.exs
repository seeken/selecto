defmodule SelectoUpdato.DocumentObjectIdTest do
  use ExUnit.Case, async: false

  alias Selecto.Document.{Fixtures, ObjectId, ShapeRelease}
  alias Selecto.Write.{DocumentMutation, DocumentReceipt, Result}
  alias SelectoUpdato.{ActionExecutionAdapter, DocumentActionExample, PlannedOperation}

  @root_hex "507f1f77bcf86cd799439011"
  @part_hex "507f1f77bcf86cd799439012"

  defmodule RecordingAdapter do
    def write_capabilities(_connection) do
      DocumentMutation.capabilities()
      |> Map.new(&{&1, true})
      |> Map.merge(%{
        protocol_version: 1,
        update: true,
        document_object_relation: true,
        document_object_id: true
      })
    end

    def execute_write(_connection, command, _opts) do
      send(self(), {:object_id_command, command})

      receipt =
        DocumentReceipt.new(command.metadata.document, %{name: "recording", profile: "object_id"})

      {:ok,
       %Result{
         operation: :update,
         affected_rows: 1,
         metadata: %{receipt: receipt, committed_effects: receipt.effects}
       }}
    end

    def preview_write(_connection, command, _opts) do
      send(self(), {:object_id_preview, command})
      {:ok, %Selecto.Write.Preview{statements: [], metadata: %{operation: :reserve_part}}}
    end
  end

  defmodule NoObjectIdAdapter do
    def write_capabilities(connection),
      do: Map.delete(RecordingAdapter.write_capabilities(connection), :document_object_id)

    def execute_write(_connection, _command, _opts), do: raise("must reject before dispatch")
  end

  defmodule HostAdapter do
    def execute_action(plan, context, opts) do
      SelectoUpdato.execute(
        plan.operation_builder,
        %Selecto{
          adapter: Keyword.get(opts, :write_adapter, RecordingAdapter),
          connection: :recording
        },
        context: context
      )
    end

    def dry_run_action(plan, context, _opts) do
      SelectoUpdato.preview(
        plan.operation_builder,
        %Selecto{adapter: RecordingAdapter, connection: :recording},
        context: context
      )
    end
  end

  defmodule VendorIdentity do
    defstruct [:value]
  end

  defp object_id(hex) do
    {:ok, value} = ObjectId.new(hex)
    value
  end

  defp intent do
    %{
      action: :reserve_part,
      target: %{id: object_id(@root_hex)},
      inputs: %{
        part_id: object_id(@part_hex),
        quantity: 1,
        expected_version: 1,
        idempotency_key: "object-id-reserve"
      }
    }
  end

  defp context, do: %{tenant_id: "tenant-a", actor: %{id: "operator"}}
  defp resolver, do: fn _, _, _ -> :enabled end

  defp execute(domain, intent) do
    assert {:ok, plan} = SelectoUpdato.plan_domain_action(domain, intent)

    assert {:ok, result} =
             ActionExecutionAdapter.execute(HostAdapter, plan, context(),
               capability_resolver: resolver()
             )

    assert_receive {:object_id_command, command}
    {command, result}
  end

  test "explicit ObjectId domain inputs survive ordinary authorized planning and execution" do
    domain = DocumentActionExample.object_id_domain()
    assert {:ok, contract, _} = SelectoUpdato.domain_contract(domain)
    action = Enum.find(contract.actions, &(&1.id == "reserve_part"))
    assert Enum.find(action.inputs, &(&1.id == "part_id")).type == :object_id
    assert {:ok, plan} = SelectoUpdato.plan_domain_action(domain, intent())
    assert %PlannedOperation{} = plan.operation_builder
    assert plan.inputs["part_id"] == object_id(@part_hex)
    assert {"id", object_id(@root_hex)} in plan.filters

    {command, result} = execute(domain, intent())
    mutation = command.metadata.document
    assert mutation.identity.value == object_id(@root_hex)
    assert [%{identity: %{value: child_identity}}] = mutation.mutations
    assert child_identity == object_id(@part_hex)
    assert "object_id" in mutation.shape_features
    assert :document_object_id in Selecto.Write.Capabilities.requirements(command)
    assert result.metadata.receipt.target == object_id(@root_hex)
    assert [%{target: effect_target}] = result.metadata.committed_effects
    assert effect_target == object_id(@root_hex)
    receipt_json = result.metadata.receipt |> Jason.encode!() |> Jason.decode!()
    assert receipt_json["target"] == object_id(@root_hex)
    assert [%{"target" => encoded_target}] = receipt_json["effects"]
    assert encoded_target == object_id(@root_hex)
  end

  test "an unpublished ObjectId field requires support even when both selectors remain strings" do
    hidden_field = %{
      "path" => ["audit_ref"],
      "type" => "object_id",
      "required" => false,
      "nullable" => true,
      "missing" => "preserve",
      "filterable" => false,
      "sortable" => false,
      "server_managed" => true
    }

    shape =
      Fixtures.shape()
      |> Map.put("id", "work-orders/hidden-object-id-v1")
      |> put_in(["shape", "fields", "audit_ref"], hidden_field)

    assert {:ok, draft} = ShapeRelease.new(shape)
    assert {:ok, release} = ShapeRelease.approve(draft, approved_by: "synthetic-author")
    refute "audit_ref" in release["relations"]["work_orders"]["fields"]
    domain = DocumentActionExample.domain(release)
    request = intent() |> put_in([:target, :id], "wo-1") |> put_in([:inputs, :part_id], "part-1")
    assert {:ok, plan} = SelectoUpdato.plan_domain_action(domain, request)

    assert {:error, %{type: :write_capability_missing}} =
             ActionExecutionAdapter.execute(HostAdapter, plan, context(),
               capability_resolver: resolver(),
               write_adapter: NoObjectIdAdapter
             )

    refute_receive {:object_id_command, _}

    {command, _result} = execute(domain, request)
    assert command.metadata.document.shape_features == ["object_id"]
    assert command.metadata.document.identity.value == "wo-1"
    assert [%{identity: %{value: "part-1"}}] = command.metadata.document.mutations
    assert :document_object_id in Selecto.Write.Capabilities.requirements(command)
  end

  test "preview preserves canonical tags and capability absence rejects before adapter dispatch" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(DocumentActionExample.object_id_domain(), intent())

    assert {:ok, _} =
             ActionExecutionAdapter.dry_run(HostAdapter, plan, context(),
               capability_resolver: resolver()
             )

    assert_receive {:object_id_preview, command}
    assert command.metadata.document.identity.value == object_id(@root_hex)

    assert {:error, %{type: :write_capability_missing}} =
             ActionExecutionAdapter.execute(HostAdapter, plan, context(),
               capability_resolver: resolver(),
               write_adapter: NoObjectIdAdapter
             )

    refute_receive {:object_id_command, _}
  end

  test "malformed, native, extra-key and string lookalike identities are never implicitly coerced" do
    for invalid <- [
          @root_hex,
          nil,
          1,
          <<0::96>>,
          %{"$oid" => @root_hex},
          %VendorIdentity{value: @root_hex},
          %{"$bson" => "object_id", "value" => String.upcase(@root_hex)},
          %{"$bson" => "object_id", "value" => "507f1f77bcf86cd79943901g"},
          %{"$bson" => "object_id", "value" => @root_hex, "$ne" => nil},
          %{bson: "object_id", value: @root_hex}
        ] do
      domain = DocumentActionExample.object_id_domain()

      assert {:error, _} =
               SelectoUpdato.plan_domain_action(domain, put_in(intent(), [:target, :id], invalid))

      assert {:error, _} =
               SelectoUpdato.plan_domain_action(
                 domain,
                 put_in(intent(), [:inputs, :part_id], invalid)
               )
    end
  end

  test "published identity types are enforced even when the authored domain input type is misleading" do
    release = Fixtures.object_id_release()
    string_domain = DocumentActionExample.domain(release)
    request = intent() |> put_in([:target, :id], @root_hex)
    assert {:error, _} = SelectoUpdato.plan_domain_action(string_domain, request)
    request = intent() |> put_in([:inputs, :part_id], @part_hex)
    assert {:error, _} = SelectoUpdato.plan_domain_action(string_domain, request)

    # Declaring an input tag does not turn a release's string identity into an ObjectId.
    mismatched = DocumentActionExample.object_id_domain(Fixtures.release())
    assert {:error, _} = SelectoUpdato.plan_domain_action(mismatched, intent())

    child_mismatch =
      DocumentActionExample.object_id_domain(Fixtures.release())
      |> put_in([:source, :columns, :id, :type], :string)

    assert {:error, _} =
             SelectoUpdato.plan_domain_action(
               child_mismatch,
               put_in(intent(), [:target, :id], "wo-1")
             )
  end

  test "identity tags keep idempotency scopes and receipts distinct from identical string characters" do
    {tagged, tagged_result} = execute(DocumentActionExample.object_id_domain(), intent())

    string_intent =
      intent() |> put_in([:target, :id], @root_hex) |> put_in([:inputs, :part_id], @part_hex)

    {string, string_result} = execute(DocumentActionExample.domain(), string_intent)

    refute tagged.metadata.document.scope_digest == string.metadata.document.scope_digest
    refute tagged.metadata.document.payload_digest == string.metadata.document.payload_digest
    refute tagged_result.metadata.receipt.id == string_result.metadata.receipt.id
    {same, same_result} = execute(DocumentActionExample.object_id_domain(), intent())
    assert tagged.metadata.document.payload_digest == same.metadata.document.payload_digest
    assert tagged_result.metadata.receipt.id == same_result.metadata.receipt.id
  end

  test "authorization cannot be bypassed or altered by using tagged targets" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(DocumentActionExample.object_id_domain(), intent())

    assert {:error, _} = ActionExecutionAdapter.execute(HostAdapter, plan, context())
    assert {:error, _} = SelectoUpdato.execute(plan.operation_builder, %Selecto{})
    altered = %{plan | target: %{id: object_id("507f1f77bcf86cd799439099")}}

    assert {:error, _} =
             ActionExecutionAdapter.execute(HostAdapter, altered, context(),
               capability_resolver: resolver()
             )

    refute_receive {:object_id_command, _}
  end
end
