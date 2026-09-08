defmodule Selecto.Telemetry.ContextProvider do
  @moduledoc """
  Optional host integration for propagating observability context across the
  process boundaries owned by Selecto.

  Implementations must be fast, local, and must not perform network I/O.
  """

  @callback capture() :: term()
  @callback attach(term()) :: term()
  @callback detach(term()) :: term()
end
