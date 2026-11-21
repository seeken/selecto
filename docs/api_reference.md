# Selecto API Reference

Complete API documentation for Selecto's advanced query builder with comprehensive join support.

## Core Functions

## Expression Authoring

### `Selecto.Expr`

Composable helper module for building Selecto AST as plain Elixir data.

Typical uses:

- dynamic filter assembly
- reusable selector helpers
- runtime-built order/group/select fragments

Example:

```elixir
alias Selecto.Expr, as: X

Selecto.filter(selecto, X.compact_and([
  X.eq("status", "active"),
  X.when_present(search, &X.case_insensitive_like("customer.name", "%#{&1}%"))
]))
```

### `Selecto.ExprMacros`

Macro layer for authoring Selecto AST with Elixir syntax.

- `where/1` - filter DSL
- `select/1` - selector DSL
- `order_by/1` - order DSL

Example:

```elixir
import Selecto.ExprMacros

filters = where(status == ^status and case_insensitive_like(customer.name, ^pattern))
selectors = select([customer.name, count_distinct(customer.id)])
orders = order_by([desc_nulls_last(total), asc(customer.name)])
```

### `Selecto.Sigil`

Filter-only sigil DSL.

```elixir
import Selecto.Sigil

filters = ~SELECTO"total >= ^min_total and starts_with(customer.name, ^prefix)"
```

For the broader guide, examples, and current coverage snapshot, see
`docs/expression_dsl.md`.

### `Selecto.configure/2`

Configures a Selecto instance with domain configuration and connection input.

```elixir
configure(domain, connection) :: %Selecto{}
```

**Parameters:**
- `domain` - Domain configuration map containing source, schemas, and join definitions
- `connection` - Adapter-specific connection input, Ecto repo, live connection,
  or pooled connection reference

**Returns:** Configured Selecto struct ready for query building

**Example:**
```elixir
selecto = Selecto.configure(domain_config, db_connection)
```

### `Selecto.select/2`

Specifies fields to select in the query with automatic join resolution.

```elixir
select(selecto, fields) :: %Selecto{}
```

**Parameters:**
- `selecto` - Selecto struct
- `fields` - List of field specifications

**Field Types:**
- `"field_name"` - Simple field selection
- `"join.field"` - Field from joined table
- `"join.nested.field"` - Field from nested joins
- `{:func, "function_name", [args]}` - SQL function call
- `{:literal, value}` - Literal value
- `{:custom_sql, sql, field_map}` - Custom SQL with field validation
- `{:case, name, conditions}` - CASE expression
- `{:array, name, [fields]}` - Array aggregation

**Example:**
```elixir
selecto
|> Selecto.select([
  "id", 
  "customer.name",
  {:func, "count", ["*"]},
  {:case, "status", %{"active" => [{:literal, true}], "else" => [{:literal, false}]}}
])
```

### `Selecto.filter/2`

Applies WHERE conditions with automatic join dependency resolution.

```elixir
filter(selecto, conditions) :: %Selecto{}
```

**Parameters:**
- `selecto` - Selecto struct
- `conditions` - List of filter conditions

**Condition Types:**
- `{field, value}` - Equality comparison
- `{field, {:gt, value}}` - Greater than
- `{field, {:gte, value}}` - Greater than or equal
- `{field, {:lt, value}}` - Less than
- `{field, {:lte, value}}` - Less than or equal
- `{field, {:like, pattern}}` - LIKE pattern matching
- `{field, {:in, [values]}}` - IN list
- `{field, {:between, min, max}}` - BETWEEN range
- `{field, {:not_null}}` - NOT NULL check
- `{field, {:null}}` - NULL check
- `{:and, [conditions]}` - AND logical operator
- `{:or, [conditions]}` - OR logical operator
- `{field, {:subquery, :in, sql, params}}` - Subquery
- `{field, {:text_search, query}}` - Full text search (PostgreSQL)

