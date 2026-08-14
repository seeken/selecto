defmodule Selecto.FunctionVerification do
  @moduledoc """
  Dispatches registered-function signature verification to database adapters.

  This layer never executes the registered function. Adapters that advertise
  `:function_verification` may inspect catalogs and use non-executing
  prepare/describe facilities in their `verify_function/3` callback.
  """

  alias Selecto.FunctionVerification.{Report, Request}

  @modes [:off, :warn, :strict]

  @spec verify(Selecto.t(), atom() | String.t(), [term()], atom(), keyword()) ::
          {:ok, Report.t()} | {:error, Selecto.Error.t()}
  def verify(selecto, function_id, args, call_site, opts \\ [])

  def verify(%Selecto{} = selecto, function_id, args, call_site, opts)
      when is_list(args) and is_atom(call_site) and is_list(opts) do
    mode = Keyword.get(opts, :mode, :warn)

    with :ok <- validate_mode(mode),
         {:ok, signature} <- resolve_signature(selecto, function_id, args, call_site),
         {:ok, request} <- Request.new(function_id, signature, call_site) do
      dispatch(selecto, request, mode, opts)
    end
  end

  def verify(%Selecto{}, function_id, _args, call_site, _opts) do
    {:error,
     Selecto.Error.validation_error("invalid function verification call", %{
       code: :invalid_function_verification_call,
       function_id: normalize_id(function_id),
       call_site: call_site
     })}
  end

  @doc false
  @spec verify_request(Selecto.t(), Request.t(), keyword()) ::
          {:ok, Report.t()} | {:error, Selecto.Error.t()}
  def verify_request(%Selecto{} = selecto, %Request{} = request, opts \\ [])
      when is_list(opts) do
    mode = Keyword.get(opts, :mode, :warn)

    with :ok <- validate_mode(mode) do
      dispatch(selecto, request, mode, opts)
    end
  end

  defp dispatch(%Selecto{adapter: adapter}, request, :off, _opts) do
    {:ok,
     Report.local(request, adapter_identity(adapter), :unverified, %{
       diagnostics: [%{code: :function_verification_disabled}]
     })}
  end

  defp dispatch(%Selecto{adapter: adapter, connection: connection}, request, mode, opts) do
    cond do
      not Selecto.AdapterSupport.supports_feature?(adapter, :function_verification) ->
        finish(
          Report.local(request, adapter_identity(adapter), :unsupported_adapter, %{
            diagnostics: [%{code: :function_verification_not_supported}]
          }),
          mode
        )

      not Selecto.AdapterSupport.callback_available?(adapter, :verify_function, 3) ->
        finish(
          Report.local(request, adapter_identity(adapter), :unsupported_adapter, %{
            diagnostics: [%{code: :function_verification_callback_missing}]
          }),
          mode
        )

      true ->
        adapter_opts = Keyword.drop(opts, [:mode, :call_site])

        adapter
        |> safe_adapter_call(connection, request, adapter_opts)
        |> normalize_result(request, adapter, mode)
    end
  end

  defp safe_adapter_call(adapter, connection, request, opts) do
    adapter.verify_function(connection, request, opts)
  rescue
    _exception -> {:callback_failure, :exception}
  catch
    kind, _reason -> {:callback_failure, kind}
  end

  defp normalize_result({:ok, result}, request, adapter, mode) do
    case Report.from_adapter(request, adapter_identity(adapter), result) do
      {:ok, report} -> finish(report, mode)
      {:error, error} -> normalize_invalid_report(error, request, adapter, mode)
    end
  end

  defp normalize_result({:error, %Selecto.Error{} = error}, request, adapter, mode) do
    report =
      Report.local(request, adapter_identity(adapter), :indeterminate, %{
        diagnostics: [%{code: :function_verification_adapter_rejected, type: error.type}]
      })

    finish(report, mode)
  end

  defp normalize_result({:callback_failure, class}, request, adapter, mode) do
    report =
      Report.local(request, adapter_identity(adapter), :indeterminate, %{
        diagnostics: [%{code: :function_verification_callback_failed, class: class}]
      })

    finish(report, mode)
  end

  defp normalize_result(_other, request, adapter, mode) do
    report =
      Report.local(request, adapter_identity(adapter), :indeterminate, %{
        diagnostics: [%{code: :function_verification_invalid_callback_result}]
      })

    finish(report, mode)
  end

  defp normalize_invalid_report(error, request, adapter, mode) do
    report =
      Report.local(request, adapter_identity(adapter), :indeterminate, %{
        diagnostics: [%{code: error.details.code}]
      })

    finish(report, mode)
  end

  defp finish(%Report{} = report, :warn), do: {:ok, report}

  defp finish(%Report{} = report, :strict) do
    if Report.successful?(report) do
      {:ok, report}
    else
      {:error,
       Selecto.Error.validation_error("database function verification did not succeed", %{
         code: :function_verification_failed,
         adapter: report.adapter,
         function_id: report.function_id,
         status: report.status,
         diagnostics: report.diagnostics
       })}
    end
  end

  defp resolve_signature(selecto, function_id, args, call_site) do
    case Selecto.FunctionSpec.resolve(selecto, function_id, args, call_site) do
      {:ok, signature} ->
        {:ok, signature}

      {:error, error} ->
        {:error,
         Selecto.Error.validation_error(error.message, %{
           code: error.code,
           function_id: error.function_id,
           resolution: error.details
         })}
    end
  end

  defp validate_mode(mode) when mode in @modes, do: :ok

  defp validate_mode(mode) do
    {:error,
     Selecto.Error.validation_error("invalid function verification mode", %{
       code: :invalid_function_verification_mode,
       actual: mode,
       allowed: @modes
     })}
  end

  defp adapter_identity(adapter), do: Selecto.AdapterSupport.adapter_name(adapter) || adapter

  defp normalize_id(value) when is_atom(value) or is_binary(value),
    do: Selecto.UDF.normalize_id(value)

  defp normalize_id(_value), do: nil
end
