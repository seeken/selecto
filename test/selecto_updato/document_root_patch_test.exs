defmodule SelectoUpdato.DocumentRootPatchTest do
  use ExUnit.Case, async: false
  alias Selecto.Document.{Fixtures, Missing, ShapeRelease}
  alias Selecto.Write.{DocumentMutation, DocumentPostimage, DocumentReceipt, Result}
  alias SelectoUpdato.{ActionExecutionAdapter, DocumentActionExample}

  defmodule RecordingAdapter do
    def write_capabilities(_) do
      DocumentMutation.capabilities()
      |> Map.new(&{&1, true})
      |> Map.merge(%{
        protocol_version: 1,
        update: true,
        returning: %{update: true},
        document_set: true,
        document_unset: true,
        document_postimage: true,
        document_object_id: true,
        document_object_relation: true
      })
    end

    def execute_write(_, command, _) do
      send(self(), {:patch_command, command})
      receipt = DocumentReceipt.new(command.metadata.document, %{name: "recording"})
      {:ok, %Result{operation: :update, affected_rows: 1, metadata: %{receipt: receipt}}}
    end

    def preview_write(_, command, _) do
      send(self(), {:patch_preview, command})
      {:ok, %Selecto.Write.Preview{statements: [], metadata: %{operation: :root_patch}}}
    end
  end

  # This supplied response exercises transport through Updato. Native mutation,
  # cell validation and persistence are the concrete adapter's responsibility.
  defmodule PostimageAdapter do
    defdelegate write_capabilities(connection), to: RecordingAdapter

    def execute_write(%{cells: cells, projection: projection}, command, _) do
      {:ok, rows} = DocumentPostimage.decode(cells, projection)
      receipt = DocumentReceipt.new(command.metadata.document, %{name: "postimage-fixture"})
      receipt = Map.put(receipt, :postimage, cells)

      {:ok,
       %Result{operation: :update, affected_rows: 1, rows: rows, metadata: %{receipt: receipt}}}
    end
  end

  defmodule MissingCapabilityAdapter do
    def write_capabilities(capability),
      do: Map.delete(RecordingAdapter.write_capabilities(nil), capability)

    def execute_write(_, _, _), do: raise("must reject before dispatch")
  end

  defmodule Host do
    def execute_action(plan, context, opts) do
      SelectoUpdato.execute(
        plan.operation_builder,
        %Selecto{
          adapter: Keyword.get(opts, :write_adapter, RecordingAdapter),
          connection: Keyword.get(opts, :connection)
        },
        context: context
      )
    end

    def dry_run_action(plan, context, _) do
      SelectoUpdato.preview(
        plan.operation_builder,
        %Selecto{adapter: RecordingAdapter, connection: nil},
        context: context
      )
    end
  end

  defp intent(overrides \\ %{}) do
    %{
      action: :revise_work_order,
      target: %{id: Fixtures.object_id(1)},
      inputs:
        Map.merge(
          %{
            title: "Reviewed title",
            priority: 3,
            expedited: true,
            expected_version: 1,
            idempotency_key: "revise-first"
          },
          overrides
        )
    }
  end

  defp context, do: %{tenant_id: "tenant-a", actor: %{id: "operator"}}
  defp opts, do: [capability_resolver: fn _, _, _ -> :enabled end]
  defp domain, do: DocumentActionExample.patch_domain()

  defp plan(domain \\ domain(), request \\ intent()),
    do: SelectoUpdato.plan_domain_action(domain, request)

  defp mutations(domain, entries),
    do: put_in(domain, [:actions, :revise_work_order, :execution, :document, :mutations], entries)

  defp returning(domain, fields),
    do: put_in(domain, [:actions, :revise_work_order, :execution, :returning], fields)

  defp authored_shape(shape) do
    assert {:ok, release} = ShapeRelease.approve(shape, approved_by: "patch-boundary-test")
    DocumentActionExample.patch_domain(release)
  end

  defp execute(domain, request) do
    assert {:ok, action} = plan(domain, request)
    assert {:ok, _} = ActionExecutionAdapter.execute(Host, action, context(), opts())
    assert_receive {:patch_command, command}
    command
  end

  test "named root fields compile through ordinary authorization with derived capabilities" do
    command = execute(domain(), intent())
    assert command.assignments == []
    assert command.expected_cardinality == {:exactly, 1}
    assert command.returning == ~w(id title priority expedited due_at version customer_id)

    assert command.metadata.document.mutations == [
             %{op: :set, path: ["title"], value: "Reviewed title"},
             %{op: :set, path: ["priority"], value: 3},
             %{op: :set, path: ["expedited"], value: true},
             %{op: :unset, path: ["schedule", "due_at"]}
           ]

    requirements = Selecto.Write.Capabilities.requirements(command)

    for capability <- [:document_set, :document_unset, :document_postimage, {:returning, :update}],
        do: assert(capability in requirements)

    refute :document_update_element in requirements
    assert command.metadata.document.tenant.value == "tenant-a"
  end

  test "missing set, unset, postimage or returning capability rejects before dispatch" do
    assert {:ok, action} = plan()

    for capability <- [:document_set, :document_unset, :document_postimage, :returning] do
      assert {:error, %{type: :write_capability_missing}} =
               ActionExecutionAdapter.execute(
                 Host,
                 action,
                 context(),
                 opts() ++ [write_adapter: MissingCapabilityAdapter, connection: capability]
               )

      refute_receive {:patch_command, _}
    end
  end

  test "preview is descriptive and neither planning nor direct execution bypass authorization" do
    assert {:ok, action} = plan()
    assert {:ok, preview} = ActionExecutionAdapter.dry_run(Host, action, context(), opts())
    refute inspect(preview) =~ "Reviewed title"
    assert_receive {:patch_preview, command}
    assert command.metadata.document.tenant.value == "tenant-a"
    assert {:error, _} = ActionExecutionAdapter.execute(Host, action, context())
    assert {:error, _} = SelectoUpdato.execute(action.operation_builder, %Selecto{})

    assert {:error, _} =
             ActionExecutionAdapter.execute(Host, %{action | returning: [:id]}, context(), opts())

    refute_receive {:patch_command, _}
  end

  test "each field requires its named document action grant independent of scalar writes" do
    for field <- [:title, :priority, :expedited, :due_at] do
      invalid = put_in(domain(), [:writes, :fields, field], %{updatable: true})
      assert {:error, _} = plan(invalid)
    end

    assert {:error, _} =
             plan(mutations(domain(), [%{op: :set, path: ["title"], value_from: :title}]))

    assert {:error, _} =
             plan(
               mutations(domain(), [
                 %{op: :set, field: :title, value_from: :title, native: "$set"}
               ])
             )
  end

  test "published scalar types and null policies apply after action input coercion" do
    for value <- [nil, 1, false, %{}, ["title"], String.duplicate("x", 16_385), <<255>>] do
      assert {:error, _} = plan(domain(), intent(%{title: value}))
    end

    for value <- [9_007_199_254_740_992, -9_007_199_254_740_992] do
      assert {:error, _} = plan(domain(), intent(%{priority: value}))
    end

    for value <- [-9_007_199_254_740_991, 9_007_199_254_740_991] do
      assert {:ok, _} = plan(domain(), intent(%{priority: value}))
    end

    assert {:ok, _} = plan(domain(), intent(%{title: String.duplicate("x", 16_384)}))
    assert {:ok, _} = plan(domain(), intent(%{priority: "3", expedited: "false"}))

    nil_domain = mutations(domain(), [%{op: :set, field: :due_at, value_from: :title}])
    command = execute(nil_domain, intent(%{title: nil}))

    assert command.metadata.document.mutations == [
             %{op: :set, path: ["schedule", "due_at"], value: nil}
           ]

    object_domain = mutations(domain(), [%{op: :set, field: :customer_id, value_from: :title}])
    command = execute(object_domain, intent(%{title: Fixtures.object_id(9)}))
    assert hd(command.metadata.document.mutations).value == Fixtures.object_id(9)
    assert {:error, _} = plan(object_domain, intent(%{title: Fixtures.object_id(9)["value"]}))

    for value <- [
          %{"$oid" => Fixtures.object_id(9)["value"]},
          Map.put(Fixtures.object_id(9), "extra", true),
          3,
          false
        ] do
      assert {:error, _} = plan(object_domain, intent(%{title: value}))
    end

    assert {:ok, _} = plan(object_domain, intent(%{title: nil}))
  end

  test "required, protected, duplicate, overlapping, mixed and over-count mutations reject" do
    for field <- [:id, :tenant_id, :version, :parts] do
      granted =
        put_in(domain(), [:writes, :fields, field, :document_actions], [:revise_work_order])

      assert {:error, _} = plan(mutations(granted, [%{op: :unset, field: field}]))
    end

    assert {:error, _} = plan(mutations(domain(), [%{op: :unset, field: :title}]))
    one = %{op: :set, field: :title, value_from: :title}
    assert {:error, _} = plan(mutations(domain(), [one, one]))
    assert {:error, _} = plan(mutations(domain(), List.duplicate(one, 9)))
    assert {:error, _} = plan(mutations(domain(), [one, %{op: :update_element, path: ["parts"]}]))

    shape = Fixtures.patch_shape() |> put_in(["shape", "fields", "title", "server_managed"], true)
    {:ok, release} = ShapeRelease.approve(shape, approved_by: "patch-protection")
    assert {:error, _} = plan(DocumentActionExample.patch_domain(release))
  end

  test "postimages are selected published scalar fields and are bound into the payload" do
    for fields <- [
          :all,
          true,
          false,
          :record,
          [],
          [:title, :title],
          [:title, "title"],
          [1],
          ["schedule.due_at"],
          [:parts],
          [:source_payload],
          [:unknown],
          List.duplicate(:title, 17)
        ] do
      assert {:error, _} = plan(returning(domain(), fields))
    end

    first = execute(domain(), intent())
    changed = execute(returning(domain(), [:title, :version]), intent())
    refute first.metadata.document.payload_digest == changed.metadata.document.payload_digest
    without = execute(returning(domain(), :none), intent())
    assert without.returning == :none
    refute :document_postimage in Selecto.Write.Capabilities.requirements(without)

    fields = [
      %{"id" => "due_at", "type" => "string", "nullable" => true, "missing" => "preserve"}
    ]

    cells = [%{"field" => "due_at", "present" => false}]
    assert {:ok, [%{"due_at" => %Missing{}}]} = DocumentPostimage.decode(cells, fields)
    assert Jason.decode!(Jason.encode!(cells)) == cells
  end

  test "protected paths include physical ancestors and descendants across root and owned fields" do
    paths = [
      ["tenant_id", "nested"],
      ["version", "nested"],
      ["kind", "nested"],
      ["_selecto_receipts"],
      ["_selecto_receipts", "nested"],
      ["parts", "reserved"]
    ]

    for path <- paths do
      shape = put_in(Fixtures.patch_shape(), ["shape", "fields", "title", "path"], path)
      assert {:error, _} = plan(authored_shape(shape)), inspect(path)
    end

    shape =
      Fixtures.patch_shape()
      |> put_in(["source", "identity_path"], ["record", "id"])
      |> put_in(["relations", "work_orders", "identity_path"], ["record", "id"])
      |> put_in(["shape", "fields", "id", "path"], ["record", "id"])
      |> put_in(["shape", "fields", "title", "path"], ["record"])

    assert {:error, _} = plan(authored_shape(shape))

    owned_shape =
      put_in(
        Fixtures.patch_shape(),
        ["relations", "work_order_schedule", "fields", "audit"],
        %{
          "path" => ["internal", "secret"],
          "type" => "string",
          "required" => false,
          "nullable" => false,
          "missing" => "preserve",
          "server_managed" => true,
          "filterable" => false,
          "sortable" => false
        }
      )

    for path <- [
          ["schedule", "internal"],
          ["schedule", "internal", "secret"],
          ["schedule", "internal", "secret", "nested"]
        ] do
      shape =
        owned_shape
        |> put_in(["shape", "fields", "title", "path"], path)

      action = mutations(authored_shape(shape), [%{op: :set, field: :title, value_from: :title}])
      assert {:error, _} = plan(action), inspect(path)
    end

    shape =
      owned_shape
      |> put_in(["shape", "fields", "title", "path"], ["schedule", "free"])

    action = mutations(authored_shape(shape), [%{op: :set, field: :title, value_from: :title}])
    assert {:ok, _} = plan(action)
  end

  test "published root membership and whole-source write policy remain required" do
    shape =
      update_in(
        Fixtures.patch_shape(),
        ["relations", "work_orders", "fields"],
        &List.delete(&1, "title")
      )

    assert {:error, _} = plan(authored_shape(shape))
    assert {:error, _} = plan(returning(authored_shape(shape), [:title]))

    for modified <- [
          put_in(domain(), [:writes, :operations, :update, :enabled], false),
          put_in(domain(), [:source, :source_table], "another_collection"),
          put_in(domain(), [:writes, :scope, :tenant, :required], false),
          put_in(domain(), [:writes, :scope, :tenant, :field], :id),
          put_in(domain(), [:actions, :revise_work_order, :capability], nil)
        ] do
      assert {:error, _} = plan(modified)
    end

    for relation <- ["work_order_schedule", "work_order_parts", "unknown"] do
      changed =
        put_in(
          domain(),
          [:actions, :revise_work_order, :execution, :document, :relation],
          relation
        )

      assert {:error, _} = plan(changed)
    end

    assert {:ok, action} = plan()

    for trusted <- [Map.delete(context(), :tenant_id), %{tenant_id: "", actor: %{id: "operator"}}] do
      assert {:error, _} = ActionExecutionAdapter.execute(Host, action, trusted, opts())
    end

    assert {:error, _} =
             ActionExecutionAdapter.execute(Host, action, context(),
               capability_resolver: fn _, _, _ -> :disabled end
             )

    refute_receive {:patch_command, _}
  end

  test "an unset-only action derives only the operations it uses and requires missing preservation" do
    unset = mutations(domain(), [%{op: :unset, field: :due_at}]) |> returning(:none)
    command = execute(unset, intent())
    requirements = Selecto.Write.Capabilities.requirements(command)
    assert :document_unset in requirements
    refute :document_set in requirements
    refute :document_update_element in requirements
    refute :document_postimage in requirements
    refute {:returning, :update} in requirements

    shape = put_in(Fixtures.patch_shape(), ["shape", "fields", "due_at", "missing"], "reject")
    assert {:error, _} = plan(mutations(authored_shape(shape), [%{op: :unset, field: :due_at}]))
  end

  test "combined patch bytes and overlapping paths fail before adapter dispatch" do
    fields = [:patch_one, :patch_two, :patch_three, :patch_four, :patch_five]

    shape =
      Enum.reduce(fields, Fixtures.patch_shape(), fn field, shape ->
        id = Atom.to_string(field)
        definition = Map.put(shape["shape"]["fields"]["title"], "path", [id])

        shape
        |> put_in(["shape", "fields", id], definition)
        |> update_in(["relations", "work_orders", "fields"], &(&1 ++ [id]))
      end)

    authored =
      authored_shape(shape)
      |> update_in([:source, :fields], &(&1 ++ fields))
      |> update_in(
        [:source, :columns],
        &Map.merge(&1, Map.new(fields, fn field -> {field, %{type: :string}} end))
      )
      |> update_in(
        [:writes, :fields],
        &Map.merge(
          &1,
          Map.new(fields, fn field ->
            {field, %{updatable: false, document_actions: [:revise_work_order]}}
          end)
        )
      )
      |> returning(:none)

    entries = Enum.map(fields, &%{op: :set, field: &1, value_from: :title})
    max_value = String.duplicate("x", 16_384)

    assert {:ok, _} =
             plan(mutations(authored, Enum.take(entries, 4)), intent(%{title: max_value}))

    assert {:error, _} = plan(mutations(authored, entries), intent(%{title: max_value}))

    overlapping_shape =
      shape
      |> put_in(["shape", "fields", "patch_two", "path"], ["patch_one", "nested"])

    {:ok, release} = ShapeRelease.approve(overlapping_shape, approved_by: "overlap-test")

    overlapping =
      put_in(
        authored,
        [:actions, :revise_work_order, :execution, :document, :shape_release],
        release
      )

    assert {:error, _} = plan(mutations(overlapping, Enum.take(entries, 2)))
    refute_receive {:patch_command, _}
  end

  test "value and path tampering cannot reuse a sealed plan or an idempotency payload" do
    assert {:ok, action} = plan()

    for tampered <- [
          %{action | inputs: Map.put(action.inputs, "title", "Injected")},
          %{action | target: %{id: Fixtures.object_id(2)}},
          %{action | execution: put_in(action.execution, [:document, :mutations], [])}
        ] do
      assert {:error, _} = ActionExecutionAdapter.execute(Host, tampered, context(), opts())
    end

    refute_receive {:patch_command, _}

    first = execute(domain(), intent())
    same = execute(domain(), intent())
    changed = execute(domain(), intent(%{title: "A later title"}))
    changed_order = execute(returning(domain(), [:version, :title]), intent())
    other_order = execute(returning(domain(), [:title, :version]), intent())
    assert first.metadata.document.payload_digest == same.metadata.document.payload_digest
    refute first.metadata.document.payload_digest == changed.metadata.document.payload_digest

    refute changed_order.metadata.document.payload_digest ==
             other_order.metadata.document.payload_digest

    assert first.metadata.document.idempotency_key == changed.metadata.document.idempotency_key
  end

  test "selected postimages preserve ObjectId, null and missing through the authorized result" do
    cells = [
      %{"field" => "id", "present" => true, "value" => Fixtures.object_id(1)},
      %{"field" => "due_at", "present" => false},
      %{"field" => "customer_id", "present" => true, "value" => nil},
      %{"field" => "version", "present" => true, "value" => 2}
    ]

    projection =
      Enum.map(~w(id due_at customer_id version), fn id ->
        {:ok, field} = ShapeRelease.field(Fixtures.patch_release(), "work_orders", id)
        Map.put(Map.take(field, ~w(type nullable missing)), "id", id)
      end)

    assert {:ok, action} = plan(returning(domain(), [:id, :due_at, :customer_id, :version]))

    assert {:ok, %Result{rows: [row], metadata: %{receipt: receipt}}} =
             ActionExecutionAdapter.execute(
               Host,
               action,
               context(),
               opts() ++
                 [
                   write_adapter: PostimageAdapter,
                   connection: %{cells: cells, projection: projection}
                 ]
             )

    assert row == %{
             "id" => Fixtures.object_id(1),
             "due_at" => %Missing{},
             "customer_id" => nil,
             "version" => 2
           }

    assert receipt.postimage == cells
    json_receipt = receipt |> Jason.encode!() |> Jason.decode!()
    assert json_receipt["postimage"] == cells
    assert json_receipt["effects"] |> hd() |> Map.fetch!("target") == Fixtures.object_id(1)
  end
end
