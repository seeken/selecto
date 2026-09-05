defmodule Selecto.DocumentAuthoringTest do
  use ExUnit.Case, async: true

  alias Selecto.Document.{
    Canonical,
    Draft,
    Drift,
    Fixtures,
    Inference,
    InferenceReport,
    ShapeRelease
  }

  test "advisory draft never invents policies, references, or action authority" do
    {:ok, report} = Inference.run(Fixtures.work_orders())
    assert :ok = InferenceReport.validate(report)
    assert {:ok, advisory} = Draft.from_report(report)
    assert advisory["status"] == "review_required"
    assert advisory["writes_authorized"] == false
    assert advisory["inference_digest"] == report["digest"]
    assert "trusted_tenant_scope" in advisory["required_author_decisions"]
    refute Map.has_key?(advisory, "source")
    assert {:error, _} = ShapeRelease.validate(advisory)
    assert advisory["digest"] == Canonical.digest(Map.delete(advisory, "digest"))

    assert Enum.any?(
             advisory["suggestions"],
             &(&1["mapping_candidate"] == "bounded_child_relation_candidate")
           )
  end

  test "authored draft keeps all policy and records immutable evidence before approval" do
    {:ok, report} = Inference.run(Fixtures.work_orders())
    authored = Fixtures.shape()
    assert {:ok, draft} = Draft.build(report, authored)
    assert draft["inference_digest"] == report["digest"]
    assert Map.delete(draft, "inference_digest") == authored
    assert {:error, _} = ShapeRelease.validate(draft, require_approved: true)
    assert {:ok, release} = ShapeRelease.approve(draft, approved_by: "fixture-reviewer")
    assert :ok = ShapeRelease.validate(release, require_approved: true)
    assert {:error, _} = Draft.build(report, release)
    assert {:error, _} = ShapeRelease.new(release)

    assert {:error, :authored_draft_or_evidence_mismatch} =
             Draft.build(report, Map.put(authored, "inference_digest", String.duplicate("a", 64)))
  end

  test "sample drift distinguishes observed incompatibilities from unobserved fields" do
    release = Fixtures.release()
    {:ok, report} = Inference.run(Fixtures.legacy_work_orders())
    assert {:ok, drift} = Drift.compare(release, report)
    assert drift["contract_changed"] == false
    assert drift["evidence_scope"] == "bounded_sample"
    assert "discriminator_values" in drift["not_evaluated"]

    assert Enum.any?(
             drift["findings"],
             &(&1["path"] == ["priority"] and &1["classification"] == "breaking" and
                 &1["observed_types"] == ["string"])
           )

    assert release == Fixtures.release()
    assert drift["digest"] == Canonical.digest(Map.delete(drift, "digest"))

    {:ok, empty_report} = Inference.run([])
    {:ok, empty_drift} = Drift.compare(release, empty_report)
    assert Enum.all?(empty_drift["findings"], &(&1["classification"] == "inconclusive"))
  end

  test "truncated samples never claim missing-field violations" do
    {:ok, report} = Inference.run(Fixtures.work_orders(), max_fields: 2)
    assert {:ok, drift} = Drift.compare(Fixtures.release(), report)
    assert drift["sample_truncated"]
    refute Enum.any?(drift["findings"], &(&1["kind"] == "required_field_missing"))
  end

  test "tampered or malformed evidence cannot enter the authoring pipeline" do
    {:ok, report} = Inference.run(Fixtures.work_orders())
    tampered = put_in(report, ["paths"], [])

    for invalid <- [
          tampered,
          %{},
          nil,
          Date.utc_today(),
          Map.put(report, :atom, "unsafe"),
          put_in(report, ["paths"], [%{"path" => ["$where"]}])
        ] do
      assert {:error, :invalid_inference_report} = InferenceReport.validate(invalid)
      assert {:error, _} = Draft.from_report(invalid)
      assert {:error, _} = Draft.build(invalid, Fixtures.shape())
      assert {:error, _} = Drift.compare(Fixtures.release(), invalid)
    end
  end

  test "byte accounting includes rejected documents and JSON escape growth" do
    docs = List.duplicate(%{"large" => String.duplicate("x", 200)}, 100)
    {:ok, report} = Inference.run(docs, max_document_bytes: 100, max_bytes: 250)
    assert report["sample"]["documents_seen"] == 3
    assert report["sample"]["bytes_inspection_budget_charged"] == 250
    assert report["sample"]["documents_sampled"] == 0
    assert "max_bytes" in report["warnings"]
    assert :ok = InferenceReport.validate(report)

    {:ok, report} = Inference.run([%{"a" => "\u0000"}], max_document_bytes: 10)
    assert report["sample"]["documents_sampled"] == 0
    assert "max_document_bytes" in report["warnings"]
  end

  test "bounded flavor and field selection remains deterministic under reordering" do
    docs = [%{"z" => 1}, %{"a" => 2}, %{"b" => 3}, %{"z" => 4}]
    {:ok, one} = Inference.run(docs, max_fields: 2, max_flavors: 2)
    {:ok, two} = Inference.run(Enum.reverse(docs), max_fields: 2, max_flavors: 2)
    assert one == two
  end

  test "adapter sampling provenance survives the authoring pipeline without accepting secrets" do
    {:ok, report} = Inference.run(Fixtures.work_orders())

    sampling = %{
      "method" => "bounded_find",
      "documents" => 3,
      "limit" => 100,
      "source" => %{"database" => "synthetic_test", "collection" => "work_orders"},
      "tenant_scoped" => true
    }

    report = put_in(report, ["provenance", "sampling"], sampling) |> Map.delete("digest")
    report = Map.put(report, "digest", Canonical.digest(report))
    assert :ok = InferenceReport.validate(report)
    assert {:ok, _} = Draft.build(report, Fixtures.shape())

    report =
      put_in(report, ["provenance", "sampling", "source", "password"], "sensitive")
      |> Map.delete("digest")

    report = Map.put(report, "digest", Canonical.digest(report))
    assert {:error, :invalid_inference_report} = InferenceReport.validate(report)
  end

  test "malformed source maps and unsupported metadata fail closed" do
    for malformed <- [
          nil,
          [],
          Date.utc_today(),
          %{atom: "value"},
          %{"fields" => %{"x" => Date.utc_today()}}
        ] do
      assert {:error, _} = ShapeRelease.new(put_in(Fixtures.shape(), ["shape"], malformed))
      assert {:error, _} = ShapeRelease.new(put_in(Fixtures.shape(), ["source"], malformed))
      assert {:error, _} = ShapeRelease.new(put_in(Fixtures.shape(), ["relations"], malformed))
    end
  end

  test "raising, throwing, and exiting enumerables cannot kill the caller or log source values" do
    parent = self()
    reference = make_ref()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {pid, monitor} =
          spawn_monitor(fn ->
            trap_flag = Process.info(self(), :trap_exit)

            failures = [
              fn -> raise "sensitive-source-value" end,
              fn -> throw({:native_error, "sensitive-source-value"}) end,
              fn -> exit({:native_error, "sensitive-source-value"}) end
            ]

            results =
              Enum.map(failures, fn failure ->
                Inference.run(Stream.map([1], fn _ -> failure.() end))
              end)

            send(parent, {reference, trap_flag, results})
          end)

        assert_receive {^reference, {:trap_exit, false},
                        [
                          {:error, :invalid_document_stream},
                          {:error, :invalid_document_stream},
                          {:error, :invalid_document_stream}
                        ]},
                       1000

        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1000
      end)

    assert log == ""
  end
end
