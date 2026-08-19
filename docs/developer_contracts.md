# Selecto Developer Contracts

Selecto core owns the authored domain contract and the read/query projection.
Companion packages consume that contract, but core should stay execution-neutral:
it describes fields, joins, reusable query definitions, component-facing UI
policy, capabilities, actions, choices, published views, and write metadata; it
does not decide who may use them and it does not execute writes.

Use this guide when authoring or reviewing domain metadata that will be consumed
by `selecto_components`, `selecto_updato`, generated API endpoints, or host
applications.

## Package Boundaries

- `selecto` owns domain normalization, validation, overlays, field references,
  portable query libraries, query projections, component-facing UI metadata,
  capability references, choice source metadata, and published view metadata.
- `selecto_components` owns Phoenix/LiveView UX, query-contract JSON/Markdown
  artifacts, generated action forms, export panels, scheduled-export forms,
  embed surfaces, and user-facing result/error presentation.
- `selecto_updato` owns write-contract projection, write/action intent
  validation, domain action planning, capability authorization handoff, and write
  execution adapters.
- Host applications own policy decisions, persistence, background workers,
  delivery adapters, actual write execution, telemetry routing, and reload UX.

Core domain metadata should be stable enough for consumers to reason about, but
should not smuggle host policy or runtime execution concerns into Selecto.

## Authoring Flow

1. Define the base read domain: `source`, `schemas`, `joins`, `filters`,
   `functions`, `query_members`, `query_library`, `custom_columns`, and defaults.
2. Add `components` when a UI consumer needs domain-selected state-exposure
   policy such as `query_params: false`.
3. Add `capabilities` for the operations that host policy may need to control.
4. Attach capability ids to fields, filters, query members, published views,
   detail actions, choice sources, and domain actions.
5. Add `choice_sources` and bind them from columns when generated forms or
   query-contract clients need constrained option selection.
6. Add `published_views` when a stable, host-managed database view or materialized
   view should be advertised to consumers.
7. Add `writes` when the domain exposes insert/update/delete/upsert surfaces.
8. Add `actions` when the domain exposes named user workflows over the write
   surface.
9. Normalize and validate the domain before shipping it to Components or Updato.

Recommended core checks:

```elixir
{:ok, normalized, diagnostics} = Selecto.Domain.normalize(domain)
projection = Selecto.Domain.project(normalized, :query_contract)
```

When the domain also exposes writes or actions, run the Updato contract checks
in the host app or the `selecto_updato` package:

```elixir
:ok = SelectoUpdato.validate_domain(domain)
{:ok, write_contract, _diagnostics} = SelectoUpdato.DomainContract.json_document(domain)
```

`diagnostics.errors` should be empty. Warnings can be acceptable during migration,
but generated or published artifacts should treat warnings as review items.

## Capabilities

Capabilities are stable ids that describe policy-relevant surfaces. Core only
validates references; host applications decide whether the current actor may use
them.

Example:

```elixir
capabilities: %{
  "orders.analytics" => %{operations: [:select, :published_view]},
  "orders.choose_customer" => %{operations: [:choice_source]},
  "orders.approve" => %{operations: [:action]},
  "orders.write" => %{operations: [:insert, :update]}
}
```

Recommended id style:

- Prefix by domain: `orders.approve`, `camp_registrations.check_in`.
- Use nouns for surfaces and verbs for actions.
- Keep ids stable; changing ids is a policy-breaking change.
- Do not encode roles in ids. Roles belong in the host resolver.

Attach capabilities where policy matters:

```elixir
filters: %{
  "private_queue" => %{field: :status, type: :string, capability: "orders.private_queue"}
},
published_views: %{
  "order_rollups" => %{kind: :view, database_name: "order_rollups", capability: "orders.analytics"}
},
choice_sources: %{
  customer_choices: %{domain: :customer, value_field: :id, label_field: :name, capability: "orders.choose_customer"}
},
actions: %{
  approve: %{scope: :row, capability: "orders.approve", execution: %{kind: :updato, operation: :update}}
}
```

## Choice Sources

Choice sources describe host-verifiable option sets. They let generated UI and
API clients avoid free-form foreign keys while leaving option resolution to the
host package or app.

```elixir
source_relationships: %{
  order_customer: %{
    target_domain: :customer,
    source_field: :customer_id,
    target_field: :id
  }
},
choice_sources: %{
  customer_choices: %{
    domain: :customer,
    value_field: :id,
    label_field: :name,
    source_relationship: :order_customer,
    filters: [{:eq, "customer.active", true}],
    order_by: [:name],
    constraint_policy: %{domain_of_interest: :fail_closed},
    presentation: %{control: :autocomplete, mode: :async, cardinality: :one},
    capability: "orders.choose_customer"
  }
},
source: %{
  columns: %{
    customer_id: %{type: :integer, choice_source: :customer_choices}
  }
}
```

Core validates that choice-source references are known. Components project choice
source metadata into query contracts and forms. Updato can validate submitted
choice values before writing.

Use `constraint_policy: %{domain_of_interest: :fail_closed}` when a client must
not silently accept an option outside the scoped domain.

## Portable Query Libraries

`query_library` keeps recurring application query intent in four named,
portable registries: `segments`, `projections`, `orderings`, and `views`.

```elixir
query_library: %{
  segments: %{
    active_orders: %{filters: [{:status, "active"}]}
  },
  projections: %{
    order_summary: %{fields: [:id, :customer_id, :status]}
  },
  orderings: %{
    newest_first: %{order_by: [{:inserted_at, :desc}, {:id, :asc}]}
  },
  views: %{
    active_order_summaries: %{
      segments: [:active_orders],
      projection: :order_summary,
      ordering: :newest_first
    }
  }
}
```

