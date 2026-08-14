defmodule Selecto.FunctionVerification.Suite do
  @moduledoc """
  Builds deterministic connected-verification evidence for a function registry.

  The suite enumerates every registered signature, asks the configured adapter
  for connected evidence in collection mode, and leaves strict pass/fail policy
  to the caller. It never supplies runtime function arguments.
  """

  alias Selecto.FunctionVerification
  alias Selecto.FunctionVerification.{Report, Request}

  @format "selecto.function_verification"
  @format_version 1
  @proof_boundary %{
    proves:
      "current connected adapter resolution of each declared signature and adapter-reported requirements",
    does_not_prove:
      "function semantics, arbitrary inputs, performance, determinism, concurrency, callbacks, external effects, or future database state",
    runtime_argument_values_transmitted: false,
    function_execution_requested: false
  }

  @type artifact :: map()

  @doc "Verifies every registered signature and returns a deterministic artifact."
  @spec verify(Selecto.t(), keyword()) :: artifact()
  def verify(%Selecto{} = selecto, opts \\ []) when is_list(opts) do
    results =
      selecto
      |> Selecto.UDF.functions()
      |> sorted_functions()
      |> Enum.flat_map(fn {function_id, spec} ->
        verify_function(selecto, function_id, spec, opts)
      end)

    %{
      format: @format,
      format_version: @format_version,
      strict_passed?: Enum.all?(results, &(&1.status == :database_resolved)),
      summary: summary(results),
      proof_boundary: @proof_boundary,
      results: results
    }
  end

  defp sorted_functions(functions) when is_map(functions) do
    functions
    |> Enum.map(fn {function_id, spec} -> {safe_function_id(function_id), spec} end)
    |> Enum.sort_by(fn {function_id, _spec} -> function_id end)
  end

  defp sorted_functions(_functions), do: []

  defp verify_function(selecto, function_id, spec, opts) when is_map(spec) do
    spec
    |> Selecto.FunctionSpec.signatures()
    |> Enum.with_index()
    |> Enum.map(fn {signature, signature_index} ->
      verify_signature(selecto, function_id, signature, signature_index, opts)
    end)
  rescue
    _exception -> [static_invalid(function_id, 0, :invalid_function_spec)]
  end

  defp verify_function(_selecto, function_id, _spec, _opts) do
    [static_invalid(function_id, 0, :invalid_function_spec)]
  end

  defp verify_signature(selecto, function_id, signature, signature_index, opts) do
    call_site = verification_call_site(signature)

    case Request.new(function_id, signature, call_site) do
      {:ok, request} ->
        adapter_opts =
          opts
          |> Keyword.drop([:mode])
          |> Keyword.put(:mode, :warn)

        case FunctionVerification.verify_request(selecto, request, adapter_opts) do
          {:ok, report} -> report_result(request, signature_index, report)
          {:error, error} -> adapter_error_result(request, signature_index, error)
        end

      {:error, error} ->
        static_invalid(function_id, signature_index, error_code(error))
    end
  rescue
    _exception -> static_invalid(function_id, signature_index, :invalid_function_signature)
  end

  defp report_result(request, signature_index, %Report{} = report) do
    %{
      function_id: request.function_id,
      signature_index: signature_index,
      signature_fingerprint: request.signature_fingerprint,
      kind: request.kind,
      sql_name: request.sql_name,
      call_site: request.call_site,
      status: report.status,
      proof_level: report.proof_level,
      adapter: report.adapter,
      resolved_identity: report.resolved_identity,
      server: report.server || %{},
      requirements: report.requirements,
      evidence: report.evidence,
      diagnostics: report.diagnostics
    }
  end

  defp adapter_error_result(request, signature_index, error) do
    %{
      function_id: request.function_id,
      signature_index: signature_index,
      signature_fingerprint: request.signature_fingerprint,
      kind: request.kind,
      sql_name: request.sql_name,
      call_site: request.call_site,
      status: :indeterminate,
      proof_level: :none,
      adapter: nil,
      resolved_identity: nil,
      server: %{},
      requirements: request.requirements,
      evidence: %{},
      diagnostics: [%{code: error_code(error)}]
    }
  end

  defp static_invalid(function_id, signature_index, code) do
    %{
      function_id: safe_function_id(function_id),
      signature_index: signature_index,
      signature_fingerprint: nil,
      kind: nil,
      sql_name: nil,
      call_site: nil,
      status: :static_invalid,
      proof_level: :none,
      adapter: nil,
      resolved_identity: nil,
      server: %{},
      requirements: %{},
      evidence: %{},
      diagnostics: [%{code: code}]
    }
  end

  defp verification_call_site(signature) do
    kind = Map.get(signature, :kind)
    allowed = Map.get(signature, :allowed_in, [])
    preferred = preferred_call_site(kind)

    cond do
      preferred in allowed -> preferred
      allowed != [] -> Enum.find(allowed, preferred, &is_atom/1)
      true -> preferred
    end
  end

  defp preferred_call_site(:predicate), do: :filter
  defp preferred_call_site(:table), do: :lateral
  defp preferred_call_site(_kind), do: :select

  defp summary(results) do
    counts =
      results
      |> Enum.group_by(& &1.status)
      |> Map.new(fn {status, entries} -> {status, length(entries)} end)

    %{
      function_count: results |> Enum.map(& &1.function_id) |> Enum.uniq() |> length(),
      signature_count: length(results),
      status_counts: counts
    }
  end

  defp error_code(%Selecto.Error{details: details}) when is_map(details) do
    Map.get(details, :code, :function_verification_error)
  end

  defp error_code(_error), do: :function_verification_error

  defp safe_function_id(function_id) when is_atom(function_id), do: Atom.to_string(function_id)
  defp safe_function_id(function_id) when is_binary(function_id), do: function_id
  defp safe_function_id(function_id), do: inspect(function_id, limit: 20, printable_limit: 100)
end
