# Join Families

Every Selecto join reads one association of its parent relation. The join
type decides how the association's rows are attached; the association decides
what an attached row is. Whatever the type, the join's ON is the
association's own: the key equality, its `conditions`, its scope keys, the
tenant pair, a carried tenant and its `where`.

## Shared types

These are the types portable JSON domains accept (`Selecto.Domain.validate_json/1`)
and every Selecto runtime renders the same way.

| type | SQL |
|---|---|
| `left` (default) | `LEFT JOIN` |
| `inner` | `INNER JOIN` |
| `right` | `RIGHT JOIN` on a derived table of the target |
| `full` | `FULL JOIN` on a derived table of the target |
| `star_dimension` | `LEFT JOIN` plus a display column and a facet filter |

A `right` or `full` join keeps target rows no owner row matches, so the
target's bounds cannot live only in ON. The target is read through a derived
table that applies the association's `where` and, for a tenant-paired target,
binds the target's tenant field to the query's tenant:

```sql
right join (select * from prices price
            where price."published" = $1 and price."tenant_id" = $2) price
  on price.product_id = selecto_root.product_id and ...
```

Only a direct association (no `through`, no `values`) can be joined `right`
or `full`; the adapter must support the join.

A `star_dimension` adds `<id>_display` (the `display_field` value) and an
`<id>_facet` filter. `display_field` defaults to `:name` and must be a target
field; `dimension_key`, when given, must equal the association's owner key.
A star dimension takes an `alias` like any other join, and pairs tenants like
any other association.

```elixir
joins: %{
  customer: %{type: :star_dimension, display_field: :full_name, alias: "buyer"}
}
```

Type names are case-insensitive (as in Perl); an unknown type refuses with
`:unsupported_join_type` in `validate/1`, `validate_json/1` and
`Selecto.configure/3` (ArgumentError `invalid_domain: join ...`).

## Native sugar

Native (atom-map) domains accept a few more names. Each normalises onto a
shared type before planning:

- `dimension` is a `star_dimension` whose `dimension` key is its display
  field.
- `snowflake_dimension` is a `star_dimension`. Further normalised tables are
  nested associations joined under it, not a list on the join.
- `self_join` is an ordinary `left` association join (the association simply
  targets the same table).
- `full_outer_join` is `type: :full`.
- `tagging` reads a many-to-many association (below) and adds the
  `<id>_list` string-aggregate column and the `<id>_filter` facet over
  `tag_field` (default `:name`).
- `hierarchical` with `hierarchy_type: :adjacency_list` (below).

### Many-to-many: `join_through` and `join_keys`

A `join_through` association is a `through` contract. `join_keys` are
required: `[{bridge_owner_key, owner_key}, {bridge_related_key, related_key}]`.
The bridge is scoped like any `through` bridge: `source_scope_key`,
`through_scope_key` and `target_scope_key` (all three or none) pair the
bridge and the target with the owner, and `through_where` confines the
bridge rows. The association's `where` confines the target.

```elixir
associations: %{
  tags: %{
    queryable: :tags, field: :tags, cardinality: :many,
    join_through: "post_tags",
    join_keys: [{:post_id, :id}, {:tag_id, :id}],
    source_scope_key: :tenant_id, through_scope_key: :tenant_id,
    target_scope_key: :tenant_id,
    through_where: %{kind: "topic"},
    where: %{visible: true}
  }
}

joins: %{tags: %{type: :tagging, tag_field: :name}}
```

Ecto-style `through` lists (`through: [:customer, :region]`) expand into one
join per segment; an unknown or nested-through segment refuses.

### Adjacency-list hierarchy (PostgreSQL only)

```elixir
joins: %{
  manager: %{
    type: :hierarchical,
    hierarchy_type: :adjacency_list,
    parent_field: :manager_id,   # default :parent_id
    id_field: :id,               # default: the association's related_key
    depth_limit: 6               # 1..10000, default 5
  }
}
```

The target is joined through a recursive CTE that walks it from its roots
(rows whose `parent_field` is NULL) down at most `depth_limit` levels. The
CTE keeps every target column and adds `level`, `path` and `path_array`
(the join also exposes `<id>_level`, `<id>_path` and `<id>_path_array`).
`parent_field` and `id_field` must be target fields, and the target cannot
declare fields named `level`, `path` or `path_array`. The association's
`where` confines the anchor and every step, the step stays inside one tenant
when the target declares `tenant_field`, and the join's ON is the
association's. A `through`, `values` or `join_strategy` association refuses.

Only PostgreSQL renders it; every other adapter refuses with
`unsupported_feature` before any SQL is sent. The portable way to walk a
tree is a recursive query member (`query_members.ctes` with
`kind: :recursive`).

## Association `conditions`

`conditions` compare an owner field with a target field and are ANDed after
the key equality wherever the association is joined: every join type, nested
joins, subselect correlations and related collections.

```elixir
associations: %{
  price: %{
    queryable: :prices, field: :price,
    owner_key: :product_id, related_key: :product_id,
    conditions: [
      %{left: :ordered_on, op: :gte, right: :valid_from},
      %{left: :ordered_on, op: :lt, right: :valid_to, open: true}
    ]
  }
}
```

renders

```sql
left join prices price on price.product_id = selecto_root.product_id
  and selecto_root."ordered_on" >= price."valid_from"
  and (price."valid_to" IS NULL OR selecto_root."ordered_on" < price."valid_to")
  and selecto_root.tenant_id = price.tenant_id
```

Rules (violations refuse with `:invalid_join_conditions`):

- a non-empty list of at most 8 entries with exactly `left`, `op`, `right`
  and optionally `open`;
- `left` is a physical, unredacted field of the owner relation, `right` one
  of the target;
- `op` is `eq`, `ne`, `lt`, `lte`, `gt` or `gte`; both sides belong to one
  type family, and ordering operators take numbers, dates, times and
  date-times only;
- `open` (a boolean, or 0/1; ordering operators only) also matches a NULL
  right side;
- a `through` or `values` association refuses them; `owner_key` and
  `related_key` stay required.

Text `eq`/`ne` compare exactly (by bytes) on MySQL and MariaDB.
`Selecto.Domain.contract_json/1` exports each `open` as a JSON boolean. A
conditioned association, like one with a non-empty `where`, is a filtered
lookup: write-side foreign-key guards skip it.

## Removed

These join forms were removed; each refuses with `:unsupported_join_type`.

| removed | use instead |
|---|---|
| `cross_join` | an association join |
| the raw-SQL `lateral_join` join type | `query_members.laterals`, or the association `join_strategy: :lateral_lookup` |
| `conditional_join` (`custom_sql` join conditions) | association `conditions` |
| snowflake `normalization_joins` lists | nested associations under the star dimension |
| `hierarchy_type: :materialized_path` and `:closure_table` | a recursive query member |

The query-level `Selecto.lateral_join` API and `custom_sql` selectors are
unaffected.
