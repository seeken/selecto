defmodule SelectoUpdato.PlannedOperation do
  @moduledoc """
  Opaque handle for an operation derived from a domain action plan.

  Planned operations are deliberately not ordinary `%SelectoUpdato.Operation{}`
  values. They can only be materialized after `ActionExecutionAdapter` has
  authorized the matching action plan. Direct write and portable-command APIs
  reject this handle.
  """

  @opaque t :: %__MODULE__{token: reference()}

  @enforce_keys [:token]
  defstruct [:token]
end

defimpl Inspect, for: SelectoUpdato.PlannedOperation do
  import Inspect.Algebra

  def inspect(_planned_operation, _opts) do
    concat(["#SelectoUpdato.PlannedOperation<opaque>"])
  end
end
