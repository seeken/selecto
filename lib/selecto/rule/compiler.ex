defmodule Selecto.Rule.Compiler do
  @moduledoc "Public compiler entrypoint for canonical Selecto data rules."

  @spec compile(term()) :: {:ok, Selecto.Rule.Contract.t()} | {:error, [map()]}
  defdelegate compile(input), to: Selecto.Rule.Contract

  @spec compile_rules(term()) :: {:ok, Selecto.Rule.Contract.t()} | {:error, [map()]}
  defdelegate compile_rules(rules), to: Selecto.Rule.Contract

  @spec compile_rules(term(), keyword()) :: {:ok, Selecto.Rule.Contract.t()} | {:error, [map()]}
  defdelegate compile_rules(rules, opts), to: Selecto.Rule.Contract
end