**Example:**
```elixir
selecto
|> Selecto.filter([
  {"active", true},
  {:and, [
    {"total", {:gt, 100}},
    {:or, [
      {"customer.region", "West"},
      {"customer.type", "premium"}
    ]}
  ]},
  {"created_at", {:between, ~D[2024-01-01], ~D[2024-12-31]}}
])
```

### `Selecto.group_by/2`

Groups results by specified fields.

```elixir
group_by(selecto, fields) :: %Selecto{}
```

**Parameters:**
- `selecto` - Selecto struct
- `fields` - List of field names for grouping

**Example:**
```elixir
selecto
|> Selecto.group_by(["customer.region", "product.category"])
```

### `Selecto.order_by/2`

Orders results by specified fields with direction.

```elixir
order_by(selecto, fields) :: %Selecto{}
```

**Parameters:**
- `selecto` - Selecto struct  
- `fields` - List of field specifications with optional direction

**Field Types:**
- `"field_name"` - Ascending order (default)
- `{:desc, "field_name"}` - Descending order
- `{:asc, "field_name"}` - Explicit ascending order
- `{:desc, {:func, "sum", ["total"]}}` - Order by function result

**Example:**
```elixir
selecto
|> Selecto.order_by([
  "customer.name",
  {:desc, "created_at"},
  {:desc, {:func, "sum", ["total"]}}
])
```

### `Selecto.limit/2` and `Selecto.offset/2`

Pagination controls for result sets.

```elixir
limit(selecto, count) :: %Selecto{}
offset(selecto, count) :: %Selecto{}
```

**Example:**
```elixir
selecto
|> Selecto.limit(50)
|> Selecto.offset(100)  # Skip first 100, return next 50
```

### `Selecto.execute/1`

Executes the query and returns results.

```elixir
execute(selecto) :: {:ok, [row]} | {:error, term}
```

**Returns:** Query results as list of tuples/maps depending on configuration

## Join Configuration API

### Standard Join Types

#### Left Join
```elixir
joins: %{
  association_name: %{type: :left}
}
```

#### Inner Join  
```elixir
joins: %{
  association_name: %{type: :inner}
}
```

#### Right and Full Joins
```elixir
joins: %{
  association_name: %{type: :right}   # or :full
}
```

The target is read through a derived table that applies the association's
`where` and, for a tenant-paired target, the query tenant. Only a direct
association can be joined `right` or `full`.

### Star Dimension
For business intelligence and analytics queries.

```elixir
joins: %{
  dimension_name: %{
    type: :star_dimension,
    display_field: :name,           # default :name; must be a target field
    alias: "dim"                    # optional authored alias
  }
}
```

**Generated Fields:**
- `dimension_name_display` - Display field value
- `dimension_name_facet` - Facet filter over the display field

Further normalised dimension tables (a snowflake) are nested associations
joined under the dimension (`joins: %{dimension_name: %{type:
:star_dimension, joins: %{region: %{type: :left}}}}`). `dimension` and
`snowflake_dimension` are native aliases of `star_dimension`.

### Association Conditions
Owner/target field comparisons ANDed after the key equality in every join.

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

See [Join Families](join_families.md) for the rules.

### Hierarchical Join (Adjacency List, PostgreSQL only)

```elixir
joins: %{
  parent_category: %{
    type: :hierarchical,
    hierarchy_type: :adjacency_list,
    depth_limit: 5,                 # 1..10000, default 5
    parent_field: :parent_id        # default :parent_id; a target field
  }
}
```

**Generated Fields:**
- `parent_category_path` - Full path from root as string
- `parent_category_level` - Depth in hierarchy (0 = root)
- `parent_category_path_array` - Path as PostgreSQL array

Other adapters refuse it with `unsupported_feature`. The portable way to walk
a tree is a recursive query member (`query_members.ctes` with
`kind: :recursive`). The `materialized_path` and `closure_table` hierarchy
types were removed.

