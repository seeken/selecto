defmodule Selecto.Application do
  @moduledoc """
  Selecto's OTP application.

  Selecto starts only the task supervisor used for execution timeouts.
  The optional connection pool runtime (`Selecto.ConnectionPool.Runtime`)
  and the performance query cache (`Selecto.Performance.QueryCache`) are
  started lazily on first use; hosts that prefer supervised lifecycle
  management may add them to their own supervision tree instead (for the
  pool runtime, `children = [Selecto.ConnectionPool.Runtime, ...]`).
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Shared ETS tables are created here so that they belong to the
    # application rather than to a short-lived caller process.
    :ok = Selecto.Performance.Hooks.init_table()
    :ok = Selecto.Performance.ComplexityWarnings.init_table()

    children = [
      # Executor timeouts depend on this supervisor, so it stays supervised.
      {Task.Supervisor, name: Selecto.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Selecto.Supervisor)
  end
end
