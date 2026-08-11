defmodule Selecto.Write.Graph.Row do
  @moduledoc "A path-addressed command row inside a portable write graph node."

  alias Selecto.Write.{Command, Graph}

  @type path_segment :: atom() | String.t() | non_neg_integer()

  @type t :: %__MODULE__{
          id: String.t(),
          path: [path_segment()],
          command: Command.t(),
          bindings: [Graph.Binding.t()],
          metadata: map()
        }

  @enforce_keys [:id, :path, :command]
  defstruct [:id, :path, :command, bindings: [], metadata: %{}]
end
