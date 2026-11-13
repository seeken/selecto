defmodule SelectoUpdato.GovernedWrite do
  @moduledoc false

  # The governed entry point's handoff to Selecto.Write. Every caller has
  # already compiled the write from its domain's `writes` contract in this
  # execution; this module issues the single-use Selecto.Write.Authorization
  # for exactly that payload, which the adapter requires before it runs.
  #
  # Selecto.Write.Authorization accepts issuance only from this module, so
  # each issue/1 call below must stay in a non-tail position.

  alias Selecto.Write.Authorization

  @spec execute(Selecto.t(), Selecto.Write.command(), keyword()) ::
          {:ok, Selecto.Write.execution_result()} | {:error, Selecto.Write.Error.t()}
  def execute(%Selecto{} = selecto, write, opts) do
    with {:ok, authorization} <- Authorization.issue(write) do
      Selecto.Write.execute(selecto, write, Keyword.put(opts, :authorization, authorization))
    end
  end

  @doc false
  # The result a governed preparation hands to Selecto.Write.execute_prepared/3.
  @spec prepared(Selecto.Write.command(), map()) ::
          {:ok, Selecto.Write.command(), map(), Authorization.t()}
          | {:error, Selecto.Write.Error.t()}
  def prepared(write, context) do
    with {:ok, authorization} <- Authorization.issue(write) do
      {:ok, write, context, authorization}
    end
  end
end
