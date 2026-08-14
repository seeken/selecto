# Registered Database-Function Verification

Selecto treats database functions as governed domain contracts only when they
are registered under `domain[:functions]`. Registration lets Selecto answer
three different questions without confusing their evidence:

1. Is the declaration structurally valid?
2. Does this query call match one declared signature?
3. Does the connected database resolve that exact signature for the current
   adapter, role, database, schema/search path, and server version?

Controlled semantic fixtures are a fourth and separate layer. They can show
that specifically enumerated synthetic inputs produced expected results, but
they do not prove arbitrary function behavior.

## What is governed

A registered function has a stable Selecto ID and an explicit database SQL
name, kind, arguments, return declaration, and allowed call sites:

```elixir
functions: %{
  "similarity" => %{
    kind: :scalar,
    sql_name: "public.similarity",
    args: [
      %{name: :left, type: :string, source: :selector, null?: false},
      %{name: :right, type: :string, source: :value, null?: false}
    ],
    returns: :float,
    allowed_in: [:select, :order_by],
    database: %{
      adapters: [:postgresql],
      requires: [extension: "pg_trgm"],
      volatility: :stable,
      minimum_version: 14
    }
  }
}
```

Overlay-authored domains can express the same metadata:

```elixir
deffunction "similarity" do
  kind(:scalar)
  sql_name("public.similarity")
  returns(:float)
  allowed_in([:select, :order_by])

  database(%{
    adapters: [:postgresql],
    requires: [extension: "pg_trgm"],
    volatility: :stable,
    minimum_version: 14
  })

  arg(:left, :string, source: :selector, null?: false)
  arg(:right, :string, source: :value, null?: false)
end
```

`database` is optional. When present, only `adapters`, `requires`,
`volatility`, and `minimum_version` are copied into adapter verification
requests. Other domain metadata is not exposed to the adapter callback.

## Function kinds

### Scalar

A scalar function returns one declared Selecto type and may be used at its
declared selector/order/group call sites:

```elixir
%{
  kind: :scalar,
  sql_name: "lower",
  args: [%{name: :value, type: :string, source: :selector}],
  returns: :string,
  allowed_in: [:select, :order_by]
}
```

### Predicate

A predicate must declare `returns: :boolean` and is used as a filter:

```elixir
%{
  kind: :predicate,
  sql_name: "starts_with",
  args: [
    %{name: :value, type: :string, source: :selector},
    %{name: :prefix, type: :string, source: :value}
  ],
  returns: :boolean,
  allowed_in: [:filter]
}
```

### Table

A table function declares the columns Selecto makes available through its
lateral/query-member alias:

```elixir
%{
  kind: :table,
  sql_name: "public.expand_items",
  args: [%{name: :items, type: {:array, :string}, source: :value}],
  returns: %{
    columns: %{
      ordinal: %{type: :bigint},
      value: %{type: :string}
    }
  },
  allowed_in: [:lateral, :query_member]
}
```

The PostgreSQL verifier checks `RETURNS TABLE` output parameters and composite
return attributes by name and type. A declaration is not evidence that an
arbitrary table-function SQL shape is portable to another adapter.

## Overloads

Use `overloads` when one stable Selecto ID has multiple database signatures:

```elixir
"display_value" => %{
  kind: :scalar,
  sql_name: "public.display_value",
  allowed_in: [:select],
  overloads: [
    %{
      args: [%{name: :value, type: :string, source: :value}],
      returns: :string
    },
    %{
      args: [%{name: :value, type: :integer, source: :value}],
      returns: :integer
    }
  ]
}
```

Selecto scores exact and compatible inferred types, rejects known mismatches,
and rejects ties as `:ambiguous_overload`. It does not treat unknown inference
as connected database evidence.

## Evidence levels

| Level | Evidence | Boundary |
| --- | --- | --- |
| Static | Safe ID/name, valid kind, arguments, returns, overloads | Does not prove query use or database existence |
| Query | Call site, arity, sources, nullability, inferred type compatibility | Does not prove database overload resolution |
| Connected preflight | Current adapter/database resolves the signature and reports requirements | Does not execute the function or prove semantics |
| Controlled live fixture | Explicit synthetic cases execute after preflight | Applies only to enumerated fixtures and inputs |

