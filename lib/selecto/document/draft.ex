defmodule Selecto.Document.Draft do
  @moduledoc """
  Reviewable suggestions and explicit author promotion. Suggested fields contain
  no executable policy. Authors must supply identities, scope, variants, field
  semantics, index requirements, and relation bounds before building a release.
  """
  alias Selecto.Document.{Canonical, InferenceReport, ShapeRelease}

  @doc "Build an advisory field patch. The result is deliberately not a runnable ShapeRelease."
  def from_report(report, opts \\ [])

  def from_report(report, opts) do
    with :ok <- InferenceReport.validate(report),
         true <- opts == [] do
      suggestions = Enum.map(report["paths"], &suggestion/1)

      draft = %{
        "schema_version" => 1,
        "kind" => "document_shape_draft",
        "status" => "review_required",
        "inference_digest" => report["digest"],
        "sample_truncated" => report["truncated"],
        "suggestions" => suggestions,
        "required_author_decisions" => [
          "source_locator",
          "root_identity",
          "trusted_tenant_scope",
          "version_path",
          "variant_discriminator_and_unknown_policy",
          "field_types_and_missing_null_policies",
          "published_fields",
          "access_patterns_and_indexes",
          "child_identity_and_fan_out"
        ],
        "writes_authorized" => false
      }

      {:ok, Map.put(draft, "digest", Canonical.digest(draft))}
    else
      false -> {:error, :unsupported_draft_options}
      error -> error
    end
  end

  @doc "Attach evidence provenance to a fully authored draft without changing its policy."
  def build(report, authored) do
    with :ok <- InferenceReport.validate(report),
         true <- is_map(authored) and not is_struct(authored),
         true <-
           is_nil(authored["inference_digest"]) or
             authored["inference_digest"] == report["digest"] do
      authored |> Map.put("inference_digest", report["digest"]) |> ShapeRelease.new()
    else
      false -> {:error, :authored_draft_or_evidence_mismatch}
      error -> error
    end
  end

  defp suggestion(evidence) do
    types = evidence["types"] |> Map.keys() |> Enum.reject(&(&1 == "null")) |> Enum.sort()
    path = evidence["path"]

    %{
      "id" => "field_" <> String.slice(Canonical.digest(path), 0, 16),
      "path" => path,
      "observed_types" => types,
      "present_documents" => evidence["present_documents"],
      "null_documents" => evidence["null_documents"],
      "candidate_required" => evidence["required_candidate"],
      "mapping_candidate" => mapping(path, types),
      "review" =>
        if(length(types) == 1,
          do: "choose_field_semantics",
          else: "choose_union_variant_or_opaque_policy"
        )
    }
  end

  defp mapping(path, types) do
    cond do
      Enum.any?(path, &is_map/1) -> "bounded_child_relation_candidate"
      "array" in types -> "opaque_array_or_identified_child_candidate"
      "object" in types -> "inline_or_opaque_object_candidate"
      true -> "scalar_field_candidate"
    end
  end
end
