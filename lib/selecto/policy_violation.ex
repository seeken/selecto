defmodule Selecto.PolicyViolation do
  @moduledoc "Raised when a query violates its configured governance policy."

  defexception [:type, :message, path: []]

  @type t :: %__MODULE__{
          type: atom(),
          message: String.t(),
          path: [term()]
        }
end
