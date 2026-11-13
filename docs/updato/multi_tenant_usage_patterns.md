# Multi-Tenant Usage Patterns for SelectoUpdato

## Purpose

Define tenant-safe write patterns for SelectoUpdato operations across shared
table, schema-prefix, and dedicated-database deployment models.

## Core Rule

Never allow tenant isolation to depend on client-controlled input alone.
Tenant scope must be applied by server-side operation construction.

## Tenant Models and Write Behavior

### 1) Shared Table (`tenant_id`)

- Include tenant filter in all update/delete operations.
- Include tenant fields in uniqueness and conflict targets for upserts.
- Validate bulk operations include explicit tenant scope before execution.

### 2) Schema-Per-Tenant

- Pass `prefix: tenant_schema` to execution options.
- Keep read-path and write-path prefix handling aligned across app layers.

### 3) Dedicated DB Per Tenant

- Resolve repo/connection by tenant before building operation pipelines.
- Ensure operation execution uses the same tenant-scoped repo used for reads.

## Recommended Pipeline Pattern

```elixir
SelectoUpdato.new(domain)
|> SelectoUpdato.filter({"tenant_id", tenant_id})
|> SelectoUpdato.filter({"id", id})
|> SelectoUpdato.update(attrs)
|> SelectoUpdato.execute(repo, prefix: tenant_prefix)
```

## Audit and Metadata

- Include tenant identifiers in audit metadata payloads.
- Keep audit logs sanitized (no sensitive tenant secrets).
- Preserve tenant context across nested writes and transaction boundaries.

## Safety Checklist

1. `dry_run/2` used in validation paths for user-driven writes.
2. Update/delete filters always include tenant scope.
3. `confirm_bulk_delete/2` enforced for wide delete operations.
4. Upsert conflict targets include tenant key in shared-table mode.
5. Transaction flows keep a single tenant context per transaction.

## Testing Checklist

- [ ] tenant A write cannot mutate tenant B rows.
- [ ] prefix mode writes only touch tenant schema.
- [ ] bulk safeguards fail closed without tenant scope.
- [ ] audit metadata includes tenant context.
