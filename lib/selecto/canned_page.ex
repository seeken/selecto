defmodule Selecto.CannedPage do
  @moduledoc """
  Authored search pages over a request-authorized Selecto query.

  Definitions contain fixed views and promoted controls. Browser state cannot
  supply selectors, operators, SQL, connections or scope. Pass a freshly
  authorized, unprojected query to `run/3` for every request.
  """
  alias Selecto.CannedPage.{Definition, Planner, Runner, State}

  defdelegate new!(selecto, options), to: Definition
  defdelegate normalize_state(page, input), to: State, as: :normalize
  defdelegate plan(page, selecto, input), to: Planner, as: :build
  defdelegate run(page, selecto, input), to: Runner
end
