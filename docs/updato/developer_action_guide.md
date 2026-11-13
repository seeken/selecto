# SelectoUpdato Developer Action Guide

`selecto_updato` is the executable write/action layer for Selecto domains. It
projects write metadata, validates write/action intents, plans domain actions,
authorizes them through host policy, and executes writes through adapters.

Use this guide when connecting generated Components action forms or API endpoints
to real writes.

## Package Boundaries

- `selecto` describes the domain: writable fields, operations, transitions,
  actions, capabilities, and choice sources.
- `selecto_components` renders action forms and sends preview/apply intents to
  the host.
- `selecto_updato` validates the write contract, plans an action from intent,
  authorizes the plan, and compiles portable write commands.
- The configured Selecto database adapter owns SQL/dialect compilation,
  connection handling, execution, and transactions.
- The host app owns policy resolver implementation, configured `%Selecto{}`
  selection, background jobs, telemetry, and HTTP/LiveView result formatting.

Updato should not know about Phoenix, LiveView, or the current UI. It receives
plain maps and returns plans, decisions, errors, and execution results.

## Write Contract

The `writes` section declares operation-level and field-level write rules:

```elixir
writes: %{
  operations: %{
    insert: %{enabled: true, returning: :record},
    update: %{enabled: true, require_filter: true, returning: :record},
    delete: %{enabled: false}
  },
  fields: %{
    id: %{insertable: false, updatable: false, server_managed: true},
    status: %{insertable: true, updatable: true, required_on: [:insert]},
    customer_id: %{insertable: true, updatable: false, choice_source: :customer_choices},
    updated_at: %{insertable: false, updatable: false, server_managed: true}
  },
  transitions: %{
    status: %{"pending" => ["approved", "cancelled"], "approved" => []}
  },
  scope: %{
    tenant: %{required: true, field: :tenant_id, sources: [:context, :actor]}
  }
}
```

Validate it before exposing endpoints:

```elixir
:ok = SelectoUpdato.validate_domain(domain)
{:ok, contract, diagnostics} = SelectoUpdato.DomainContract.json_document(domain)
```

The contract is read-only metadata. A successful contract build does not mean a
caller is authorized to write.

## Domain Actions

Actions are named plans over the write contract:

```elixir
actions: %{
  approve: %{
    type: :transition,
    scope: :row,
    target: :order,
    capability: "orders.approve",
    inputs: %{
      approved_at: %{type: :utc_datetime, required: false, default: {:system, :now}},
      note: %{type: :string, required: false}
    },
    preconditions: [
      {:eq, :balance_cents, 0},
      %{field: :fraud_hold, comparator: :neq, value: true}
    ],
    transition: %{field: :status, from: "pending", to: "approved"},
    execution: %{
      kind: :updato,
      operation: :update,
      set: %{status: "approved", approved_at: {:input, :approved_at}}
    }
  }
}
```

Plan an action from a Components/API intent:

```elixir
intent = %{
  "action" => "approve",
  "target" => %{"id" => 42},
  "inputs" => %{"note" => "Reviewed"},
  "confirmed" => true
}

{:ok, plan} = SelectoUpdato.plan_domain_action(domain, intent)
```

The plan is still non-executing. It normalizes the target, inputs, selected
variant, execution operation, and write changes.

Action `preconditions` are server-owned portable filters. Each predicate is
included in `plan.preconditions`, merged with the target and caller scope in
`plan.filters`, and carried into the final update/delete predicate. Lists are
conjunctive. Supported comparators are `eq`, `neq`, `gt`, `gte`, `lt`, `lte`,
and non-empty `in`; use `{field, value}`, `{comparator, field, value}`, a
JSON-safe equivalent, or a map with `field`, `comparator`, and `value`.
Portable execution requires source-row fields (including read-only source
fields), not joined or computed fields. The example assumes `balance_cents`
and `fraud_hold` are declared in the domain source. Filter preconditions
currently apply to direct `update` and `delete` actions; planning rejects them
on insert, upsert, and event-stream actions rather than ignoring them.

For a target order `42`, the example above executes only when `id = 42`,
`balance_cents = 0`, `fraud_hold != true`, and the transition-derived
`status = 'pending'` all still hold. A caller cannot weaken those predicates by
omitting or replacing intent filters.

## The Action Constraint Stack

