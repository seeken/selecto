defmodule Selecto.Application do
  @moduledoc """
  Selecto's OTP application.

  Selecto starts only the task supervisor used for execution timeouts.
  The optional connection pool runtime (`Selecto.ConnectionPool.Runtime`)
  and the performance query cache (`Selecto.Performance.QueryCache`) are
  started lazily on first use; hosts that prefer supervised lifecycle
  management may add them to their own supervision tree instead.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Executor timeouts depend on this supervisor, so it stays supervised.
      {Task.Supervisor, name: Selecto.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Selecto.Supervisor)
  end
end
