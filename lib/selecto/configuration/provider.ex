defmodule Selecto.Configuration.Provider do
  @moduledoc """
  Adapts a host-owned source definition to a Selecto domain and executor.

  `configure/2` returns the domain, ordinary Selecto configuration options, and
  opaque execution context. Selecto validates the domain and options normally.
  `execute/3` must enforce the source's authorization and return Selecto's
  `{:ok, {rows, columns, aliases}}` result or `{:error, %Selecto.Error{}}`.

  Providers are trusted application modules, never user-supplied input.
  Optional execution callbacks support metadata, counts, sums, and streaming.
  A missing callback returns a structured unsupported-operation error.
  """
  @callback configure(term(), keyword()) :: {map(), keyword(), term()}
  @callback execute(Selecto.t(), term(), keyword()) ::
              {:ok, {list(), list(), list()}} | {:error, Selecto.Error.t()}

  @callback execute_with_metadata(Selecto.t(), term(), keyword()) ::
              {:ok, term(), map()} | {:error, Selecto.Error.t()}
  @callback execute_count_with_metadata(Selecto.t(), term(), keyword()) ::
              {:ok, non_neg_integer(), map()} | {:error, Selecto.Error.t()}
  @callback execute_projection_sum_with_metadata(Selecto.t(), term(), binary(), keyword()) ::
              {:ok, term(), map()} | {:error, Selecto.Error.t()}
  @callback execute_stream(Selecto.t(), term(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, Selecto.Error.t()}
  @optional_callbacks execute_with_metadata: 3,
                      execute_count_with_metadata: 3,
                      execute_projection_sum_with_metadata: 4,
                      execute_stream: 3

  @doc false
  def invoke(selecto, operation, args) do
    try do
      Selecto.Policy.validate_query!(selecto)
      provider = selecto.provider
      arguments = [selecto, selecto.provider_context | args]

      if function_exported?(provider, operation, length(arguments)) do
        apply(provider, operation, arguments)
      else
        {:error,
         Selecto.Error.validation_error(
           "Provider #{inspect(provider)} does not support #{operation}"
         )}
      end
    rescue
      error -> {:error, Selecto.Error.from_reason(error)}
    end
  end

  @doc false
  def configure(provider, source, connection, opts) do
    unless is_atom(provider) and Code.ensure_loaded?(provider) and
             function_exported?(provider, :configure, 2) and
             function_exported?(provider, :execute, 3) do
      raise ArgumentError, "expected a Selecto.Configuration.Provider module"
    end

    {domain, core_opts, context} = provider.configure(source, opts)
    selecto = Selecto.configure(domain, connection, core_opts)
    %{selecto | provider: provider, provider_context: context}
  end
end
