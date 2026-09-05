defmodule Selecto.Document.Inference do
  @moduledoc """
  Bounded structural discovery from caller-supplied JSON-shaped documents.
  Reports contain paths and counts, never source values. Discovery confers no
  query or write authority. The caller owns sampling authorization and source
  access controls, including protection of field names in the report.
  """
  alias Selecto.Document.{Canonical, Path}

  @defaults %{
    max_documents: 1000,
    max_bytes: 5_000_000,
    max_document_bytes: 512_000,
    max_depth: 8,
    max_fields: 256,
    max_array_elements: 100,
    max_flavors: 64,
    timeout_ms: 1000,
    max_report_bytes: 256_000
  }
  @ceilings %{
    max_documents: 10_000,
    max_bytes: 50_000_000,
    max_document_bytes: 5_000_000,
    max_depth: 32,
    max_fields: 4096,
    max_array_elements: 10_000,
    max_flavors: 512,
    timeout_ms: 30_000,
    max_report_bytes: 5_000_000
  }

  @spec run(Enumerable.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(documents, opts \\ []) do
    with {:ok, bounds, exclusions} <- options(opts),
         true <- not is_nil(Enumerable.impl_for(documents)) do
      task = Task.async(fn -> infer(documents, bounds, exclusions) end)

      # The outer deadline also interrupts a stalled lazy input enumerable. No
      # report is returned from an interrupted run, and partial evidence never
      # masquerades as a complete sample.
      case Task.yield(task, bounds.timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :inference_timeout}
        {:exit, _} -> {:error, :invalid_document_stream}
      end
    else
      false -> {:error, :documents_must_be_enumerable}
      error -> error
    end
  end

  @doc "Canonical report bytes, including its content digest."
  def canonical_json(report), do: Canonical.encode(report)

  defp options(opts) when is_list(opts) do
    allowed = Map.keys(@defaults) ++ [:excluded_paths, :collect_values]

    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_inference_options}

      Enum.any?(Keyword.keys(opts), &(&1 not in allowed)) ->
        {:error, :unknown_inference_option}

      Keyword.get(opts, :collect_values, false) != false ->
        {:error, :value_collection_not_supported}

      true ->
        bounds = Map.merge(@defaults, Map.new(Keyword.take(opts, Map.keys(@defaults))))
        exclusions = Keyword.get(opts, :excluded_paths, [])

        valid_bounds =
          Enum.all?(bounds, fn {key, value} ->
            is_integer(value) and value > 0 and value <= @ceilings[key]
          end)

        valid_exclusions =
          is_list(exclusions) and length(exclusions) <= 128 and
            Enum.all?(exclusions, &match?({:ok, _}, Path.parse(&1, allow_each: true)))

        cond do
          not valid_bounds -> {:error, :invalid_inference_bounds}
          bounds.max_report_bytes < 1024 -> {:error, :report_budget_too_small}
          not valid_exclusions -> {:error, :invalid_excluded_paths}
          true -> {:ok, bounds, Enum.sort(Enum.uniq(exclusions))}
        end
    end
  end

  defp options(_), do: {:error, :invalid_inference_options}

  defp infer(documents, bounds, exclusions) do
    state = %{
      bounds: bounds,
      exclusions: exclusions,
      sampled: 0,
      seen: 0,
      bytes: 0,
      inspected_bytes: 0,
      paths: %{},
      flavors: %{},
      warnings: MapSet.new(),
      stop: false,
      deadline: System.monotonic_time(:millisecond) + bounds.timeout_ms
    }

    result =
      documents
      |> Stream.take(bounds.max_documents)
      |> Enum.reduce_while(state, fn document, state ->
        cond do
          state.seen >= bounds.max_documents ->
            {:halt, warn(state, "max_documents")}

          expired?(state) ->
            {:halt, warn(state, "timeout")}

          true ->
            state = %{state | seen: state.seen + 1}
            next = inspect_document(document, state)
            if next.stop, do: {:halt, next}, else: {:cont, next}
        end
      end)

    result =
      if result.seen == bounds.max_documents, do: warn(result, "max_documents"), else: result

    finalize(result)
  rescue
    _ -> {:error, :invalid_document_stream}
  catch
    _, _ -> {:error, :invalid_document_stream}
  end

  defp inspect_document(document, state) when is_map(document) and not is_struct(document) do
    remaining =
      min(state.bounds.max_document_bytes, state.bounds.max_bytes - state.inspected_bytes)

    case json_size(document, remaining, 0, state.deadline) do
      {:ok, bytes} ->
        local = %{paths: %{}, warnings: MapSet.new(), seen_fields: 0}
        local = walk_object(document, [], local, state)
        paths = merge_paths(state.paths, local.paths, state.bounds.max_fields)
        all_warnings = MapSet.union(state.warnings, local.warnings)

        all_warnings =
          if map_size(paths) < map_size(Map.merge(state.paths, local.paths)),
            do: MapSet.put(all_warnings, "max_fields"),
            else: all_warnings

        signature =
          local.paths
          |> Enum.map(fn {path, info} ->
            %{"path" => path, "types" => info.types |> Map.keys() |> Enum.sort()}
          end)
          |> Enum.sort_by(&Canonical.encode/1)

        flavor_id = Canonical.digest(signature)

        {flavors, all_warnings} =
          cond do
            Map.has_key?(state.flavors, flavor_id) ->
              {Map.update!(state.flavors, flavor_id, &%{&1 | count: &1.count + 1}), all_warnings}

            map_size(state.flavors) < state.bounds.max_flavors ->
              {Map.put(state.flavors, flavor_id, %{count: 1, signature: signature}), all_warnings}

            true ->
              retained =
                state.flavors
                |> Map.put(flavor_id, %{count: 1, signature: signature})
                |> Enum.sort()
                |> Enum.take(state.bounds.max_flavors)
                |> Map.new()

              {retained, MapSet.put(all_warnings, "max_flavors")}
          end

        %{
          state
          | sampled: state.sampled + 1,
            bytes: state.bytes + bytes,
            inspected_bytes: state.inspected_bytes + bytes,
            paths: paths,
            flavors: flavors,
            warnings: all_warnings
        }

      {:error, :bytes} ->
        state = %{state | inspected_bytes: state.inspected_bytes + remaining}

        if remaining < state.bounds.max_document_bytes do
          %{warn(state, "max_bytes") | stop: true}
        else
          warn(state, "max_document_bytes")
        end

      {:error, :depth} ->
        %{warn(state, "input_depth_limit") | inspected_bytes: state.inspected_bytes + remaining}

      {:error, :timeout} ->
        %{warn(state, "timeout") | stop: true}

      {:error, :invalid} ->
        %{
          warn(state, "unsupported_document_value")
          | inspected_bytes: state.inspected_bytes + remaining
        }
    end
  end

  defp inspect_document(_, state), do: warn(state, "document_must_be_object")

  # Count bounded JSON wire bytes without serializing documents or retaining
  # values. Hard input depth prevents the size preflight itself recursing without
  # a bound. Walk-time max_depth may be smaller and produces truncated evidence.
  defp json_size(_, remaining, _, _) when remaining < 0, do: {:error, :bytes}
  defp json_size(_, _, depth, _) when depth > 64, do: {:error, :depth}

  defp json_size(value, remaining, depth, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      size_value(value, remaining, depth, deadline)
    end
  end

  defp size_value(value, remaining, depth, deadline)
       when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, size_constant(2, remaining), fn
      {key, value}, {:ok, total} when is_binary(key) ->
        with {:ok, key_bytes} <- string_size(key, remaining - total, deadline),
             {:ok, value_bytes} <-
               json_size(value, remaining - total - key_bytes - 2, depth + 1, deadline) do
          {:cont, {:ok, total + key_bytes + value_bytes + 2}}
        else
          error -> {:halt, error}
        end

      _, {:error, _} = error ->
        {:halt, error}

      _, _ ->
        {:halt, {:error, :invalid}}
    end)
  end

  defp size_value(value, remaining, depth, deadline) when is_list(value) do
    Enum.reduce_while(value, size_constant(2, remaining), fn element, acc ->
      with {:ok, total} <- acc,
           {:ok, bytes} <- json_size(element, remaining - total - 1, depth + 1, deadline) do
        {:cont, {:ok, total + bytes + 1}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp size_value(value, remaining, _, deadline) when is_binary(value),
    do: string_size(value, remaining, deadline)

  defp size_value(nil, remaining, _, _), do: size_constant(4, remaining)
  defp size_value(true, remaining, _, _), do: size_constant(4, remaining)
  defp size_value(false, remaining, _, _), do: size_constant(5, remaining)

  defp size_value(value, remaining, _, _) when is_integer(value) do
    # Large integers are rejected before converting them into decimal text.
    bits = :erlang.external_size(value) * 8

    if bits > remaining * 4 + 64,
      do: {:error, :bytes},
      else: size_constant(byte_size(Integer.to_string(value)), remaining)
  end

  defp size_value(value, remaining, _, _) when is_float(value),
    do: size_constant(byte_size(Float.to_string(value)), remaining)

  defp size_value(_, _, _, _), do: {:error, :invalid}

  defp size_constant(bytes, remaining),
    do: if(bytes <= remaining, do: {:ok, bytes}, else: {:error, :bytes})

  defp string_size(value, remaining, deadline) do
    if byte_size(value) + 2 > remaining do
      {:error, :bytes}
    else
      escaped_size(value, 2, remaining, deadline)
    end
  end

  defp escaped_size(_, count, remaining, _) when count > remaining, do: {:error, :bytes}
  defp escaped_size(<<>>, count, _, _), do: {:ok, count}

  defp escaped_size(<<char::utf8, rest::binary>>, count, remaining, deadline) do
    extra =
      cond do
        char in [34, 92, 8, 9, 10, 12, 13] -> 2
        char < 32 -> 6
        char < 128 -> 1
        char < 2048 -> 2
        char < 65536 -> 3
        true -> 4
      end

    if rem(count, 512) == 0 and System.monotonic_time(:millisecond) >= deadline,
      do: {:error, :timeout},
      else: escaped_size(rest, count + extra, remaining, deadline)
  end

  defp escaped_size(_, _, _, _), do: {:error, :invalid}

  defp walk_object(document, parent, local, state) do
    cond do
      length(parent) >= state.bounds.max_depth ->
        local_warn(local, "max_depth")

      expired?(state) ->
        local_warn(local, "timeout")

      true ->
        # Size preflight has already bounded this map; sorting makes field
        # selection deterministic even when a configured field limit truncates it.
        document
        |> Enum.sort_by(fn {key, _} -> key end)
        |> Enum.reduce_while(local, fn {key, value}, local ->
          path = parent ++ [key]

          cond do
            excluded?(path, state.exclusions) ->
              {:cont, local}

            not Path.safe_key?(key) ->
              {:cont, local_warn(local, "unsafe_field_name")}

            local.seen_fields >= state.bounds.max_fields and not Map.has_key?(local.paths, path) ->
              {:halt, local_warn(local, "max_fields")}

            expired?(state) ->
              {:halt, local_warn(local, "timeout")}

            true ->
              {:cont, walk_value(value, path, local, state)}
          end
        end)
    end
  end

  defp walk_value(value, path, local, state) do
    local = record(local, path, value)

    cond do
      is_map(value) -> walk_object(value, path, local, state)
      is_list(value) -> walk_array(value, path, local, state)
      true -> local
    end
  end

  defp walk_array(values, path, local, state) do
    bounded = Enum.take(values, state.bounds.max_array_elements + 1)
    truncated? = length(bounded) > state.bounds.max_array_elements
    sample = Enum.take(bounded, state.bounds.max_array_elements)
    array_path = path ++ [%{"each" => true}]
    local = if truncated?, do: local_warn(local, "max_array_elements"), else: local
    info = Map.fetch!(local.paths, path)

    array = %{
      count: 1,
      min: length(sample),
      max: length(sample),
      total: length(sample),
      empty: if(values == [], do: 1, else: 0),
      truncated: truncated?
    }

    local = put_in(local.paths[path], %{info | arrays: merge_arrays(info.arrays, array)})

    cond do
      length(path) >= state.bounds.max_depth ->
        if(values == [], do: local, else: local_warn(local, "max_depth"))

      true ->
        Enum.reduce_while(sample, local, fn value, local ->
          cond do
            excluded?(array_path, state.exclusions) ->
              {:halt, local}

            local.seen_fields >= state.bounds.max_fields and
                not Map.has_key?(local.paths, array_path) ->
              {:halt, local_warn(local, "max_fields")}

            expired?(state) ->
              {:halt, local_warn(local, "timeout")}

            true ->
              {:cont, walk_value(value, array_path, local, state)}
          end
        end)
    end
  end

  defp record(local, path, value) do
    type = type(value)

    existing =
      Map.get(local.paths, path, %{present: 1, null: 0, observations: 0, types: %{}, arrays: nil})

    info = %{
      existing
      | null: if(is_nil(value), do: 1, else: existing.null),
        observations: existing.observations + 1,
        types: Map.update(existing.types, type, 1, &(&1 + 1))
    }

    %{
      local
      | paths: Map.put(local.paths, path, info),
        seen_fields: local.seen_fields + if(Map.has_key?(local.paths, path), do: 0, else: 1)
    }
  end

  defp merge_paths(existing, additions, limit) do
    Map.merge(existing, additions, fn _, left, right ->
      %{
        present: left.present + right.present,
        null: left.null + right.null,
        observations: left.observations + right.observations,
        types: Map.merge(left.types, right.types, fn _, l, r -> l + r end),
        arrays: merge_arrays(left.arrays, right.arrays)
      }
    end)
    |> Enum.sort_by(fn {path, _} -> Canonical.encode(path) end)
    |> Enum.take(limit)
    |> Map.new()
  end

  defp merge_arrays(nil, other), do: other
  defp merge_arrays(other, nil), do: other

  defp merge_arrays(left, right),
    do: %{
      count: left.count + right.count,
      min: min(left.min, right.min),
      max: max(left.max, right.max),
      total: left.total + right.total,
      empty: left.empty + right.empty,
      truncated: left.truncated or right.truncated
    }

  defp finalize(state) do
    paths =
      state.paths
      |> Enum.sort_by(fn {path, _} -> Canonical.encode(path) end)
      |> Enum.map(fn {path, info} ->
        %{
          "path" => path,
          "depth" => length(path),
          "present_documents" => info.present,
          "null_documents" => info.null,
          "observations" => info.observations,
          "types" => info.types,
          "required_candidate" => state.sampled > 0 and info.present == state.sampled,
          "mixed_types" => map_size(Map.delete(info.types, "null")) > 1,
          "array" => array_report(info.arrays)
        }
      end)

    report = %{
      "schema_version" => 1,
      "kind" => "document_inference",
      "status" => "evidence_only",
      "provenance" => %{
        "sampling_method" => "caller_supplied",
        "values_collected" => false,
        "source_access" => "caller_authorized",
        "runtime" => "selecto_fixture_engine/v1"
      },
      "bounds" => Map.new(state.bounds, fn {key, value} -> {Atom.to_string(key), value} end),
      "exclusions_applied" => length(state.exclusions),
      "sample" => %{
        "documents_seen" => state.seen,
        "documents_sampled" => state.sampled,
        "bytes_sampled_upper_bound" => state.bytes,
        "bytes_inspection_budget_charged" => state.inspected_bytes
      },
      "paths" => paths,
      "flavors" =>
        state.flavors
        |> Enum.sort()
        |> Enum.map(fn {id, flavor} ->
          %{"id" => id, "documents" => flavor.count, "structure" => flavor.signature}
        end),
      "warnings" => state.warnings |> MapSet.to_list() |> Enum.sort(),
      "truncated" => MapSet.size(state.warnings) > 0
    }

    fit_report(report, state.bounds.max_report_bytes)
  end

  defp fit_report(report, limit) do
    signed = Map.put(report, "digest", Canonical.digest(report))

    cond do
      byte_size(Canonical.encode(signed)) <= limit -> {:ok, signed}
      report["paths"] != [] -> fit_report(truncate_report(report, "paths"), limit)
      report["flavors"] != [] -> fit_report(truncate_report(report, "flavors"), limit)
      true -> {:error, :report_budget_too_small}
    end
  end

  defp truncate_report(report, key) do
    report
    |> Map.update!(key, &Enum.take(&1, div(length(&1), 2)))
    |> Map.update!("warnings", &Enum.sort(Enum.uniq(["max_report_bytes" | &1])))
    |> Map.put("truncated", true)
  end

  defp array_report(nil), do: nil

  defp array_report(a),
    do: %{
      "arrays_observed" => a.count,
      "sampled_length_min" => a.min,
      "sampled_length_max" => a.max,
      "sampled_length_total" => a.total,
      "empty_arrays" => a.empty,
      "elements_truncated" => a.truncated
    }

  defp excluded?(path, exclusions),
    do: Enum.any?(exclusions, fn excluded -> Enum.take(path, length(excluded)) == excluded end)

  defp expired?(state), do: System.monotonic_time(:millisecond) >= state.deadline
  defp warn(state, warning), do: %{state | warnings: MapSet.put(state.warnings, warning)}
  defp local_warn(local, warning), do: %{local | warnings: MapSet.put(local.warnings, warning)}
  defp type(nil), do: "null"
  defp type(v) when is_boolean(v), do: "boolean"
  defp type(v) when is_integer(v), do: "integer"
  defp type(v) when is_float(v), do: "float"
  defp type(v) when is_binary(v), do: "string"
  defp type(v) when is_list(v), do: "array"
  defp type(v) when is_map(v), do: "object"
end
