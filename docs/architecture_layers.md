# Architecture: module layers and naming conventions

Selecto separates "what you asked for" from "the SQL that answers it" across
three layers. Understanding this split explains the `Advanced` / `Builder`
module naming, which encodes the layer roles rather than difficulty levels.

## The three layers

```
Layer 1  Facades            Selecto (root) + per-feature facades
                            e.g. Selecto.CteQuery, Selecto.JsonQuery,
                                 Selecto.Window, Selecto.SetOperations
Layer 2  Intent/spec        Selecto.Advanced.*
                            Builds and validates spec structs.
                            Contains NO SQL generation.
Layer 3  SQL rendering      Selecto.Builder.*
                            Consumes Layer-2 specs, emits dialect fragments
                            through the Selecto.DB.Dialect behaviour.
```

Data flows strictly downward: a facade builds an `Advanced.*.Spec` struct
(validating it in the process), then hands the spec to a builder function,
which renders SQL via the configured dialect/adapter. Builders never accept
raw user input, and advanced modules never emit SQL.

Example, for CTEs:

1. `Selecto.with_cte/3` (`lib/selecto.ex`) — facade entry point.
2. `Selecto.Advanced.CTE.create_cte/validate_cte/validate_dependencies`
   (`lib/selecto/advanced/cte.ex`) — spec construction + validation.
3. `Selecto.Builder.CteSql.build_with_clause/2`
   (`lib/selecto/builder/cte.ex`) — renders the `WITH` clause; re-checks
   spec dependencies before emitting SQL.

The same pattern holds for array operations, CASE expressions, JSON
operations, lateral joins, VALUES clauses, window functions, set operations,
and subselects.

## Naming conventions

- `Selecto.<Feature>` — runtime helpers and small value types for a feature
  (`Selecto.Window`, `Selecto.SetOperations`).
- `Selecto.Advanced.<Feature>` — intent/spec/validation layer for complex
  features. If you are reading one of these modules, expect struct definitions
  and validators, not strings of SQL.
- `Selecto.Builder.<Feature>` or `Selecto.Builder.Sql.<Section>` — SQL
  renderers. These are the only places (besides adapter/dialect callbacks)
  where SQL text is assembled.
- Known deviation: the CTE facade is named `Selecto.CteQuery` rather than
  following the `Selecto.<Feature>` pattern used elsewhere. It is kept for
  API stability; new features should use the standard pattern.

## Dialect/adapter boundary

Builders do not talk to databases. They call typed fragment-render callbacks
defined by `Selecto.DB.Dialect` (struct vocabulary in `Selecto.Dialect.*`),
with connections abstracted behind `Selecto.DB.Adapter`. No database-specific
SQL may appear in the core builders; adapters live outside this library.

## Runtime processes

Only `Task.Supervisor` (execution timeouts) is started with the application.
`Selecto.ConnectionPool.Runtime` and `Selecto.Performance.QueryCache` start
lazily on first use and may instead be added to the host's supervision tree.