### Many-to-Many Tagging
A tagging join reads a `join_through` association; `join_keys` are required.

```elixir
associations: %{
  tags: %{
    queryable: :tags, field: :tags, cardinality: :many,
    join_through: "post_tags",
    join_keys: [{:post_id, :id}, {:tag_id, :id}],
    # bridge scope: all three keys or none
    source_scope_key: :tenant_id,
    through_scope_key: :tenant_id,
    target_scope_key: :tenant_id
  }
}

joins: %{
  tags: %{type: :tagging, tag_field: :name}
}
```

**Generated Fields:**
- `tags_list` - Comma-separated string of all tags
- `tags_filter` - Multi-select facet filter over the tag field

**Filtering:**
```elixir
# Filter by any tag
{"tags.name", "programming"}
```

## Common Table Expression (CTE) API

### `Selecto.Builder.CteSql`

Low-level SQL builder for validated CTE specs and raw CTE fragments.

#### `build_with_clause/1`
Builds a complete WITH clause from CTE entries.

```elixir
build_with_clause(ctes) :: {iodata, [params]}
```

Accepted entries:
- `%Selecto.Advanced.CTE.Spec{}`
- `{:raw_cte, cte_definition_iodata, params}`
- `{:raw_recursive_cte, cte_definition_iodata, params}`

#### `build_cte_definition/1`
Builds a single CTE definition from a validated `%Selecto.Advanced.CTE.Spec{}`.

```elixir
build_cte_definition(spec) :: {iodata, [params]}
```

#### `integrate_ctes_with_query/3`
Combines a WITH clause and a main query iodata payload.

```elixir
integrate_ctes_with_query(ctes, main_query, main_params) :: {iodata, [params]}
```

**Example:**
```elixir
alias Selecto.Advanced.CTE
alias Selecto.Builder.CteSql

active_users_spec =
  CTE.create_cte("active_users", fn ->
    Selecto.configure(user_domain, conn)
    |> Selecto.select(["id", "name"])
    |> Selecto.filter({"active", true})
  end)

{with_clause, with_params} = CteSql.build_with_clause([active_users_spec])

{query_iodata, params} =
  CteSql.integrate_ctes_with_query(
    [active_users_spec],
    ["SELECT * FROM active_users"],
    []
  )
```

Most users should prefer the high-level public APIs (`Selecto.with_cte/4`, `Selecto.with_recursive_cte/3`, and `Selecto.with_ctes/2`) over low-level CTE SQL assembly.

## Parameter Handling API

### `Selecto.SQL.Params`

Handles safe parameter substitution and SQL finalization.

#### `finalize/1`
Converts parameterized iodata to executable SQL with placeholders.

```elixir
finalize(iodata_with_params) :: {sql_string, [param_values]}
```

**Example:**
```elixir
# iodata with embedded {:param, value} markers
parameterized_query = ["SELECT * FROM users WHERE id = ", {:param, 123}]

{sql, params} = Selecto.SQL.Params.finalize(parameterized_query)
# Result: {"SELECT * FROM users WHERE id = $1", [123]}
```

## Domain Configuration Reference