`mix selecto.verify` supplies bounded finite-model evidence for other Selecto
invariants. It does not replace connected function verification.

## Verification modes

Verify one resolved query call with `Selecto.verify_function/4`:

```elixir
Selecto.verify_function(
  selecto,
  "similarity",
  ["name", {:param, "mountain"}],
  call_site: :select,
  mode: :strict
)
```

- `:off` returns `:unverified` without adapter dispatch.
- `:warn` returns finite evidence for success, failure, indeterminate state, or
  unsupported adapters.
- `:strict` succeeds only for `:database_resolved`.

The runtime values used for local overload selection are not copied into the
adapter request. The request contains declared argument metadata and a stable
signature fingerprint only.

## Registry-wide task

Expose a configured Selecto value from a provider module:

```elixir
defmodule MyApp.SelectoFunctionProvider do
  def selecto do
    Selecto.configure(MyApp.Domain.domain(), MyApp.Repo,
      adapter: SelectoDBPostgreSQL.Adapter
    )
  end
end
```

Then run:

```sh
mix selecto.functions.verify --domain MyApp.SelectoFunctionProvider

mix selecto.functions.verify \
  --domain MyApp.SelectoFunctionProvider \
  --strict \
  --output tmp/selecto-functions.json
```

The provider may alternatively export `domain/0` and `connection/0`, with
optional `configure_options/0` keyword options. The task:

- reports every function and overload in stable ID/index order;
- prints text evidence;
- writes timestamp-free deterministic JSON when `--output` is supplied;
- writes failure artifacts before raising in strict mode;
- includes the proof boundary in both formats.

## PostgreSQL connected checks

`selecto_db_postgresql` maps Selecto types to explicit PostgreSQL signature
types. Important defaults include:

| Selecto | PostgreSQL identity |
| --- | --- |
| `:string`, `:text` | `text` |
| `:decimal`, `:numeric` | `numeric` |
| `:float` | `double precision` |
| `:datetime`, `:naive_datetime`, `:timestamp` | `timestamp without time zone` |
| `:utc_datetime` | `timestamp with time zone` |
| `:map`, `:jsonb` | `jsonb` |
| `{:array, type}` | mapped element type plus `[]` |

The adapter binds an exact `to_regprocedure` identity, reads PostgreSQL catalog
metadata, checks current-role `EXECUTE`, requirements, return shape, server,
database, and search path, then parses/describes a typed unnamed statement and
immediately closes it. It never binds runtime values or executes the function
during connected preflight.

Unsupported Selecto types, unsupported connection shapes, malformed driver
results, and unexpected driver failures become `:indeterminate`; they are never
promoted to resolution evidence.

## Stable statuses

Connected reports use finite statuses:

- `:database_resolved`
- `:unsupported_adapter`
- `:missing_function`
- `:signature_mismatch`
- `:return_mismatch`
- `:permission_denied`
- `:missing_requirement`
- `:indeterminate`
- `:unverified`

Registry artifacts may additionally use `:static_invalid` when a malformed
entry cannot become a verification request.

## Built-ins, generic calls, and raw SQL

Selecto expression helpers for common database built-ins remain part of the
query-building API. Their presence in core proves that Selecto can construct
the supported AST/SQL shape; it does not prove that every adapter/server
version provides the function.

Generic `{:func, ...}` expressions are not registered function contracts. They
remain explicitly unregistered and unverified, including in strict-mode
documentation. Use `Selecto.udf/2` or `Selecto.udf_table/2` with a domain
registration when a function must participate in signature validation and
connected evidence.

Raw SQL remains outside the registered-function verifier and is governed by
the existing strict/domain SQL policy.

## What success does not mean

`:database_resolved` means the connected database resolved the declared
signature under the current context. It does not prove:

- semantic correctness for any input;
- absence of side effects;
- determinism or volatility claims beyond current catalog metadata;
- performance or planner behavior;
- concurrency behavior;
- callback, network, filesystem, or other external effects;
- behavior on another role, database, search path, server version, or adapter;
- future behavior after database migrations or extension changes.

Use controlled synthetic fixtures for representative behavior and report their
case list separately. Never convert bounded or representative evidence into an
arbitrary-function correctness claim.