Several contracts can reject the same action for different reasons. Keep their
jobs separate so a useful preview does not accidentally become write authority:

| Contract | Question it answers | Enforcement boundary |
| --- | --- | --- |
| Capability decision | May this actor attempt this action for this tenant and phase? | Trusted host policy, resolved again for Apply |
| Action `preconditions` | Does the selected source row still meet the action's fixed eligibility predicates? | Final atomic update/delete predicate |
| Transition guard | Is the stored state still the declared `from` state? | Final atomic mutation predicate |
| `selecto.data_rules.v1` binding | Are the submitted inputs or resulting candidate values valid? | Pure evaluation for input; protected state for candidate/transaction stages |
| Expected cardinality | Did the mutation affect exactly the intended set? | Adapter-owned transaction with rollback on mismatch |
| Native constraint declaration | Does the named database constraint still exist and map to this rule binding? | Adapter preflight and sanitized database-error mapping |

These checks compose; none substitutes for another. A button may be enabled
while the row has become stale. A row may satisfy its preconditions while an
action input violates a data rule. A passing data rule does not grant a
capability or satisfy tenant scope.

Canonical data rules may bind to `:action_input`, a root `:candidate`, or a
nested candidate collection. A partial update or nested delta cannot prove a
candidate rule from submitted fields alone. Updato therefore derives bounded
state requests from the Domain. The adapter must load the protected source
state, merge the authorized change, evaluate the resulting candidate, and
commit or roll back while the protection is still held. If that strategy is
not available, the operation fails closed; `required_data_rule_pending` is not
permission to dispatch.

An upsert has two possible branches. When a required rule needs candidate,
transaction, or evidence state, the adapter must provide a branch-aware
protected-state strategy. Treating the request as an insert check would let an
existing-row conflict branch bypass final-state rules, so unsupported adapters
return `upsert_rule_strategy_unsupported`.

Adapters implementing `protected_upsert_candidates` receive an
`UpsertCandidateRequest` with the actual command, including its declared
conflict target and governed update-field whitelist. The insert branch projects
the prospective inserted row; the conflict branch merges only those native
`EXCLUDED` update fields into the protected prior row. A `DO NOTHING` conflict
keeps that row unchanged and retains native affected-row and returning semantics.
Omitted defaults needed by a rule must be genuinely available, not guessed as
NULL. The compiler evaluates candidate rules once, realizes authorized
normalizations, and asks the adapter to reproject the final command using its
opaque receipt. Changed branches, changed prior rows, or unstable canonical
values fail closed. Remaining obligations and final authorization use that same
proven state. Receipts are private to one prepared transaction and bind the exact
command and trusted context; caller-supplied receipts do not establish support.
Compiling a protected upsert for inspection also requires this native strategy.

Choice membership is checked once against final realized assignments. A
protected conflict checks the persisted update fields against the proven final
record; ignored insert-only values cannot replace stored choice dependencies.
An opaque choice resolver may inspect any known field, so an active resolver
requires a complete native record projection. Unproved generated/default values
remain pending. An unchanged `DO NOTHING` conflict invokes no choice resolver.

`Multi.run` prepares governed operations inside one adapter-owned transaction
when protected storage is needed. Each operation keeps its own record-state
requirement. Independent protected upserts and ordinary mutations can compose;
the adapter rejects overlapping or unproved effects before the first business
mutation.

Portable rules can optionally name a database-native constraint by adapter,
constraint name, and category (`unique_violation`, `foreign_key_violation`,
`not_null_violation`, or `check_violation`). This is an obligation, not a hint.
An adapter advertising `native_constraint_mapping` verifies the named constraint
for the target relation before execution and correlates a matching database
failure with the rule binding. A missing or mismatched constraint fails closed;
raw driver diagnostics and unrelated constraint names remain private.

## Preview And Apply Flow

Recommended host flow:

