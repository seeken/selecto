defmodule SelectoUpdato.ActionPlan do
  @moduledoc """
  A non-executing plan for a domain-declared action.

  Action plans translate Selecto domain action metadata into Updato operation
  intent. Domain-backed plans carry an opaque, expiring operation handle that
  only `SelectoUpdato.ActionExecutionAdapter` can materialize after authorization;
  they deliberately do not talk to a repo or mutate data.
  """

  alias SelectoUpdato.{Operation, PlannedOperation}

  @type t :: %__MODULE__{
          action: String.t() | nil,
          type: String.t() | atom() | nil,
          label: String.t() | nil,
          description: String.t() | nil,
          capability: String.t() | atom() | nil,
          icon: String.t() | atom() | nil,
          confirmation: map() | nil,
          audit: map() | nil,
          presentation: map() | nil,
          operation: String.t() | nil,
          operation_intent: map() | nil,
          operation_builder: PlannedOperation.t() | Operation.t() | nil,
          authorization_grant: reference() | nil,
          scope: String.t() | nil,
          transition: map() | nil,
          preconditions: [map()] | nil,
          execution: map() | nil,
          inputs: map() | nil,
          variant: String.t() | nil,
          execution_case: String.t() | nil,
          collection_patches: map() | nil,
          collection_operations: map() | nil,
          target: term(),
          filters: [term()] | nil,
          changes: map() | nil,
          returning: term(),
          expected_cardinality: term(),
          diagnostics: map() | nil
        }

  defstruct [
    :action,
    :type,
    :label,
    :description,
    :capability,
    :icon,
    :confirmation,
    :audit,
    :presentation,
    :operation,
    :operation_intent,
    :operation_builder,
    :authorization_grant,
    :scope,
    :transition,
    :execution,
    :variant,
    :execution_case,
    :target,
    :filters,
    :changes,
    :returning,
    :expected_cardinality,
    preconditions: [],
    inputs: %{},
    collection_patches: %{},
    collection_operations: %{},
    diagnostics: %{errors: [], warnings: []}
  ]
end
