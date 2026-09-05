defmodule Selecto.Query.Compiled do
  @moduledoc "Adapter-owned compiled query; only safe metadata is inspectable."
  @derive {Inspect, only: [:backend, :metadata]}
  defstruct [:backend, :artifact, :plan, metadata: %{}]
  @type t :: %__MODULE__{}
end
