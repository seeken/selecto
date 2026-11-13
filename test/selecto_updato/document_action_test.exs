defmodule SelectoUpdato.DocumentActionTest do
  use ExUnit.Case, async: false

  alias Selecto.Write.{Command, DocumentMutation, DocumentReceipt, Result}
  alias SelectoUpdato.{ActionExecutionAdapter, DocumentActionExample, PlannedOperation}

  defmodule RecordingAdapter do
    def write_capabilities(_connection) do
      DocumentMutation.capabilities()
      |> Map.new(&{&1, true})
      |> Map.merge(%{protocol_version: 1, update: true})
    end

    def execute_write(_connection, %Command{} = command, _opts) do
      send(self(), {:document_command, command})

      receipt =
        DocumentReceipt.new(command.metadata.document, %{name: "recording", profile: "test"})

      {:ok,
       %Result{
         operation: :update,
         affected_rows: 1,
         metadata: %{receipt: receipt, committed_effects: receipt.effects}
       }}
    end

    def preview_write(_connection, command, _opts) do
      send(self(), {:document_preview, command})
      {:ok, %Selecto.Write.Preview{statements: [], metadata: %{operation: :reserve_part}}}
    end
  end

  defmodule HostAdapter do
    def execute_action(plan, context, opts) do
      adapter = Keyword.get(opts, :write_adapter, RecordingAdapter)

      SelectoUpdato.execute(
        plan.operation_builder,
        %Selecto{adapter: adapter, connection: :test},
        context: context
      )
    end

    def dry_run_action(plan, context, _opts) do
      SelectoUpdato.preview(
        plan.operation_builder,
        %Selecto{adapter: RecordingAdapter, connection: :test},
        context: context
      )
    end
  end

  defmodule ScalarAdapter do
    def write_capabilities(_), do: %{protocol_version: 1, update: true}
    def execute_write(_, _, _), do: raise("must fail before dispatch")
  end

  defmodule TypedArrayAdapter do
    def write_capabilities(connection),
      do: Map.put(RecordingAdapter.write_capabilities(connection), :document_scalar_array, true)

    defdelegate execute_write(connection, command, opts), to: RecordingAdapter
    defdelegate preview_write(connection, command, opts), to: RecordingAdapter
  end

  defmodule ObjectRelationAdapter do
    def write_capabilities(connection),
      do:
        Map.put(RecordingAdapter.write_capabilities(connection), :document_object_relation, true)

    defdelegate execute_write(connection, command, opts), to: RecordingAdapter
    defdelegate preview_write(connection, command, opts), to: RecordingAdapter
  end

  defmodule RefinedObjectAdapter do
    def write_capabilities(connection),
      do:
        Map.put(
          ObjectRelationAdapter.write_capabilities(connection),
          :document_scalar_array,
          true
        )

    defdelegate execute_write(connection, command, opts), to: RecordingAdapter
    defdelegate preview_write(connection, command, opts), to: RecordingAdapter
  end

  defp intent(overrides \\ %{}) do
    %{
      action: :reserve_part,
      target: %{id: "wo-1"},
      inputs:
        Map.merge(
          %{
            part_id: "part-1",
            quantity: 2,
            expected_version: 1,
            idempotency_key: "reserve-first"
          },
          overrides
        )
    }
  end

  defp context, do: %{tenant_id: "tenant-a", actor: %{id: "operator"}}
  defp resolver, do: fn _request, _context, _opts -> :enabled end

  test "normal action authorization binds trusted scope and emits portable mutation and effects" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(DocumentActionExample.domain(), intent())

    assert %PlannedOperation{} = plan.operation_builder

    assert {:ok, %Result{} = result} =
             ActionExecutionAdapter.execute(HostAdapter, plan, context(),
               capability_resolver: resolver()
             )

    assert_receive {:document_command, command}
    assert command.operation == :update
    assert command.assignments == []

    assert command.predicate ==
             {:and,
              [
                {:eq, {:field, "id"}, {:literal, "wo-1"}},
                {:eq, {:field, "tenant_id"}, {:literal, "tenant-a"}}
              ]}

    assert %DocumentMutation{} = mutation = command.metadata.document
    assert mutation.identity == %{path: ["_id"], value: "wo-1"}
    assert mutation.tenant == %{path: ["tenant_id"], value: "tenant-a"}
    assert mutation.version == %{path: ["version"], expected: 1}
    assert mutation.shape_digest == Selecto.Document.Fixtures.release()["digest"]
    assert [%{patch: [%{op: :increment, path: ["reserved"], value: 2}]}] = mutation.mutations
    assert result.metadata.receipt.version == 2
    assert [%{name: "work_orders.part_reserved/v1"}] = result.metadata.committed_effects
  end

  test "preview uses the same boundary, and capability denial never dispatches" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(DocumentActionExample.domain(), intent())

    assert {:ok, _} =
             ActionExecutionAdapter.dry_run(HostAdapter, plan, context(),
               capability_resolver: resolver()
             )

    assert_receive {:document_preview, _}
    assert {:error, _} = ActionExecutionAdapter.execute(HostAdapter, plan, context())

    assert {:error, _} =
             ActionExecutionAdapter.execute(HostAdapter, plan, context(),
               capability_resolver: fn _, _, _ -> :disabled end
             )

    refute_receive {:document_command, _}
  end

  test "idempotency payload binds effective filters as well as mutation and scope" do
    digests =
      for version <- [1, 2] do
        request = Map.put(intent(), :filters, [{:version, version}])

        assert {:ok, plan} =
                 SelectoUpdato.plan_domain_action(DocumentActionExample.domain(), request)

        assert {:ok, _} =
                 ActionExecutionAdapter.execute(HostAdapter, plan, context(),
                   capability_resolver: resolver()
                 )

        assert_receive {:document_command, command}
        command.metadata.document.payload_digest
      end

    assert length(Enum.uniq(digests)) == 2
  end

  test "missing scope and adapter capability fail closed" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(DocumentActionExample.domain(), intent())

    assert {:error, _} =
             ActionExecutionAdapter.execute(HostAdapter, plan, %{},
               capability_resolver: resolver()
             )

    assert {:error, %{type: :write_capability_missing}} =
             ActionExecutionAdapter.execute(HostAdapter, plan, context(),
               capability_resolver: resolver(),
               write_adapter: ScalarAdapter
             )

    refute_receive {:document_command, _}
  end

  test "typed shape features require adapter support through ordinary action authorization" do
    release = Selecto.Document.Fixtures.scalar_array_release()

    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(DocumentActionExample.domain(release), intent())

    assert {:error, %{type: :write_capability_missing}} =
             ActionExecutionAdapter.execute(HostAdapter, plan, context(),
               capability_resolver: resolver()
             )

    refute_receive {:document_command, _}

    assert {:ok, _} =
             ActionExecutionAdapter.execute(HostAdapter, plan, context(),
               capability_resolver: resolver(),
               write_adapter: TypedArrayAdapter
             )

    assert_receive {:document_command, command}
    assert command.metadata.document.shape_features == ["scalar_array"]
    assert :document_scalar_array in Selecto.Write.Capabilities.requirements(command)
  end

  test "feature-free releases retain the original persisted idempotency payload encoding" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(DocumentActionExample.domain(), intent())

    assert {:ok, _} =
             ActionExecutionAdapter.execute(HostAdapter, plan, context(),
               capability_resolver: resolver()
             )

    assert_receive {:document_command, command}
    mutation = command.metadata.document
    assert mutation.shape_features == []

    original_mutation =
      mutation
      |> Map.delete(:shape_features)
      |> Map.put(:payload_digest, "")
      |> Map.put(:idempotency_key, "")

    assert mutation.payload_digest ==
             DocumentMutation.digest(%{
               mutation: original_mutation,
               relation: command.relation,
               predicate: command.predicate,
               expected_cardinality: command.expected_cardinality,
               returning: command.returning,
               domain_fingerprint: command.metadata[:domain_fingerprint]
             })
  end

  test "owned object shape rules require support before an existing array action dispatches" do
    release = Selecto.Document.Fixtures.object_relation_release()

    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(DocumentActionExample.domain(release), intent())

    for adapter <- [RecordingAdapter, TypedArrayAdapter] do
      assert {:error, %{type: :write_capability_missing}} =
               ActionExecutionAdapter.execute(HostAdapter, plan, context(),
                 capability_resolver: resolver(),
                 write_adapter: adapter
               )

      refute_receive {:document_command, _}
    end

    assert {:ok, _} =
             ActionExecutionAdapter.execute(HostAdapter, plan, context(),
               capability_resolver: resolver(),
               write_adapter: ObjectRelationAdapter
             )

    assert_receive {:document_command, command}
    assert command.metadata.document.shape_features == ["object_relation"]
    assert :document_object_relation in Selecto.Write.Capabilities.requirements(command)
    assert [%{op: :update_element}] = command.metadata.document.mutations
  end

  test "typed arrays within an owned object require both refinements on an unrelated array action" do
    alias Selecto.Document.{Fixtures, ShapeRelease}

    array_field =
      get_in(Fixtures.scalar_array_shape(), ["relations", "work_order_parts", "fields", "labels"])

    shape =
      Fixtures.object_relation_shape()
      |> Map.put("id", "work-orders/object-action-refinements-v1")
      |> put_in(["relations", "work_order_schedule", "fields", "labels"], array_field)

    assert {:ok, draft} = ShapeRelease.new(shape)
    assert {:ok, release} = ShapeRelease.approve(draft, approved_by: "synthetic-action-author")

    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(DocumentActionExample.domain(release), intent())

    for adapter <- [ObjectRelationAdapter, TypedArrayAdapter] do
      assert {:error, %{type: :write_capability_missing}} =
               ActionExecutionAdapter.execute(HostAdapter, plan, context(),
                 capability_resolver: resolver(),
                 write_adapter: adapter
               )

      refute_receive {:document_command, _}
    end

    assert {:ok, _} =
             ActionExecutionAdapter.execute(HostAdapter, plan, context(),
               capability_resolver: resolver(),
               write_adapter: RefinedObjectAdapter
             )

    assert_receive {:document_command, command}
    assert command.metadata.document.shape_features == ["object_relation", "scalar_array"]
    requirements = Selecto.Write.Capabilities.requirements(command)
    assert :document_object_relation in requirements
    assert :document_scalar_array in requirements
  end

  test "caller cannot compile opaque or tampered action plans" do
    assert {:ok, plan} =
             SelectoUpdato.plan_domain_action(DocumentActionExample.domain(), intent())

    assert {:error, _} = SelectoUpdato.execute(plan.operation_builder, %Selecto{})

    assert {:error, _} =
             ActionExecutionAdapter.execute(
               HostAdapter,
               %{plan | inputs: Map.put(plan.inputs, "quantity", 99)},
               context(),
               capability_resolver: resolver()
             )

    refute_receive {:document_command, _}
  end

  test "invalid versions, idempotency and amounts never produce plans" do
    for overrides <- [
          %{quantity: 0},
          %{quantity: -1},
          %{quantity: 101},
          %{expected_version: -1},
          %{expected_version: nil},
          %{idempotency_key: ""}
        ] do
      assert {:error, _} =
               SelectoUpdato.plan_domain_action(DocumentActionExample.domain(), intent(overrides))
    end
  end

  test "approved shape alone does not authorize mutations" do
    domain =
      put_in(DocumentActionExample.domain(), [:writes, :fields, :parts, :document_actions], [])

    assert {:error, _} = SelectoUpdato.plan_domain_action(domain, intent())
    domain = DocumentActionExample.domain(Selecto.Document.Fixtures.shape())
    assert {:error, _} = SelectoUpdato.plan_domain_action(domain, intent())
  end

  test "protected and undeclared paths, positional identity and raw syntax are rejected" do
    for path <- [
          ["_id"],
          ["tenant_id"],
          ["version"],
          ["kind"],
          ["_selecto_receipts"],
          ["unknown"],
          ["parts.0"],
          ["$parts"],
          [0]
        ] do
      domain =
        update_in(
          DocumentActionExample.domain(),
          [:actions, :reserve_part, :execution, :document, :mutations],
          fn [mutation] ->
            [%{mutation | path: path}]
          end
        )

      assert {:error, _} = SelectoUpdato.plan_domain_action(domain, intent())
    end

    for path <- [["part_id"], ["unknown"], ["reserved", "$inc"]] do
      domain =
        update_in(
          DocumentActionExample.domain(),
          [:actions, :reserve_part, :execution, :document, :mutations],
          fn [mutation] ->
            [%{mutation | patch: [%{op: :increment, path: path, value_from: :quantity}]}]
          end
        )

      assert {:error, _} = SelectoUpdato.plan_domain_action(domain, intent())
    end
  end

  test "raw scalar writes cannot mass assign identity, tenant, version or parts" do
    for field <- [:id, :tenant_id, :version, :parts] do
      operation =
        DocumentActionExample.domain()
        |> SelectoUpdato.new(tenant: "tenant-a")
        |> SelectoUpdato.update(%{field => "caller-value"})
        |> SelectoUpdato.filter({:id, "wo-1"})

      assert {:error, _} =
               SelectoUpdato.execute(
                 operation,
                 %Selecto{adapter: RecordingAdapter, connection: :test}
               )
    end

    refute_receive {:document_command, _}
  end
end
