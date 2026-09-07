defmodule Selecto.Rule.Compiler do
  @moduledoc "Public compiler entrypoint for canonical Selecto data rules."

  @spec compile(term()) :: {:ok, Selecto.Rule.Contract.t()} | {:error, [map()]}
  defdelegate compile(input), to: Selecto.Rule.Contract
end