```elixir
def preview_action(domain, intent, context) do
  with {:ok, plan} <- SelectoUpdato.plan_domain_action(domain, intent),
       {:ok, preview} <-
         SelectoUpdato.ActionExecutionAdapter.dry_run(
           MyApp.UpdatoActionAdapter,
           plan,
           context,
           capability_resolver: MyApp.UpdatoCapabilityResolver
         ) do
    {:ok, %{plan: plan, preview: preview}}
  end
end

def apply_action(domain, intent, context) do
  with {:ok, plan} <- SelectoUpdato.plan_domain_action(domain, intent),
       {:ok, result} <-
         SelectoUpdato.ActionExecutionAdapter.execute(
           MyApp.UpdatoActionAdapter,
           plan,
           context,
           capability_resolver: MyApp.UpdatoCapabilityResolver
         ) do
    {:ok, %{plan: plan, result: result}}
  end
end
```

Rules:

- Preview must not mutate data.
- Apply must re-plan and re-authorize; never trust a previous preview.
- A domain-backed plan contains an opaque, expiring operation handle. Do not
  pass `plan.operation_builder` to the raw write API; the action adapter receives
  a materialized operation only after authorization succeeds.
- The write adapter must enforce cardinality inside the same transaction as the
  mutation, so mismatches roll back.
- The host should shape API/LiveView responses; Updato should return structured
  results and errors.

## Capability Authorization

Updato delegates policy to a host resolver:

```elixir
defmodule MyApp.UpdatoCapabilityResolver do
  @behaviour SelectoUpdato.CapabilityResolver

  alias SelectoUpdato.CapabilityDecision

  def decide(request, context, _opts) do
    cond do
      is_nil(context[:actor]) ->
        {:ok,
         %CapabilityDecision{
           status: :hidden,
           capability: request.capability,
           reason: "An authenticated actor is required.",
           code: :missing_actor
         }}

      context.actor.role == :analyst and request.capability == "orders.approve" ->
        {:ok,
         %CapabilityDecision{
           status: :disabled,
           capability: request.capability,
           reason: "Managers must approve orders.",
           code: :manager_required
         }}

      true ->
        {:ok, %CapabilityDecision{status: :enabled, capability: request.capability}}
    end
  end
end
```

Authorize a plan:

```elixir
{:ok, decision} =
  SelectoUpdato.authorize_domain_action(plan, :execute, %{actor: user, tenant: tenant_id},
    capability_resolver: MyApp.UpdatoCapabilityResolver
  )
```

This standalone check is useful for presenting enabled, disabled, or hidden UI
state, but it does not issue execution authority. `ActionExecutionAdapter`
always calls the resolver again for the exact preview or execute phase and
supplies a single-use authorization grant to the host adapter callback.

The grant is also bound to the actor and tenant identity presented to the
resolver. Identity may be supplied in the context or adapter options; when both
sources are present they must agree. Atom and string spellings of actor, tenant,
tenant-id, and tenant-field keys must also agree. Updato propagates opts-only
identity into the authorized callback context. The host must pass that context
through unchanged when compiling the materialized operation. Actor, tenant, or
phase substitution, including ambiguous duplicate-key injection by a callback,
invalidates the grant without producing a command.

Updato consumes the grant before any choice-membership resolver or other
callback-backed validation runs. A later validation failure still burns that
single-use grant; callers must start a new authorization attempt rather than
retrying the materialized builder.

If no resolver is configured, actions without a capability may proceed, but
actions with a capability require a resolver. That keeps privileged writes from
silently becoming public.

## Intent Validation

Use write/action intent validation for generated APIs or clients:

```elixir
result =
  SelectoUpdato.validate_domain_intent(domain, %{
    "operation" => "update",
    "fields" => ["status"]
  })

if result.valid?, do: :ok, else: {:error, result.errors}
```

For action forms:

```elixir
result =
  SelectoUpdato.validate_domain_intent(domain, %{
    "action" => "approve",
    "target" => %{"id" => 42},
    "inputs" => %{"note" => "Reviewed"}
  })
```

Validation is non-executing. It checks whether an intent references exposed
operations, actions, and writable fields. It should run before planning in API
endpoints when you want diagnostics without execution.

## Choice-Source Membership

Writable fields can reference Selecto choice sources. Updato can validate that
submitted values belong to the scoped option set.

```elixir
SelectoUpdato.new(domain,
  choice_source_membership_resolver: &MyApp.Choices.resolve_membership/1
)
|> SelectoUpdato.insert(%{customer_id: 123, status: "pending"})
|> SelectoUpdato.execute(selecto)
```

For domain actions, validate choice-backed inputs or fields before execution.
Use fail-closed behavior for tenant-sensitive foreign keys.

