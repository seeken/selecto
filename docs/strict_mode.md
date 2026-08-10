# Strict mode

Strict mode is an opt-in governance boundary for Selecto query consumers. It
allows a trusted application to assemble a domain dynamically and then seals
that domain when the query is configured.

```elixir
selecto = Selecto.configure(domain, connection, mode: :strict)
```

The domain does not have to come from a module or DSL. Literal maps, generated
maps, introspection adapters, and overlay composition are all valid inputs. The
boundary begins after extensions have been merged and structural validation has
succeeded.

## Guarantees

For a strict query, Selecto:

- requires domain validation and rejects `validate: false`;
- records a deterministic seal for the composed domain and compiled base
  configuration;
- checks those seals again at SQL-compilation and execution boundaries;
- rejects `:raw_sql`, `:raw_sql_filter`, `:custom_sql`, and raw SQL subquery
  expressions supplied by the query caller;
- allows a domain join to be enabled but rejects source, key, condition, field,
  and join-type overrides;
- rejects joins that are absent from the domain;
- allows parameterized instances only for an existing domain join and only with
  its declared filter parameters;
- rejects direct CTE, LATERAL, VALUES, UNNEST, and subquery-join construction;
- allows those advanced sources through named `domain.query_members` without
  structural overrides; and
- rejects set operations and nested named-member queries that mix strict and
  permissive policies.

The policy is checked eagerly by public query APIs and again by the SQL builder.
The final check catches manually modified query state that bypasses the normal
functions.

## Domain-owned SQL

By default, `mode: :strict` uses `domain_sql: :declared`. Application-authored
SQL already present in the sealed domain—such as a compatibility custom
column—remains usable through its governed field name. Query consumers still
cannot provide SQL.

For environments where even trusted domain SQL is prohibited:

```elixir
Selecto.configure(domain, connection,
  mode: :strict,
  domain_sql: :forbid
)
```

That profile rejects explicit SQL-bearing domain entries such as SQL custom
columns and raw join conditions during configuration.

## What strict mode is not

Strict mode is an application-level correctness and governance control. Code
running in the same BEAM can call a database adapter directly or deliberately
forge data structures, so strict mode is not a process sandbox. Use a
least-privilege database role, tenant scoping, and database row-level security
where the threat model requires them.
