defmodule Selecto.FunctionVerification.Report do
  @moduledoc """
  Normalized evidence returned by connected database-function verification.

  A report is evidence for one adapter, connection context, and exact request
  fingerprint. It is not evidence that the function is semantically correct for
  arbitrary inputs.
  """

  alias Selecto.FunctionVerification.Request

  @protocol_version 1
  @statuses [
    :database_resolved,
    :unsupported_adapter,
    :missing_function,
    :signature_mismatch,
    :return_mismatch,
    :permission_denied,
    :missing_requirement,
    :indeterminate,
    :unverified
  ]

  @enforce_keys [
    :protocol_version,
    :status,
    :proof_level,
    :adapter,
    :function_id,
    :signature_fingerprint,
    :evidence,
    :diagnostics
  ]
  defstruct @enforce_keys ++ [:resolved_identity, :server, :requirements]

  @type status ::
          :database_resolved
          | :unsupported_adapter
          | :missing_function
          | :signature_mismatch
          | :return_mismatch
          | :permission_denied
          | :missing_requirement
          | :indeterminate
          | :unverified

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          status: status(),
          proof_level: :connected_preflight | :none,
          adapter: atom() | module(),
          function_id: String.t(),
          signature_fingerprint: String.t(),
          resolved_identity: String.t() | nil,
          server: map() | nil,
          requirements: map(),
          evidence: map(),
          diagnostics: [map()]
        }

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec from_adapter(Request.t(), atom() | module(), map() | t()) ::
          {:ok, t()} | {:error, Selecto.Error.t()}
  def from_adapter(%Request{} = request, adapter, %__MODULE__{} = report) do
    from_adapter(request, adapter, Map.from_struct(report))
  end

  def from_adapter(%Request{} = request, adapter, result) when is_map(result) do
    status = map_value(result, :status)

    if status in @statuses and status not in [:unsupported_adapter, :unverified] do
      {:ok,
       %__MODULE__{
         protocol_version: @protocol_version,
         status: status,
         proof_level: :connected_preflight,
         adapter: adapter,
         function_id: request.function_id,
         signature_fingerprint: request.signature_fingerprint,
         resolved_identity: map_value(result, :resolved_identity),
         server: normalize_map(map_value(result, :server)),
         requirements: request.requirements,
         evidence: normalize_map(map_value(result, :evidence)),
         diagnostics: normalize_diagnostics(map_value(result, :diagnostics))
       }}
    else
      {:error,
       Selecto.Error.validation_error(
         "function verification adapter returned an invalid report",
         %{
           code: :invalid_function_report,
           adapter: adapter,
           status: status
         }
       )}
    end
  end

  def from_adapter(%Request{} = request, adapter, _result) do
    {:error,
     Selecto.Error.validation_error("function verification adapter returned an invalid report", %{
       code: :invalid_function_report,
       adapter: adapter,
       function_id: request.function_id
     })}
  end

  @spec local(Request.t(), atom() | module(), status(), map()) :: t()
  def local(%Request{} = request, adapter, status, attrs \\ %{})
      when status in [:unsupported_adapter, :indeterminate, :unverified] and is_map(attrs) do
    %__MODULE__{
      protocol_version: @protocol_version,
      status: status,
      proof_level: if(status == :unverified, do: :none, else: :connected_preflight),
      adapter: adapter,
      function_id: request.function_id,
      signature_fingerprint: request.signature_fingerprint,
      resolved_identity: nil,
      server: nil,
      requirements: request.requirements,
      evidence: Map.get(attrs, :evidence, %{}),
      diagnostics: Map.get(attrs, :diagnostics, [])
    }
  end

  @spec successful?(t()) :: boolean()
  def successful?(%__MODULE__{status: :database_resolved}), do: true
  def successful?(%__MODULE__{}), do: false

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}
  defp normalize_diagnostics(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp normalize_diagnostics(_value), do: []
end
