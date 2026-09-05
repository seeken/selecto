defmodule Selecto.DocumentContractTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Canonical, Fixtures, Inference, Missing, Path, ShapeRelease}

  test "safe parsed paths preserve missing, null, and present values without creating atoms" do
    assert {:ok, ["schedule", "due_at"]} = Path.parse(["schedule", "due_at"])
    assert {:error, _} = Path.parse("schedule.due_at")

    for path <- [
          ["$where"],
          ["a.b"],
          ["a\0b"],
          ["a", 0],
          ["a", :each],
          [:atom],
          [String.duplicate("a", 129)]
        ] do
      assert {:error, _} = Path.parse(path)
    end

    assert {:ok, _} = Path.parse(["parts", %{"each" => true}, "sku"], allow_each: true)
    assert %Missing{} = Path.fetch(%{}, ["due_at"])
    assert nil == Path.fetch(%{"due_at" => nil}, ["due_at"])
    assert 2 == Path.fetch(%{"quantity" => 2}, ["quantity"])
    assert %{"$selecto" => "missing"} == Missing.to_map(%Missing{})
  end

  test "canonical JSON sorts nested maps while preserving array order" do
    assert Canonical.encode(%{"b" => %{"d" => 2, "c" => 1}, "a" => [2, 1]}) ==
             ~s({"a":[2,1],"b":{"c":1,"d":2}})
  end

  test "inference is deterministic, order-independent, value-free structural evidence" do
    documents = Fixtures.work_orders() ++ Fixtures.legacy_work_orders()
    assert {:ok, report} = Inference.run(documents)
    assert {:ok, reversed} = Inference.run(Enum.reverse(documents))
    assert report == reversed
    assert report["sample"]["documents_sampled"] == 4
    assert report["status"] == "evidence_only"
    refute report["truncated"]
    encoded = Inference.canonical_json(report)

    for value <- ["Replace pump", "tenant-a", "synthetic-a", "high", "2026-08-26T12:00:00Z"] do
      refute encoded =~ value
    end

    priority = evidence(report, ["priority"])
    assert priority["types"] == %{"integer" => 2, "string" => 1}
    assert priority["present_documents"] == 3
    assert priority["mixed_types"]
    refute priority["required_candidate"]
    due = evidence(report, ["schedule", "due_at"])
    assert due["present_documents"] == 3
    assert due["null_documents"] == 1
    assert due["types"] == %{"null" => 1, "integer" => 1, "string" => 1}
    parts = evidence(report, ["parts", %{"each" => true}, "part_id"])
    assert parts["present_documents"] == 3
    assert parts["observations"] == 5
    assert report["digest"] == Canonical.digest(Map.delete(report, "digest"))
  end

  test "excluded subtrees and unsafe key names never enter evidence or flavors" do
    doc = %{
      "ok" => 1,
      "secret" => %{"private_key_name" => "private-value"},
      "$where" => "native-code"
    }

    assert {:ok, report} = Inference.run([doc], excluded_paths: [["secret"]])
    encoded = Inference.canonical_json(report)
    refute encoded =~ "secret"
    refute encoded =~ "private"
    refute encoded =~ "$where"
    refute encoded =~ "native-code"
    assert report["warnings"] == ["unsafe_field_name"]
    assert {:error, :value_collection_not_supported} = Inference.run([doc], collect_values: true)
  end

  test "document count, individual and total byte budgets stop or reject input explicitly" do
    assert {:ok, report} =
             Inference.run(Stream.repeatedly(fn -> %{"a" => 1} end), max_documents: 3)

    assert report["sample"]["documents_sampled"] == 3
    assert "max_documents" in report["warnings"]

    assert {:ok, report} =
             Inference.run([%{"large" => String.duplicate("x", 500)}], max_document_bytes: 100)

    assert report["sample"]["documents_sampled"] == 0
    assert "max_document_bytes" in report["warnings"]

    assert {:ok, report} = Inference.run(List.duplicate(%{"a" => 1}, 50), max_bytes: 20)
    assert report["sample"]["bytes_sampled_upper_bound"] <= 20
    assert "max_bytes" in report["warnings"]
  end

  test "field, depth, array, flavor, and report limits are enforced and visible" do
    doc = %{"a" => %{"b" => %{"c" => 1}}, "array" => Enum.map(1..10, &%{"x" => &1}), "z" => 2}
    assert {:ok, depth} = Inference.run([doc], max_depth: 2)
    assert Enum.all?(depth["paths"], &(&1["depth"] <= 2))
    assert "max_depth" in depth["warnings"]

    assert {:ok, fields} = Inference.run([doc], max_fields: 2)
    assert length(fields["paths"]) <= 2
    assert "max_fields" in fields["warnings"]

    assert {:ok, arrays} = Inference.run([doc], max_array_elements: 2)
    assert evidence(arrays, ["array"])["array"]["sampled_length_max"] == 2
    assert "max_array_elements" in arrays["warnings"]

    assert {:ok, flavors} = Inference.run([%{"a" => 1}, %{"b" => true}], max_flavors: 1)
    assert length(flavors["flavors"]) == 1
    assert "max_flavors" in flavors["warnings"]

    assert {:ok, small} = Inference.run(Fixtures.work_orders(), max_report_bytes: 1500)
    assert byte_size(Inference.canonical_json(small)) <= 1500
    assert "max_report_bytes" in small["warnings"]
    assert {:error, :invalid_inference_bounds} = Inference.run([], max_depth: 1000)
  end

  test "wall-clock watchdog interrupts an enumerable that never yields" do
    stream =
      Stream.repeatedly(fn ->
        Process.sleep(5000)
        %{}
      end)

    assert {:error, :inference_timeout} = Inference.run(stream, timeout_ms: 10)
  end

  test "inference rejects unsupported structs and invalid Unicode without retaining values" do
    assert {:ok, report} =
             Inference.run([%{"bad" => self()}, %{"bad" => <<255>>}, %{bad: 1}, Date.utc_today()])

    assert report["sample"]["documents_sampled"] == 0
    assert "unsupported_document_value" in report["warnings"]
    assert "document_must_be_object" in report["warnings"]
  end

  test "an authored release approves explicitly, validates, and detects tampering" do
    assert {:ok, draft} = ShapeRelease.new(Fixtures.shape())
    assert {:error, _} = ShapeRelease.validate(draft, require_approved: true)
    assert {:error, _} = ShapeRelease.approve(draft)
    assert {:ok, release} = ShapeRelease.approve(draft, approved_by: "test-author")
    assert :ok = ShapeRelease.validate(release, require_approved: true)

    assert :ok =
             ShapeRelease.validate(Jason.decode!(Canonical.encode(release)),
               require_approved: true
             )

    assert {:error, ["release digest mismatch"]} =
             ShapeRelease.validate(put_in(release, ["source", "collection"], "different"))

    assert {:error, _} = ShapeRelease.approve(release, approved_by: "another-author")
    assert {:ok, %{"id" => "work_orders"}} = ShapeRelease.relation(release, "work_orders")

    assert {:ok, %{"path" => ["schedule", "due_at"]}} =
             ShapeRelease.field(release, "work_orders", "due_at")

    assert {:ok, %{"path" => ["reserved"]}} =
             ShapeRelease.field(release, "work_order_parts", "reserved")

    assert {:error, _} = ShapeRelease.field(release, "work_orders", "arbitrary")
  end

  test "malformed contracts fail closed rather than raising" do
    shape = Fixtures.shape()

    cases = [
      put_in(shape, ["source", "identity_path"], ["$where"]),
      put_in(shape, ["source", "credential"], "secret"),
      put_in(shape, ["shape", "fields", "title", "path"], ["state"]),
      put_in(shape, ["shape", "fields", "title", "required"], nil),
      put_in(shape, ["shape", "fields", "source_payload", "filterable"], true),
      put_in(shape, ["shape", "variants", "values"], ["repair", "repair"]),
      put_in(shape, ["shape", "variants", "unknown_policy"], "ignore"),
      put_in(shape, ["relations", "work_order_parts", "identity_path"], ["position"]),
      put_in(shape, ["relations", "work_order_parts", "max_elements"], 0),
      put_in(shape, ["relations", "work_orders", "access_patterns"], %{}),
      put_in(shape, ["shape", "fields"], 1),
      put_in(shape, ["source"], nil)
    ]

    for input <- cases, do: assert({:error, _} = ShapeRelease.new(input))
  end

  test "document validation preserves variants, missing/null, exact types, and child identity" do
    release = Fixtures.release()

    for document <- Fixtures.work_orders(),
        do: assert(:ok = ShapeRelease.validate_document(release, document))

    for document <- Fixtures.legacy_work_orders(),
        do: assert({:error, _} = ShapeRelease.validate_document(release, document))

    [first | _] = Fixtures.work_orders()

    for invalid <- [
          Map.delete(first, "title"),
          Map.put(first, "title", nil),
          Map.put(first, "kind", "unknown"),
          put_in(first, ["parts"], List.duplicate(hd(first["parts"]), 2)),
          put_in(first, ["parts"], List.duplicate(hd(first["parts"]), 201))
        ] do
      assert {:error, _} = ShapeRelease.validate_document(release, invalid)
    end
  end

  defp evidence(report, path), do: Enum.find(report["paths"], &(&1["path"] == path))
end
