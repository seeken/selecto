defmodule Selecto.Document.NativeInferenceReport do
  @moduledoc """
  Strict value-free native statistical evidence, separate from fixture counts.

  Native JSON numbers do not establish an integer/float family. Reported counts
  retain their native attribute or flavor scope; unavailable counters stay null.
  This evidence is neither an approved shape nor input to automatic draft/drift
  processing. The caller must review field selections and author their semantics.
  """
  alias Selecto.Document.{Canonical, Path}

  @types ~w(array boolean missing null number object string unknown)
  @warnings ~w(native_coverage_unknown numeric_family_unknown max_depth max_fields max_flavors unsafe_field_name unsupported_native_schema excluded_paths)
  @ceilings %{
    "sample_size" => 10_000,
    "max_depth" => 32,
    "max_array_elements" => 10_000,
    "max_fields" => 4096,
    "max_flavors" => 512,
    "max_response_bytes" => 5_000_000,
    "max_report_bytes" => 5_000_000,
    "timeout_ms" => 30_000
  }

  @doc "Hard bounds for the native statistical evidence contract."
  def ceilings, do: @ceilings

  def validate(report) do
    with true <- plain?(report),
         true <-
           keys?(
             report,
             ~w(schema_version kind status provenance bounds coverage truncation exclusions_applied flavors warnings digest)
           ),
         true <-
           report["schema_version"] == 1 and report["kind"] == "document_native_inference" and
             report["status"] == "evidence_only",
         true <- provenance?(report["provenance"]),
         true <- bounds?(report["bounds"]),
         true <-
           report["coverage"] == %{
             "kind" => "statistical_sample",
             "source_complete" => nil,
             "documents_sampled" => nil,
             "bytes_sampled" => nil,
             "integer_float_distinction" => "unavailable",
             "requiredness" => "unavailable"
           },
         true <-
           plain?(report["truncation"]) and keys?(report["truncation"], ~w(native import)) and
             is_nil(report["truncation"]["native"]) and is_boolean(report["truncation"]["import"]),
         true <- integer?(report["exclusions_applied"], 0, 128),
         true <-
           bounded?(report["warnings"], length(@warnings)) and
             Enum.uniq(report["warnings"]) == report["warnings"] and
             Enum.all?(report["warnings"], &(&1 in @warnings)) and
             "native_coverage_unknown" in report["warnings"],
         true <- bounded?(report["flavors"], report["bounds"]["max_flavors"]),
         true <- Enum.all?(report["flavors"], &flavor?(&1, report["bounds"])),
         true <-
           Enum.sum(Enum.map(report["flavors"], &length(&1["fields"]))) <=
             report["bounds"]["max_fields"],
         true <- report["digest"] == Canonical.digest(Map.delete(report, "digest")),
         true <- byte_size(Canonical.encode(report)) <= report["bounds"]["max_report_bytes"] do
      :ok
    else
      _ -> {:error, :invalid_native_inference_report}
    end
  rescue
    _ -> {:error, :invalid_native_inference_report}
  end

  defp provenance?(value) do
    plain?(value) and keys?(value, ~w(backend method source authorization values_collected)) and
      value["backend"] == "couchbase" and value["method"] == "native_infer" and
      value["authorization"] == "source_wide" and value["values_collected"] == false and
      source?(value["source"])
  end

  defp source?(source),
    do:
      plain?(source) and keys?(source, ~w(id bucket scope collection)) and
        Path.safe_key?(source["id"]) and
        Enum.all?(~w(bucket scope collection), &locator_component?(source[&1]))

  defp locator_component?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: Regex.match?(~r/\A[A-Za-z0-9_.%\-]+\z/, value)

  defp locator_component?(_), do: false

  defp bounds?(bounds),
    do:
      plain?(bounds) and keys?(bounds, Map.keys(@ceilings)) and
        Enum.all?(@ceilings, fn {key, ceiling} -> integer?(bounds[key], 1, ceiling) end)

  defp flavor?(flavor, bounds) do
    plain?(flavor) and keys?(flavor, ~w(root_types reported_documents fields)) and
      types?(flavor["root_types"]) and counter?(flavor["reported_documents"]) and
      bounded?(flavor["fields"], bounds["max_fields"]) and
      Enum.all?(flavor["fields"], &field?(&1, bounds)) and
      Enum.uniq_by(flavor["fields"], & &1["path"]) == flavor["fields"]
  end

  defp field?(field, bounds) do
    plain?(field) and keys?(field, ~w(path types reported_count type_counts array)) and
      match?({:ok, _}, Path.parse(field["path"], allow_each: true)) and
      length(field["path"]) <= bounds["max_depth"] and types?(field["types"]) and
      counter?(field["reported_count"]) and plain?(field["type_counts"]) and
      Enum.sort(Map.keys(field["type_counts"])) == field["types"] and
      Enum.all?(field["type_counts"], fn {_type, count} -> counter?(count) end) and
      array?(field["array"])
  end

  defp array?(nil), do: true

  defp array?(array),
    do:
      plain?(array) and keys?(array, ~w(min_items max_items sample_size)) and
        Enum.all?(array, fn {_key, count} -> counter?(count) end) and
        (is_nil(array["min_items"]) or is_nil(array["max_items"]) or
           array["min_items"] <= array["max_items"])

  defp types?(types),
    do:
      is_list(types) and length(types) in 1..8 and Enum.sort(Enum.uniq(types)) == types and
        Enum.all?(types, &(&1 in @types))

  defp counter?(nil), do: true
  defp counter?(value), do: integer?(value, 0, 1_000_000_000)
  defp plain?(value), do: is_map(value) and not is_struct(value)
  defp keys?(value, expected), do: Enum.sort(Map.keys(value)) == Enum.sort(expected)
  defp bounded?(values, max), do: is_list(values) and length(values) <= max
  defp integer?(value, min, max), do: is_integer(value) and value >= min and value <= max
end
