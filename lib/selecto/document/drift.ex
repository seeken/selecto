defmodule Selecto.Document.Drift do
  @moduledoc """
  Compare bounded structural evidence to an approved release without modifying
  either artifact. Findings are sample observations, never a claim that an
  unseen field or variant is absent from the source.
  """
  alias Selecto.Document.{Canonical, InferenceReport, ShapeRelease}

  def compare(release, report) do
    with :ok <- ShapeRelease.validate(release, require_approved: true),
         :ok <- InferenceReport.validate(report) do
      declared = declared_fields(release)
      evidence = Map.new(report["paths"], &{&1["path"], &1})

      observed_findings =
        Enum.flat_map(declared, fn {path, fields} ->
          Enum.flat_map(fields, &compare_field(path, &1, evidence[path], report))
        end)
        |> Enum.uniq()

      new_findings =
        report["paths"]
        |> Enum.reject(&Map.has_key?(declared, &1["path"]))
        |> Enum.reject(fn evidence ->
          Enum.any?(declared, fn {path, fields} ->
            length(evidence["path"]) > length(path) and
              Enum.take(evidence["path"], length(path)) == path and
              Enum.any?(fields, &(&1["type"] == "object_id"))
          end)
        end)
        |> Enum.map(&new_path/1)

      result = %{
        "schema_version" => 1,
        "kind" => "document_shape_drift",
        "release_id" => release["id"],
        "release_digest" => release["digest"],
        "inference_digest" => report["digest"],
        "evidence_scope" => "bounded_sample",
        "sample_truncated" => report["truncated"],
        "contract_changed" => false,
        "findings" => (observed_findings ++ new_findings) |> Enum.sort_by(&Canonical.encode/1),
        "not_evaluated" =>
          [
            "discriminator_values",
            "unique_identity_values",
            "reference_integrity",
            "index_presence",
            "live_authorization",
            "semantic_datetime_validity"
          ] ++
            if("object_relation" in ShapeRelease.features(release),
              do: ["owned_object_child_requiredness"],
              else: []
            ) ++
            if("object_id" in ShapeRelease.features(release),
              do: ["native_object_id_identity"],
              else: []
            )
      }

      {:ok, Map.put(result, "digest", Canonical.digest(result))}
    end
  end

  defp declared_fields(release) do
    root = Map.new(release["shape"]["fields"], fn {_, field} -> {field["path"], [field]} end)

    Enum.reduce(release["relations"], root, fn
      {_, %{"kind" => "array"} = relation}, fields ->
        Enum.reduce(relation["fields"], fields, fn {_, field}, fields ->
          Map.put(fields, relation["path"] ++ [%{"each" => true}] ++ field["path"], [field])
        end)

      {_, %{"kind" => "object"} = relation}, fields ->
        Enum.reduce(relation["fields"], fields, fn {_, field}, fields ->
          path = relation["path"] ++ field["path"]
          refinement = Map.put(field, "_owned_object_child", true)
          Map.update(fields, path, [refinement], &[refinement | &1])
        end)

      _, fields ->
        fields
    end)
  end

  defp compare_field(path, _field, nil, _report),
    do: [finding(path, "not_observed", "inconclusive", "not_seen_in_sample")]

  defp compare_field(path, field, evidence, report) do
    unexpected =
      evidence["types"]
      |> Map.keys()
      |> Enum.reject(
        &(&1 in [field["type"], "null"] or (field["type"] == "object_id" and &1 == "object"))
      )
      |> Enum.sort()

    type_findings =
      if unexpected == [],
        do: [],
        else: [
          finding(path, "incompatible_types", "breaking", "observed_in_sample")
          |> Map.put("observed_types", unexpected)
        ]

    null_findings =
      if evidence["null_documents"] > 0 and not field["nullable"],
        do: [finding(path, "null_not_allowed", "breaking", "observed_in_sample")],
        else: []

    # Array-child presence is measured per document, not per array element; it
    # cannot establish required-child violations and must remain unclaimed.
    missing_findings =
      if field["required"] and field["_owned_object_child"] != true and
           not Enum.any?(path, &is_map/1) and not report["truncated"] and
           evidence["present_documents"] < report["sample"]["documents_sampled"],
         do: [finding(path, "required_field_missing", "breaking", "observed_in_sample")],
         else: []

    typed_findings =
      if field["type"] == "object_id" and Map.has_key?(evidence["types"], "object"),
        do: [
          finding(
            path,
            "object_id_requires_typed_validation",
            "inconclusive",
            "structural_object_only"
          )
        ],
        else: []

    type_findings ++ typed_findings ++ null_findings ++ missing_findings
  end

  defp new_path(evidence) do
    finding(evidence["path"], "unpublished_path", "compatible_additive", "observed_in_sample")
    |> Map.put("action", "review_before_publication")
  end

  defp finding(path, kind, classification, evidence),
    do: %{
      "path" => path,
      "kind" => kind,
      "classification" => classification,
      "evidence" => evidence
    }
end