## Variants And Discriminators

Actions may expose variants for production-grade generated forms:

```elixir
actions: %{
  check_in: %{
    inputs: %{
      documents_complete: %{type: :boolean, required: true, discriminator: true},
      checked_in_at: %{type: :utc_datetime, required: false, default: {:system, :now}}
    },
    variants: [
      %{
        id: :standard,
        when: %{documents_complete: true},
        execution: %{kind: :updato, operation: :update, set: %{status: "checked_in"}}
      },
      %{
        id: :missing_documents,
        when: %{documents_complete: false},
        inputs: %{follow_up_note: %{type: :string, required: true}},
        execution: %{kind: :updato, operation: :update, set: %{status: "checked_in"}}
      }
    ]
  }
}
```

Planner expectations:

- discriminator inputs select one matching variant
- variant inputs extend or refine base inputs
- defaults are resolved before execution values are built
- invalid or missing discriminator values should fail during planning

## Bulk Actions

Bulk actions should be explicit:

```elixir
%{
  writes: %{
    operations: %{
      update: %{enabled: true, bulk: true, require_filter: true}
    }
  },
  actions: %{
    mark_reviewed: %{
      type: :bulk_action,
      scope: :bulk,
      capability: "orders.review",
      execution: %{kind: :updato, operation: :update, set: %{reviewed: true}}
    }
  }
}
```

The client target is the whole selected set, never a representative first row:

```elixir
%{"action" => "mark_reviewed", "target" => %{"ids" => [41, 42, 43]}}
```

Bulk safety rules:

- reject empty and duplicate selected-id sets
- normalize selected ids using the domain primary-key type
- compile the whole set as a parameterized `IN` predicate
- derive `{:exactly, selected_count}` cardinality for concrete selected ids
- enforce the action's published `selection.min_rows` and `selection.max_rows`
  before building a concrete bulk operation
- preserve transition `from` state as an additional write predicate
- re-authorize at apply time
- cap maximum row count in the host if needed
- return per-row or aggregate result details
- avoid destructive bulk actions unless confirmation is explicit
- require the adapter to roll back if affected rows differ from selected rows

## Execution

Simple direct writes can use the core pipeline:

```elixir
SelectoUpdato.new(domain)
|> SelectoUpdato.filter({"id", 42})
|> SelectoUpdato.update(%{status: "approved"})
|> SelectoUpdato.execute(selecto)
```

Action execution adapters usually translate `ActionPlan` into that pipeline.
Host adapters should:

- whitelist fields from the plan
- apply tenant scope
- validate choice-source membership
- validate transitions
- pass the portable command to the configured Selecto adapter
- return structured result maps

## Error Shape

Prefer stable machine codes and structured details. Typical error tuple:

```elixir
{:validation_error, "Managers must approve orders.",
 %{code: :manager_required, capability: "orders.approve", phase: :execute}}
```

For API responses, keep the shape predictable:

```elixir
%{
  ok: false,
  error: %{
    type: "validation_error",
    code: "manager_required",
    message: "Managers must approve orders.",
    path: ["intent", "inputs", "approved_at"],
    capability: "orders.approve"
  }
}
```

## Host API Pattern

Recommended endpoints:

- `GET /api/selecto/:domain/write-contract.json`
- `POST /api/selecto/:domain/write-intent/validate`
- `POST /api/selecto/:domain/actions/:action/preview`
- `POST /api/selecto/:domain/actions/:action/apply`

Preview/apply should accept the same intent shape Components emits. Apply should
return result and reload metadata that the host LiveView can hand back to
Components:

```elixir
%{
  result: %{record: updated_record},
  reload: %{
    status: "refreshed",
    surface: "selecto_results",
    message: "Current results were rerun after the action."
  }
}
```

## Testing Checklist

- `SelectoUpdato.validate_domain/1` accepts the authored domain.
- `DomainContract.json_document/2` includes expected operations, fields, actions,
  relationships, and capabilities.
- invalid write intents return diagnostics without executing.
- every generated action can be planned.
- preview authorizes but does not write.
- apply re-authorizes and writes.
- capability denial is tested for preview and execute.
- choice-source membership denial is tested.
- target-required actions reject missing target ids.
- bulk actions reject empty or unauthorized target sets.
- result maps include enough data for Components to render success, failure, and
  reload state.
