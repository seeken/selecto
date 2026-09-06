defmodule Selecto.Document.InferenceReport do
  @moduledoc "Validation for exact fixture observations and separate native statistical evidence."
  alias Selecto.Document.{Canonical, Path}

  @types ~w(null string integer float boolean object array)
  @warnings ~w(max_documents timeout max_fields max_flavors max_bytes max_document_bytes input_depth_limit unsupported_document_value document_must_be_object unsafe_field_name max_depth max_array_elements max_report_bytes)

  def validate(%{"kind" => "document_native_inference"} = report),
    do: Selecto.Document.NativeInferenceReport.validate(report)

  def validate(report) do
    with true <- plain?(report),
         true <-
           keys?(
             report,
             ~w(schema_version kind status provenance bounds exclusions_applied sample paths flavors warnings truncated digest)
           ),
         true <-
           report["schema_version"] == 1 and report["kind"] == "document_inference" and
             report["status"] == "evidence_only",
         true <- valid_provenance?(report["provenance"]),
         true <- valid_bounds?(report["bounds"]),
         true <- valid_sample?(report["sample"], report["bounds"]),
         true <- integer_between?(report["exclusions_applied"], 0, 128),
         true <- is_boolean(report["truncated"]),
         true <-
           bounded_list?(report["warnings"], 32) and
             Enum.all?(report["warnings"], &(&1 in @warnings)),
         true <-
           bounded_list?(report["paths"], 4096) and Enum.all?(report["paths"], &valid_path?/1),
         true <- distinct_paths?(report["paths"]),
         true <-
           bounded_list?(report["flavors"], 512) and
             Enum.all?(report["flavors"], &valid_flavor?/1),
         true <- digest?(report["digest"]),
         true <- byte_size(Canonical.encode(report)) <= report["bounds"]["max_report_bytes"],
         true <- report["digest"] == Canonical.digest(Map.delete(report, "digest")) do
      :ok
    else
      _ -> {:error, :invalid_inference_report}
    end
  rescue
    _ -> {:error, :invalid_inference_report}
  end

  defp valid_provenance?(value) do
    plain?(value) and
      Map.delete(value, "sampling") == %{
        "sampling_method" => "caller_supplied",
        "values_collected" => false,
        "source_access" => "caller_authorized",
        "runtime" => "selecto_fixture_engine/v1"
      } and (not Map.has_key?(value, "sampling") or valid_sampling?(value["sampling"]))
  end

  defp valid_sampling?(value) do
    plain?(value) and keys?(value, ~w(method documents limit source tenant_scoped)) and
      value["method"] == "bounded_find" and integer_between?(value["limit"], 1, 1000) and
      integer_between?(value["documents"], 0, value["limit"]) and value["tenant_scoped"] == true and
      plain?(value["source"]) and Path.safe_key?(value["source"]["collection"]) and
      Enum.all?(value["source"], fn {key, name} ->
        key in ["database", "collection"] and Path.safe_key?(name)
      end)
  end

  defp valid_bounds?(bounds) do
    ceilings = %{
      "max_documents" => 10_000,
      "max_bytes" => 50_000_000,
      "max_document_bytes" => 5_000_000,
      "max_depth" => 32,
      "max_fields" => 4096,
      "max_array_elements" => 10_000,
      "max_flavors" => 512,
      "timeout_ms" => 30_000,
      "max_report_bytes" => 5_000_000
    }

    plain?(bounds) and map_size(bounds) == map_size(ceilings) and
      Enum.all?(ceilings, fn {key, ceiling} -> integer_between?(bounds[key], 1, ceiling) end)
  end

  defp valid_sample?(sample, bounds) do
    plain?(sample) and
      keys?(
        sample,
        ~w(documents_seen documents_sampled bytes_sampled_upper_bound bytes_inspection_budget_charged)
      ) and
      integer_between?(sample["documents_seen"], 0, bounds["max_documents"]) and
      integer_between?(sample["documents_sampled"], 0, sample["documents_seen"]) and
      integer_between?(sample["bytes_sampled_upper_bound"], 0, bounds["max_bytes"]) and
      integer_between?(
        sample["bytes_inspection_budget_charged"],
        sample["bytes_sampled_upper_bound"],
        bounds["max_bytes"]
      )
  end

  defp valid_path?(evidence) do
    plain?(evidence) and
      keys?(
        evidence,
        ~w(path depth present_documents null_documents observations types required_candidate mixed_types array)
      ) and
      match?({:ok, _}, Path.parse(evidence["path"], allow_each: true)) and
      evidence["depth"] == length(evidence["path"]) and
      integer_between?(evidence["present_documents"], 1, 10_000) and
      integer_between?(evidence["null_documents"], 0, evidence["present_documents"]) and
      integer_between?(evidence["observations"], evidence["present_documents"], 1_000_000_000) and
      plain?(evidence["types"]) and map_size(evidence["types"]) in 1..7 and
      Enum.all?(evidence["types"], fn {type, count} ->
        type in @types and integer_between?(count, 1, 1_000_000_000)
      end) and
      is_boolean(evidence["required_candidate"]) and is_boolean(evidence["mixed_types"]) and
      valid_array?(evidence["array"])
  end

  defp valid_array?(nil), do: true

  defp valid_array?(value) do
    plain?(value) and
      keys?(
        value,
        ~w(arrays_observed sampled_length_min sampled_length_max sampled_length_total empty_arrays elements_truncated)
      ) and
      Enum.all?(
        ~w(arrays_observed sampled_length_min sampled_length_max sampled_length_total empty_arrays),
        &integer_between?(value[&1], 0, 1_000_000_000)
      ) and
      value["sampled_length_min"] <= value["sampled_length_max"] and
      is_boolean(value["elements_truncated"])
  end

  defp valid_flavor?(value) do
    plain?(value) and keys?(value, ~w(id documents structure)) and digest?(value["id"]) and
      integer_between?(value["documents"], 1, 10_000) and bounded_list?(value["structure"], 4096) and
      Enum.all?(value["structure"], fn entry ->
        plain?(entry) and keys?(entry, ~w(path types)) and
          match?({:ok, _}, Path.parse(entry["path"], allow_each: true)) and
          bounded_list?(entry["types"], 7) and Enum.all?(entry["types"], &(&1 in @types))
      end) and value["id"] == Canonical.digest(value["structure"])
  end

  defp distinct_paths?(paths),
    do: paths |> Enum.map(& &1["path"]) |> Enum.uniq() |> length() == length(paths)

  defp plain?(value), do: is_map(value) and not is_struct(value)
  defp bounded_list?(value, maximum), do: is_list(value) and length(value) <= maximum
  defp keys?(value, allowed), do: Enum.sort(Map.keys(value)) == Enum.sort(allowed)

  defp integer_between?(value, minimum, maximum),
    do:
      is_integer(value) and is_integer(minimum) and is_integer(maximum) and value >= minimum and
        value <= maximum

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(~r/\A[a-f0-9]{64}\z/, value)

  defp digest?(_), do: false
end
