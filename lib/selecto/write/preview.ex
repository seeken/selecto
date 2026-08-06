defmodule Selecto.Write.Preview do
  @moduledoc "Opaque adapter-generated preview of a portable write command."

  @type statement :: %{required(:text) => String.t(), optional(:params) => [term()]}
  @type t :: %__MODULE__{statements: [statement()], metadata: map()}

  @enforce_keys [:statements]
  defstruct statements: [], metadata: %{}
end
