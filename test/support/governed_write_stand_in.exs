# Core does not depend on selecto_updato, whose SelectoUpdato.GovernedWrite is
# the only module allowed to issue write authorizations. Core's own tests use
# this stand-in of the same name to exercise the governed path; it is never
# compiled into the library.
defmodule SelectoUpdato.GovernedWrite do
  @moduledoc false

  alias Selecto.Write.Authorization

  def authorize(write) do
    case Authorization.issue(write) do
      {:ok, authorization} -> {:ok, authorization}
      {:error, error} -> {:error, error}
    end
  end

  def execute(selecto, write, opts \\ []) do
    with {:ok, authorization} <- Authorization.issue(write) do
      Selecto.Write.execute(selecto, write, Keyword.put(opts, :authorization, authorization))
    end
  end

  def prepared(write, context) do
    with {:ok, authorization} <- Authorization.issue(write) do
      {:ok, write, context, authorization}
    end
  end
end
