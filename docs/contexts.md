# Building Phoenix Contexts With Selecto

`Selecto.Context` removes common boundary plumbing when a Phoenix context uses
Selecto for reads and Selecto Updato for writes. It does not depend on Phoenix
or Ecto, and it does not infer authorization from a caller scope.

## Read records as maps

Build the query normally, then ask the context helper for all records or
exactly one record:

```elixir
def list_projects(current_scope, opts \\ []) do
  project_selecto(current_scope)
  |> Selecto.select(~w(id name code status))
  |> Selecto.filter({"status", Keyword.get(opts, :status, "active")})
  |> Selecto.Context.all()
end

def get_project(current_scope, id) do
  project_selecto(current_scope)
  |> Selecto.select(~w(id name code status))
  |> Selecto.filter({"id", id})
  |> Selecto.limit(1)
  |> Selecto.Context.one()
end
```

`all/2` and `one/2` return maps with existing atom keys by default. Unknown
column names remain strings; Selecto never creates atoms from result data.
Pass `keys: :strings` when string-keyed maps are preferred.

`one/2` returns `{:error, :not_found}` for no rows and
`{:error, :multiple_results}` for more than one row.

## Normalize governed input

Use an explicit atom allowlist for controller or LiveView parameters:

```elixir
attrs = Selecto.Context.take_attrs(params, [:name, :code, :status, :priority])
```

String and atom keys are accepted. Unknown fields are ignored, and no dynamic
atoms are created. If both key forms are present, the atom-keyed value wins.
The domain's `writes` contract remains the authoritative write policy; this
helper only narrows and normalizes the application boundary.

## Return one written record

When an insert, update, or delete operation declares a compatible `returning`
policy, the tagged Updato result can flow directly into `write_one/2`:

```elixir
domain()
|> SelectoUpdato.new()
|> SelectoUpdato.filter({:id, id})
|> SelectoUpdato.update(attrs)
|> SelectoUpdato.returning([:id, :name, :code, :status])
|> SelectoUpdato.execute(write_selecto(current_scope))
|> Selecto.Context.write_one()
```

`write_one/2` preserves write errors and returns clear errors when the result
contains zero or multiple returned records.

## Nested associations remain domain-owned

Context helpers do not invent association behavior. Declare owned nested
relationships in the domain and let the context normalize the nested input
before passing it to Selecto Updato. For a `has_many` child set, relationship
policy can require `strategy: :sync`, stable `identity_fields`, generated
foreign keys, and `delete_missing` behavior.

For the read side, a context can combine `Selecto.subselect/3` with
`Selecto.Context.one/2` to return a parent and its child collection from one
correlated JSON query. The context remains responsible for presenting that
nested value in its application-facing record shape.

## Authorization boundary

Keep the Phoenix caller scope as the first context argument. The application
must translate that scope into governed Selecto filters and Updato execution
context; `Selecto.Context` intentionally cannot guess tenant, ownership, or
capability policy.