Core normalization and `:query_contract` projection preserve the complete
library. Contract validation rejects malformed registries, unknown references,
invalid field or association paths, composition cycles, and invalid boolean
segment groups before SQL generation. Required domain filters, selections, and
ordering remain in force after a named definition is applied.

Segments are reusable query predicates, not authorization decisions. Keep
tenant and visibility authority in required domain policy or trusted host
context. See [Portable Query Libraries](query_library.md) for the DSL, typed
parameters, boolean composition, recursive projection merging, and runtime APIs.

## Component-Facing Policy

Use canonical `components` metadata for policy consumed by compatible UI
packages without exposing it to query, write, or API projections:

```elixir
components: %{query_params: false}
```

`query_params: false` keeps editable explorer state out of generated URLs and
causes compatible consumers to ignore inbound URL state. Missing policy defaults
to the shareable URL behavior. Malformed authored policy must fail closed in a
consumer that handles sensitive state. This setting reduces URL exposure; it
does not replace authorization or protect state on other host-owned surfaces.

## Published Views

Published views advertise stable read surfaces that a host can materialize,
embed, schedule, or expose to clients.

```elixir
published_views: %{
  "order_state_rollups" => %{
    database_name: "order_state_rollups",
    kind: :view,
    query: fn selecto ->
      selecto
      |> Selecto.select([
        {:field, "status", "status"},
        {:field, {:count, "*"}, "order_count"}
      ])
      |> Selecto.group_by(["status"])
    end,
    columns: %{status: %{type: :string}, order_count: %{type: :integer}},
    capability: "orders.analytics"
  }
}
```

Core validates shape and capability references. Components can disable or hide
published views in query contracts using host policy. Hosts still own creating,
refreshing, migrating, and authorizing actual database views.

## Writes

The `writes` section describes writable operations and field rules. Core keeps
the shape in the normalized domain; Updato validates and executes it.

```elixir
writes: %{
  operations: %{
    insert: %{enabled: true, returning: :record},
    update: %{enabled: true, require_filter: true, returning: :record}
  },
  fields: %{
    id: %{insertable: false, updatable: false, server_managed: true},
    status: %{insertable: true, updatable: true, required_on: [:insert]},
    customer_id: %{insertable: true, updatable: false, choice_source: :customer_choices},
    inserted_at: %{insertable: false, updatable: false, server_managed: true}
  },
  transitions: %{
    status: %{"pending" => ["approved", "cancelled"], "approved" => []}
  },
  scope: %{
    tenant: %{required: true, field: :tenant_id, sources: [:context, :actor]}
  }
}
```

Keep write metadata declarative. Runtime code should live in Updato adapters or
host application modules.

A query-enforced write may reuse a previously constructed Selecto query as an
atomic update/delete eligibility guard or an insert-candidate rule. That query
can only narrow the domain's write authority: it does not enable an operation,
grant a field, or replace canonical tenant scope. Root identity and unsupported
query expressions must fail closed at the write boundary.

## Domain Actions

Actions are named workflows over the write contract. They are not direct writes;
they are metadata that Components can render and Updato can plan.

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
    transition: %{field: :status, from: "pending", to: "approved"},
    execution: %{
      kind: :updato,
      operation: :update,
      set: %{status: "approved", approved_at: {:input, :approved_at}}
    }
  }
}
```

Action authoring rules:

- Use stable ids. Generated Components ids usually include the action id.
- Attach a capability when action use must be policy-controlled.
- Declare all user-editable values under `inputs`.
- Reference inputs from `execution` with `{:input, input_id}`.
- Use `variants` for discriminator-based forms and execution plans.
- Use `bulk: %{enabled: true}` only when the operation is safe for many targets.
- Keep confirmation/destructive metadata explicit for UI consumers.

## Query Contracts

`Selecto.Domain.project(domain, :query_contract)` produces the core read
projection. `selecto_components` wraps that projection as JSON-ready
`query_contract.json`, applies host capability policy, and validates generated
query intents.

The query contract is the correct handoff for:

- frontend/query builders
- portable named segments, projections, orderings, and views
- generated API clients
- exported view and scheduled export configuration
- published view discovery
- choice-source option and membership links

It is not the write contract. Use `selecto_updato` for write/action planning and
write intent validation.

## Versioning And Compatibility

- `schema_version` is the machine compatibility version for the domain schema.
- `domain_version` is optional human or generator metadata.
- `domain_fingerprint` is optional stable identity metadata.
- Changing field ids, action ids, capability ids, or choice source ids is a
  breaking change for clients.
- Additive changes are usually safe when capabilities default to allowed for
  hosts that do not provide a resolver.

## Review Checklist

Before shipping a domain contract:

- Domain normalization has no errors.
- Query-library references resolve, composition is acyclic, and required policy
  remains outside optional segment boolean groups.
- Component-facing policy uses documented values and malformed sensitive-state
  policy fails closed in the consuming package.
- Proposed sections are intentional: `writes`, `actions`, `capabilities`,
  `source_relationships`, `choice_sources`.
- Capability ids are declared and referenced consistently.
- Choice-source fields have membership validation in the host path.
- Published views have explicit capabilities when they reveal aggregate or
  operational data.
- Write operations that can affect multiple rows require filters or explicit
  target ids.
- Action variants have unambiguous discriminator conditions.
- Generated forms can render every declared input type.
- Updato can plan each action and reject invalid intents.