### Complete Domain Structure
```elixir
domain = %{
  # Required: Domain identification
  name: "Domain Display Name",
  
  # Required: Primary source table configuration
  source: %{
    source_table: "primary_table_name",
    primary_key: :id,
    fields: [:id, :field1, :field2, :field3],
    redact_fields: [:sensitive_field],  # Optional: fields to exclude
    columns: %{
      id: %{type: :integer},
      field1: %{type: :string},
      field2: %{type: :decimal}, 
      field3: %{type: :utc_datetime}
    },
    associations: %{
      related_table: %{
        queryable: :schema_key,         # Key in schemas map
        field: :association_name,       # Field name for selection
        owner_key: :foreign_key_field,  # FK field in source table
        related_key: :id               # PK field in related table
      }
    }
  },
  
  # Required: Related table schema definitions
  schemas: %{
    schema_key: %{
      name: "Human Readable Name",
      source_table: "actual_table_name",
      fields: [:id, :name, :other_field],
      redact_fields: [],              # Optional
      columns: %{
        id: %{type: :integer},
        name: %{type: :string},
        other_field: %{type: :boolean}
      },
      associations: %{
        # Nested associations for chained joins
        nested_relation: %{
          queryable: :another_schema,
          field: :nested_field,
          owner_key: :nested_id,
          related_key: :id
        }
      }
    }
  },
  
  # Required: Join configuration
  joins: %{
    related_table: %{
      type: :left,                    # or :inner, :right, :star_dimension, etc.
      name: "Human Readable Name",    # Optional display name
      # Additional type-specific options...
    }
  },
  
  # Optional: Default query configuration
  default_selected: ["id", "name"],           # Always selected fields
  required_filters: [{"active", true}]       # Always applied filters
}
```

### Column Types
Supported column types for type validation and casting:

- `:integer` - Integer numbers
- `:decimal` - Decimal/numeric values  
- `:float` - Floating point numbers
- `:string` - Text/varchar fields
- `:text` - Long text fields
- `:boolean` - Boolean true/false
- `:date` - Date only
- `:time` - Time only  
- `:utc_datetime` - Timestamp with timezone
- `:naive_datetime` - Timestamp without timezone
- `:binary` - Binary data
- `:array` - PostgreSQL arrays
- `:map` - JSON/JSONB fields

## Error Handling

### Common Errors

#### Configuration Errors
- **Missing required keys**: Domain missing name, source, schemas, or joins
- **Invalid column types**: Unsupported column type specified
- **Missing schema references**: Join references non-existent schema
- **Circular dependencies**: Join configuration creates circular reference

#### Query Building Errors  
- **Invalid field reference**: Field doesn't exist in domain or schema
- **Unsupported join type**: Join type not implemented
- **Parameter type mismatch**: Parameter doesn't match expected column type
- **Depth limit exceeded**: Hierarchical query exceeds configured depth limit

#### Execution Errors
- **SQL syntax error**: Generated SQL is invalid
- **Database connection error**: Connection lost or invalid
- **Parameter binding error**: Parameter count mismatch or type conversion failure

### Error Examples
```elixir
# Configuration validation
case Selecto.configure(domain, conn) do
  {:ok, selecto} -> selecto
  {:error, "Missing required domain keys: [:joins]"} -> handle_config_error()
end

# Query execution  
case Selecto.execute(selecto) do
  {:ok, results} -> process_results(results)
  {:error, %Postgrex.Error{} = error} -> handle_db_error(error)
end
```

## Performance Considerations

### Query Optimization Tips

1. **Filter Early**: Apply most selective filters first
   ```elixir
   selecto
   |> Selecto.filter([
     {"date_range", {:between, start_date, end_date}},  # Selective date filter first
     {"status", "active"},                               # Then status
     {"customer.type", "premium"}                       # Finally join filters
   ])
   ```

2. **Limit Join Depth**: Avoid excessive nested joins
   ```elixir
   # Good: Limited nesting
   "customer.region.name"
   
   # Avoid: Deep nesting
   "order.customer.company.region.country.continent.name"
   ```

3. **Use Appropriate Join Types**: 
   - Use `star_dimension` for analytics/aggregation
   - Use `left` joins when related data may not exist
   - Use `inner` joins for required relationships

4. **Batch Large Queries**: Process large datasets in chunks
   ```elixir
   selecto
   |> Selecto.order_by(["id"])      # Consistent ordering
   |> Selecto.limit(1000)          # Process in batches
   |> Selecto.offset(batch * 1000)
   ```

5. **Index Support**: Ensure database indexes support your query patterns
   - Index foreign key fields used in joins
   - Index commonly filtered fields  
   - Consider composite indexes for multi-field filters

This API reference provides comprehensive documentation for all Selecto features with practical examples and configuration guidance.
