defmodule Selecto.Configuration.Provider do
  @moduledoc """
  Adapts a host-owned source definition to a Selecto domain and executor.

  `configure/2` returns the domain, ordinary Selecto configuration options, and
  opaque execution context. Selecto validates the domain and options normally.
  `execute/3` must enforce the source's authorization and return Selecto's
  `{:ok, {rows, columns, aliases}}` result or `{:error, %Selecto.Error{}}`.

  Providers are trusted application modules, never user-supplied input.
  SQL metadata and streaming execution are unavailable for provider queries.
  """
  @callback configure(term(), keyword()) :: {map(), keyword(), term()}
  @callback execute(Selecto.t(), term(), keyword()) ::
              {:ok, {list(), list(), list()}} | {:error, Selecto.Error.t()}

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

  @doc false
  def ensure_sql_execution!(%Selecto{provider: nil}), do: :ok

  def ensure_sql_execution!(%Selecto{provider: provider}) do
    raise ArgumentError,
          "SQL execution helpers are unavailable for provider #{inspect(provider)}; use Selecto.execute/2"
  end
end
