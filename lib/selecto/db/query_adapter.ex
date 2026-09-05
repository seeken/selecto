defmodule Selecto.DB.QueryAdapter do
  @moduledoc """
  Public versioned source-query SPI. Host applications explicitly inject an
  adapter and connection; importing an adapter creates no connection or registry.
  SQL adapters retain `Selecto.DB.Adapter` during incremental migration.
  """
  alias Selecto.Query.{CapabilityProfile, Compiled, Plan, Result}
  @callback contract_version() :: 1
  @callback capabilities(term(), map()) ::
              {:ok, CapabilityProfile.t()} | {:error, Selecto.Error.t()}
  @callback compile_query(term(), Plan.t(), keyword()) ::
              {:ok, Compiled.t()} | {:error, Selecto.Error.t()}
  @callback preview_query(term(), Compiled.t(), keyword()) ::
              {:ok, map()} | {:error, Selecto.Error.t()}
  @callback execute_query(term(), Compiled.t(), keyword()) ::
              {:ok, Result.t()} | {:error, Selecto.Error.t()}
  @callback explain_query(term(), Compiled.t(), keyword()) ::
              {:ok, map()} | {:error, Selecto.Error.t()}
  @callback infer_shapes(term(), map(), map(), keyword()) ::
              {:ok, map()} | {:error, Selecto.Error.t()}
  @optional_callbacks explain_query: 3, infer_shapes: 4
end
