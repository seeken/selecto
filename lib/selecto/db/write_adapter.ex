defmodule Selecto.DB.WriteAdapter do
  @moduledoc """
  Optional write behavior for a `Selecto.DB.Adapter` implementation.

  Implementing this behavior means the adapter can preserve the complete
  semantics of a portable `Selecto.Write.Command` or atomic
  `Selecto.Write.Batch`/`Selecto.Write.Graph`. Read-only adapters simply omit it.
  """

  @type connection :: term()
  @type command ::
          Selecto.Write.Command.t() | Selecto.Write.Batch.t() | Selecto.Write.Graph.t()
  @type execution_result :: Selecto.Write.Result.t() | [Selecto.Write.Result.t()]

  @callback write_capabilities(connection()) :: map()

  @callback preview_write(connection(), command(), keyword()) ::
              {:ok, Selecto.Write.Preview.t()} | {:error, Selecto.Write.Error.t()}

  @callback execute_write(connection(), command(), keyword()) ::
              {:ok, execution_result()} | {:error, Selecto.Write.Error.t()}
end
