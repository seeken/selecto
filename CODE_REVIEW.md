# Selecto Code Review Document

Generated: 2026-01-16

## Summary Statistics
- Total files: 92
- Total public functions: ~350+
- Core library size: ~25,000 lines of Elixir code

## Architecture Overview

Selecto is a dynamic SQL query builder for Elixir that provides a domain-driven approach to constructing complex SQL queries. The architecture is organized into several key layers:

1. **Core Layer** - Main entry point and configuration
2. **Builder Layer** - SQL generation for different clauses
3. **Schema Layer** - Domain/schema definitions
4. **Advanced Layer** - Complex SQL features (JSON, arrays, CTEs)
5. **Output Layer** - Result transformation
6. **Performance Layer** - Caching and optimization
7. **Database Layer** - Multi-database support

## File Reference Map

### Most Referenced Modules (by alias/import count)

| Module | Reference Count | Description |
|--------|-----------------|-------------|
| Selecto.Builder.Sql | 7+ | Main SQL builder |
| Selecto.Builder.Sql.Select | 5+ | SELECT clause generation |
| Selecto.Builder.Sql.Helpers | 3+ | SQL safety utilities |
| Selecto.Builder.Sql.Where | 3+ | WHERE clause generation |
| Selecto (main) | 60+ | Core module entry point |

---

## Files

### Core Layer

---

### lib/selecto.ex
**References:** Most referenced module in the codebase (60+ references)
**Purpose:** Main entry point for the Selecto query builder. Defines the `%Selecto{}` struct and provides the primary public API for building and executing queries.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| configure | 2 | Initialize Selecto with domain and connection options |
| select | 2 | Add SELECT fields to the query |
| filter | 2 | Add WHERE conditions |
| order_by | 2 | Add ORDER BY clauses |
| group_by | 2 | Add GROUP BY clauses |
| limit | 2 | Set LIMIT value |
| offset | 2 | Set OFFSET value |
| join | 3 | Add a JOIN to the query |
| distinct | 1-2 | Enable DISTINCT selection |
| having | 2 | Add HAVING clause |
| field | 2 | Get field configuration by name |
| execute | 1-2 | Execute the query and return results |
| to_sql | 1 | Generate SQL string without executing |
| to_sql_tuple | 1 | Generate SQL with parameters |
| paginate | 2 | Add pagination (limit/offset) |
| rollup | 2 | Add ROLLUP for OLAP queries |
| cube | 2 | Add CUBE for OLAP queries |
| with_cte | 3 | Add Common Table Expression |
| lateral_join | 3 | Add LATERAL JOIN |
| subselect | 3 | Add subquery to SELECT |
| pivot | 3 | Configure pivot/crosstab query |
| window | 3 | Add window function |
| set_operation | 3 | Add UNION/INTERSECT/EXCEPT |

**Review Notes:**
- Well-structured main API with clear function naming
- Good separation between query building and execution
- Consider documenting the struct fields for external users

---

### lib/selecto/configuration.ex
**References:** 2 files reference this module
**Purpose:** Handles initialization and configuration of Selecto instances from domain definitions.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| configure | 2 | Main configuration function - builds Selecto struct from domain |
| build_config | 1 | Build internal configuration from domain map |
| validate_domain | 1 | Validate domain structure |

**Review Notes:**
- Configuration parsing is centralized here
- Domain validation could be more comprehensive

---

### lib/selecto/query.ex
**References:** 1 file references this module
**Purpose:** Query building and manipulation helpers. Handles the accumulation of query parts.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| add_select | 2 | Add fields to SELECT list |
| add_filter | 2 | Add filter conditions |
| add_order_by | 2 | Add ordering |
| add_group_by | 2 | Add grouping |
| add_join | 3 | Register a join |
| set_limit | 2 | Set result limit |
| set_offset | 2 | Set result offset |
| add_having | 2 | Add HAVING condition |
| add_distinct | 2 | Add DISTINCT clause |

**Review Notes:**
- Clean accumulator pattern for query building
- Good immutability - returns new structs

---

### lib/selecto/executor.ex
**References:** 1 file references this module
**Purpose:** Executes built queries against the database using Postgrex.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| execute | 1-2 | Execute query and return results |
| execute! | 1-2 | Execute query, raise on error |
| to_sql | 1 | Convert Selecto to SQL string |
| to_sql_tuple | 1 | Convert to {sql, params} tuple |

**Review Notes:**
- Good error handling with execute/execute! pattern
- Integration with Postgrex is clean

---

### lib/selecto/schema.ex
**References:** 1 file references this module
**Purpose:** Schema/domain definition and validation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| from_module | 1 | Build schema from Ecto module |
| validate | 1 | Validate schema structure |
| merge | 2 | Merge two schemas |

**Review Notes:**
- Good integration with Ecto schemas
- Schema merging is useful for composition

---

### lib/selecto/fields.ex
**References:** 1 file references this module
**Purpose:** Field definition and lookup utilities.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| get_field | 2 | Get field config by name |
| list_fields | 1 | List all available fields |
| resolve_field | 2 | Resolve field reference to config |

**Review Notes:**
- Central field resolution logic
- Good error messages for missing fields

---

### lib/selecto/helpers.ex
**References:** 0 files reference this module
**Purpose:** General utility functions for the library.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| ensure_list | 1 | Wrap value in list if not already |
| deep_merge | 2 | Deep merge two maps |

**Review Notes:**
- Minimal helper module
- Could be expanded or consolidated

---

### lib/selecto/error.ex
**References:** 0 files reference this module
**Purpose:** Custom error definitions for Selecto.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| exception | 1 | Create error exception |

**Review Notes:**
- Defines SelectoError exception
- Good practice for custom errors

---

### lib/selecto/types.ex
**References:** 1 file references this module
**Purpose:** Type definitions and type handling utilities.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| to_sql_type | 1 | Convert Elixir type to SQL type |
| cast | 2 | Cast value to specified type |
| supported_types | 0 | List supported data types |

**Review Notes:**
- Good type abstraction
- Supports PostgreSQL types well

---

## Builder Layer

---

### lib/selecto/builder/sql.ex
**References:** 7+ files reference this module
**Purpose:** Main SQL generation orchestrator. Coordinates all SQL clause builders to produce final SQL.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 2 | Build complete SQL from Selecto struct |
| build_with_params | 2 | Build SQL with parameter binding |

**Review Notes:**
- Central coordination point for SQL generation
- Good separation of concerns with clause-specific modules

---

### lib/selecto/builder/sql/select.ex
**References:** 5+ files reference this module
**Purpose:** SELECT clause SQL generation. Handles field selection, aggregates, functions, and expressions.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| prep_selector | 2-3 | Prepare selector for SQL generation |
| build | 2-4 | Build SELECT clause iodata |

**Key Selector Types Supported:**
- Plain fields: `"field_name"`
- Literals: `{:literal, value}`
- Functions: `{:func, field}`, `{:func, field, filter}`
- Aggregates: `{:count}`, `{:sum, field}`, `{:avg, field}`
- CASE: `{:case, pairs, else_clause}`
- Custom SQL: `{:custom_sql, template, mappings}`
- Array functions: `{:array_agg, field}`, `{:unnest, field}`

**Review Notes:**
- Very comprehensive selector support
- Could benefit from better documentation of all selector types
- Good iodata usage for performance

---

### lib/selecto/builder/sql/where.ex
**References:** 3+ files reference this module
**Purpose:** WHERE clause SQL generation. Handles filter conditions and predicates.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 2 | Build WHERE clause from filters |

**Predicate Types Supported:**
- Simple equality: `{field, value}`
- Comparisons: `{field, {:gt, value}}`, `{field, {:lt, value}}`
- NULL checks: `{field, nil}`, `{field, :not_null}`
- IN lists: `{field, [values]}`
- BETWEEN: `{field, {:between, min, max}}`
- LIKE/ILIKE: `{field, {:like, pattern}}`
- Subqueries: `{field, {:subquery, :in, query}}`
- Array ops: `{:array_contains, field, values}`
- Logical: `{:and, [filters]}`, `{:or, [filters]}`, `{:not, filter}`

**Review Notes:**
- Comprehensive predicate support
- Good SQL injection protection
- Consider adding more documentation for filter syntax

---

### lib/selecto/builder/sql/group.ex
**References:** 1 file references this module
**Purpose:** GROUP BY clause SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 1 | Build GROUP BY clause |
| group | 2 | Process group by specifications |

**Review Notes:**
- Supports ROLLUP syntax
- Clean implementation

---

### lib/selecto/builder/sql/order.ex
**References:** 2 files reference this module
**Purpose:** ORDER BY clause SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 1 | Build ORDER BY clause |
| order | 2 | Process individual order specification |

**Direction Options:**
- `:asc`, `:desc`
- `:asc_nulls_first`, `:asc_nulls_last`
- `:desc_nulls_first`, `:desc_nulls_last`

**Review Notes:**
- Good null handling options
- Supports CASE expressions in ORDER BY

---

### lib/selecto/builder/sql/helpers.ex
**References:** 3+ files reference this module
**Purpose:** SQL safety and formatting helpers. Prevents SQL injection through identifier validation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| check_string | 1 | Validate string for SQL safety |
| double_wrap | 1 | Quote identifier with double quotes |
| single_wrap | 1 | Quote value with single quotes |
| needs_quoting? | 1 | Check if identifier needs quoting |
| maybe_quote_identifier | 1 | Conditionally quote identifier |
| quote_identifier | 2 | Quote identifier with adapter-specific quotes |
| build_selector_string | 3 | Build table.column reference |
| build_join_string | 2 | Build join alias reference |
| get_quote_char | 1 | Get quote character for adapter |

**Review Notes:**
- Critical for SQL injection prevention
- Good adapter-awareness for quote characters
- Reserved word list could be more comprehensive

---

### lib/selecto/builder/sql/hierarchy.ex
**References:** 1 file references this module
**Purpose:** Hierarchical SQL patterns for self-referencing relationships (trees, graphs).

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build_hierarchy_join_with_cte | 7 | Build hierarchical join with CTE |
| build_adjacency_list_cte | 3 | Build recursive CTE for adjacency list |
| build_materialized_path_query | 3 | Build materialized path query |
| build_closure_table_query | 3 | Build closure table query |
| hierarchy_cte_name | 1 | Generate CTE name for hierarchy |

**Supported Patterns:**
- Adjacency List (parent_id)
- Materialized Path (path column)
- Closure Table (separate relationship table)

**Review Notes:**
- Good support for common hierarchy patterns
- Recursive CTE generation is well-implemented
- Phase 2 documentation indicates ongoing development

---

### lib/selecto/builder/join.ex
**References:** 1 file references this module
**Purpose:** JOIN clause SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 3 | Build JOIN clauses |
| process_join | 4 | Process individual join specification |

**Review Notes:**
- Supports LEFT, RIGHT, INNER, FULL joins
- Good integration with hierarchy joins

---

### lib/selecto/builder/cte.ex
**References:** 2 files reference this module
**Purpose:** Common Table Expression (CTE) SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 2 | Build WITH clause for CTEs |
| build_cte | 3 | Build individual CTE |
| build_recursive_cte | 4 | Build recursive CTE |

**Review Notes:**
- Good support for both simple and recursive CTEs
- Integration with hierarchy module

---

### lib/selecto/builder/pivot.ex
**References:** 1 file references this module
**Purpose:** Pivot/crosstab query SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build_pivot | 2 | Build pivot query transformation |
| generate_pivot_columns | 3 | Generate pivot column specifications |

**Review Notes:**
- Enables dynamic pivot tables
- Good for reporting use cases

---

### lib/selecto/builder/window.ex
**References:** 1 file references this module
**Purpose:** Window function SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 2 | Build window function clause |
| build_over_clause | 2 | Build OVER clause with PARTITION BY and ORDER BY |

**Review Notes:**
- Good window function support
- Integrates with main SELECT builder

---

### lib/selecto/builder/subselect.ex
**References:** 2 files reference this module
**Purpose:** Subquery SQL generation for SELECT clause.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 3 | Build subquery for SELECT |

**Review Notes:**
- Enables correlated subqueries
- Good parameter handling

---

### lib/selecto/builder/set_operations.ex
**References:** 1 file references this module
**Purpose:** Set operation SQL generation (UNION, INTERSECT, EXCEPT).

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build_set_operations | 1 | Build set operation SQL |
| has_set_operations? | 1 | Check if query has set operations |
| validate_set_operations_for_sql | 1 | Validate set operations |

**Review Notes:**
- Supports UNION ALL, INTERSECT ALL, EXCEPT ALL
- Good chaining support for multiple operations

---

### lib/selecto/builder/lateral_join.ex
**References:** 2 files reference this module
**Purpose:** LATERAL JOIN SQL generation for correlated subqueries.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build_lateral_joins | 1 | Build LATERAL JOIN clauses |
| build_lateral_join | 1 | Build single LATERAL JOIN |
| integrate_lateral_joins_sql | 2 | Integrate into main SQL |

**Review Notes:**
- PostgreSQL-specific LATERAL support
- Good for "top N per group" patterns

---

### lib/selecto/builder/json_operations.ex
**References:** 1 file references this module
**Purpose:** PostgreSQL JSON/JSONB operation SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build_json_select | 1 | Build JSON operation for SELECT |
| build_json_filter | 1 | Build JSON operation for WHERE |
| build_json_operations | 1 | Build multiple JSON operations |

**Supported Operations:**
- Extraction: `->`, `->>`, `json_extract_path`
- Aggregation: `json_agg`, `jsonb_object_agg`
- Construction: `json_build_object`, `json_build_array`
- Testing: `@>`, `?`, `jsonb_path_exists`

**Review Notes:**
- Comprehensive JSON support
- Good for document-style data

---

### lib/selecto/builder/values_clause.ex
**References:** 1 file references this module
**Purpose:** VALUES clause SQL generation for inline tables.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build_values_clause | 1 | Build VALUES clause |
| build_values_cte | 1 | Build VALUES as CTE |
| build_values_clause_with_params | 1 | Build with parameter binding |

**Review Notes:**
- Useful for lookup tables
- Good type handling

---

### lib/selecto/builder/array_operations.ex
**References:** 1 file references this module
**Purpose:** PostgreSQL array operation SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build_array_sql | 3 | Build array operation SQL |

**Review Notes:**
- Integrates with Advanced.ArrayOperations
- Good for array column handling

---

### lib/selecto/builder/case_expression.ex
**References:** 2 files reference this module
**Purpose:** CASE expression SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build_case_for_select | 2 | Build CASE for SELECT clause |
| build_case_for_where | 2 | Build CASE for WHERE clause |

**Review Notes:**
- Good CASE expression support
- Used by both SELECT and WHERE builders

---

## Schema Layer

---

### lib/selecto/schema/column.ex
**References:** 1 file references this module
**Purpose:** Column definition structures and validation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| new | 1-2 | Create column definition |
| validate | 1 | Validate column spec |

**Review Notes:**
- Clean column definition API
- Good default handling

---

### lib/selecto/schema/join.ex
**References:** 1 file references this module
**Purpose:** Join definition structures.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| new | 1 | Create join definition |
| validate | 1 | Validate join spec |

**Review Notes:**
- Supports various join types
- Good field inheritance from joined tables

---

### lib/selecto/schema/filter.ex
**References:** 1 file references this module
**Purpose:** Filter definition structures.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| new | 1 | Create filter definition |
| validate | 1 | Validate filter spec |

**Review Notes:**
- Pre-defined filter support
- Good for common query patterns

---

### lib/selecto/schema/parameterized_join.ex
**References:** 1 file references this module
**Purpose:** Parameterized join support for dynamic join conditions.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| new | 1 | Create parameterized join |
| resolve | 2 | Resolve parameters for join |

**Review Notes:**
- Enables runtime join customization
- Good for multi-tenant scenarios

---

## Advanced Layer

---

### lib/selecto/advanced/lateral_join.ex
**References:** 2 files reference this module
**Purpose:** LATERAL join specification and validation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| create_lateral_join | 3-4 | Create LATERAL join spec |
| validate_correlations | 2 | Validate correlation references |

**Spec Struct Fields:**
- `id` - Unique identifier
- `join_type` - :left, :inner, :right, :full
- `subquery_builder` - Function to build correlated subquery
- `table_function` - Alternative: UNNEST, etc.
- `alias` - Result alias
- `correlation_refs` - Parent table references
- `validated` - Validation status

**Review Notes:**
- Good correlation validation
- Clean spec-based approach

---

### lib/selecto/advanced/json_operations.ex
**References:** 1 file references this module
**Purpose:** JSON operation specification and validation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| create_json_operation | 2-3 | Create JSON operation spec |
| validate_json_operation | 1 | Validate JSON spec |
| select_operation? | 1 | Check if suitable for SELECT |
| filter_operation? | 1 | Check if suitable for WHERE |

**Supported Operations:**
- Extraction: `json_extract`, `json_extract_text`, `json_extract_path`
- Testing: `json_contains`, `json_exists`, `json_path_exists`
- Aggregation: `json_agg`, `json_object_agg`, `jsonb_agg`
- Construction: `json_build_object`, `json_build_array`
- Manipulation: `json_set`, `jsonb_insert`
- Type: `json_typeof`, `json_array_length`

**Review Notes:**
- Comprehensive JSON support
- Good path validation

---

### lib/selecto/advanced/values_clause.ex
**References:** 1 file references this module
**Purpose:** VALUES clause specification and validation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| create_values_clause | 1-2 | Create VALUES spec |
| validate_and_process_data | 2 | Validate and infer column info |

**Data Formats:**
- List of lists: `[[1, "a"], [2, "b"]]`
- List of maps: `[%{id: 1, name: "a"}, %{id: 2, name: "b"}]`

**Review Notes:**
- Good data validation
- Automatic column type inference

---

### lib/selecto/advanced/array_operations.ex
**References:** 1 file references this module
**Purpose:** Array operation specification and validation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| create_array_operation | 2-3 | Create array aggregation spec |
| create_array_filter | 3 | Create array filter spec |
| create_array_size | 3-4 | Create array size spec |
| create_unnest | 1-2 | Create UNNEST spec |
| validate_array_operation! | 1 | Validate array spec |
| to_sql | 2-3 | Generate SQL |
| is_aggregate? | 1 | Check if aggregation |
| is_filter? | 1 | Check if filter |
| is_unnest? | 1 | Check if unnest |

**Supported Operations:**
- Aggregation: `array_agg`, `string_agg`
- Testing: `array_contains`, `array_overlap`
- Size: `array_length`, `cardinality`
- Construction: `array_fill`, `array_append`, `array_cat`
- Transformation: `unnest`, `array_to_string`

**Review Notes:**
- Comprehensive PostgreSQL array support
- Good validation with helpful errors

---

### lib/selecto/advanced/cte.ex
**References:** 1 file references this module
**Purpose:** CTE specification structures.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| new | 1 | Create CTE spec |
| validate | 1 | Validate CTE spec |

**Review Notes:**
- Clean CTE definition structure
- Supports recursive CTEs

---

### lib/selecto/advanced/case_expression.ex
**References:** 1 file references this module
**Purpose:** CASE expression specification.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| new | 1 | Create CASE spec |
| validate | 1 | Validate CASE spec |

**Review Notes:**
- Structured CASE expression support
- Good for complex conditionals

---

## SQL Functions

---

### lib/selecto/sql/functions.ex
**References:** 1 file references this module
**Purpose:** Advanced SQL function support extending basic selectors.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| prep_advanced_selector | 2 | Process advanced SQL functions |

**Function Categories:**
- **String**: `substr`, `trim`, `upper`, `lower`, `length`, `position`, `replace`, `split_part`
- **Math**: `abs`, `ceil`, `floor`, `round`, `power`, `sqrt`, `mod`, `random`
- **Date/Time**: `now`, `date_trunc`, `interval`, `age`, `date_part`
- **Array**: `array_agg`, `array_length`, `array_to_string`, `unnest`, `array_cat`
- **Window**: `row_number`, `rank`, `dense_rank`, `lag`, `lead`, `first_value`, `last_value`, `ntile`
- **Conditional**: `decode`, `iif`

**Review Notes:**
- Comprehensive function library
- Good integration with main prep_selector
- Window functions well-supported

---

### lib/selecto/sql/params.ex
**References:** 1 file references this module
**Purpose:** SQL parameter handling and binding.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| bind_params | 2 | Bind parameters to SQL |
| extract_params | 1 | Extract parameter values |

**Review Notes:**
- Clean parameter handling
- Good SQL injection prevention

---

## Subfilter Layer

---

### lib/selecto/subfilter.ex
**References:** 1 file references this module
**Purpose:** Main subfilter/subquery support.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| parse | 2 | Parse subfilter specification |
| validate | 2 | Validate subfilter |
| to_sql | 2 | Generate subfilter SQL |

**Review Notes:**
- Entry point for complex subquery filters
- Good delegation to specialized builders

---

### lib/selecto/subfilter/parser.ex
**References:** 2 files reference this module
**Purpose:** Parse subfilter specifications.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| parse | 2 | Parse subfilter spec |

**Review Notes:**
- Clean parsing logic
- Good error messages

---

### lib/selecto/subfilter/registry.ex
**References:** 2 files reference this module
**Purpose:** Registry for subfilter types.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| register | 2 | Register subfilter type |
| lookup | 1 | Look up subfilter handler |

**Review Notes:**
- Extensible registry pattern
- Good for custom subfilter types

---

### lib/selecto/subfilter/sql.ex
**References:** 3 files reference this module
**Purpose:** Main SQL generation for subfilters.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 3 | Build subfilter SQL |

**Review Notes:**
- Coordinates specialized builders
- Good abstraction layer

---

### lib/selecto/subfilter/sql/in_builder.ex
**References:** 2 files reference this module
**Purpose:** IN subquery SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 3 | Build IN subquery |

**Review Notes:**
- Clean IN clause generation
- Good parameter handling

---

### lib/selecto/subfilter/sql/exists_builder.ex
**References:** 2 files reference this module
**Purpose:** EXISTS subquery SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 3 | Build EXISTS subquery |

**Review Notes:**
- EXISTS clause support
- Good for existence checks

---

### lib/selecto/subfilter/sql/any_all_builder.ex
**References:** 2 files reference this module
**Purpose:** ANY/ALL subquery SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 3 | Build ANY/ALL subquery |

**Review Notes:**
- Supports ANY and ALL quantifiers
- Good for set comparisons

---

### lib/selecto/subfilter/sql/aggregation_builder.ex
**References:** 2 files reference this module
**Purpose:** Aggregation subquery SQL generation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 3 | Build aggregation subquery |

**Review Notes:**
- Supports subqueries with aggregates
- Good for comparison with aggregate results

---

### lib/selecto/subfilter/join_path_resolver.ex
**References:** 1 file references this module
**Purpose:** Resolve join paths for subfilters.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| resolve | 2 | Resolve join path |

**Review Notes:**
- Handles nested join resolution
- Good for multi-hop relationships

---

## Output Layer

---

### lib/selecto/output/formats.ex
**References:** 1 file references this module
**Purpose:** Output format definitions and coordination.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| format | 2-3 | Format results to specified format |
| available_formats | 0 | List available formats |

**Review Notes:**
- Central output formatting
- Delegates to transformers

---

### lib/selecto/output/type_coercion.ex
**References:** 1 file references this module
**Purpose:** Type coercion for output values.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| coerce | 2 | Coerce value to type |
| coerce_row | 2 | Coerce all values in row |

**Review Notes:**
- Handles PostgreSQL to Elixir type conversion
- Good null handling

---

### lib/selecto/output/transformers/maps.ex
**References:** 1 file references this module
**Purpose:** Transform results to maps.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| transform | 2 | Transform to list of maps |

**Review Notes:**
- Default output format
- Clean implementation

---

### lib/selecto/output/transformers/structs.ex
**References:** 2 files reference this module
**Purpose:** Transform results to Elixir structs.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| transform | 3 | Transform to structs |

**Review Notes:**
- Good for typed results
- Validates struct fields

---

### lib/selecto/output/transformers/json.ex
**References:** 2 files reference this module
**Purpose:** Transform results to JSON.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| transform | 2 | Transform to JSON string |

**Review Notes:**
- Uses Jason for encoding
- Good for API responses

---

### lib/selecto/output/transformers/csv.ex
**References:** 2 files reference this module
**Purpose:** Transform results to CSV.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| transform | 2 | Transform to CSV string |

**Review Notes:**
- Good for export functionality
- Handles escaping properly

---

### lib/selecto/output/transformers/stream.ex
**References:** 1 file references this module
**Purpose:** Stream results for large datasets.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| transform | 2 | Transform to stream |

**Review Notes:**
- Memory-efficient for large results
- Good Elixir stream integration

---

## Performance Layer

---

### lib/selecto/performance/hooks.ex
**References:** 3 files reference this module
**Purpose:** Performance hook management.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| register_hook | 2 | Register performance hook |
| execute_hooks | 3 | Execute registered hooks |

**Review Notes:**
- Extensible hook system
- Good for monitoring

---

### lib/selecto/performance/hook_behaviour.ex
**References:** 1 file references this module
**Purpose:** Behaviour definition for performance hooks.

#### Callbacks
| Callback | Arity | Description |
|----------|-------|-------------|
| before_query | 2 | Called before query execution |
| after_query | 3 | Called after query execution |

**Review Notes:**
- Clean behaviour definition
- Good for custom implementations

---

### lib/selecto/performance/query_cache.ex
**References:** 1 file references this module
**Purpose:** Query result caching.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| get | 1 | Get cached result |
| put | 2 | Cache result |
| invalidate | 1 | Invalidate cache entry |

**Review Notes:**
- Simple caching mechanism
- Could use ETS for production

---

### lib/selecto/performance/optimizer.ex
**References:** 1 file references this module
**Purpose:** Query optimization hints.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| optimize | 1 | Suggest optimizations |
| analyze | 1 | Analyze query complexity |

**Review Notes:**
- Query optimization suggestions
- Good for development insights

---

### lib/selecto/performance/query_analyzer.ex
**References:** 1 file references this module
**Purpose:** Detailed query analysis.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| analyze | 1 | Analyze query structure |
| explain | 1 | Get query execution plan |

**Review Notes:**
- Good for debugging
- EXPLAIN integration

---

### lib/selecto/performance/complexity_analyzer.ex
**References:** 1 file references this module
**Purpose:** Query complexity estimation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| estimate_complexity | 1 | Estimate query complexity |

**Review Notes:**
- Useful for query governance
- Heuristic-based estimation

---

### lib/selecto/performance/metrics_collector.ex
**References:** 1 file references this module
**Purpose:** Query metrics collection.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| collect | 2 | Collect query metrics |
| report | 0 | Get metrics report |

**Review Notes:**
- Good for monitoring
- Telemetry integration

---

## Database Layer

---

### lib/selecto/connection.ex
**References:** 1 file references this module
**Purpose:** Database connection management.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| configure | 1 | Configure connection |
| execute | 2 | Execute with connection |

**Review Notes:**
- Connection abstraction
- Good Postgrex integration

---

### lib/selecto/connection_pool.ex
**References:** 1 file references this module
**Purpose:** Connection pool management.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| get_connection | 1 | Get pooled connection |
| return_connection | 1 | Return to pool |

**Review Notes:**
- Pool integration
- Could integrate with DBConnection

---

### lib/selecto/database/adapter.ex
**References:** 1 file references this module
**Purpose:** Database adapter behaviour.

#### Callbacks
| Callback | Arity | Description |
|----------|-------|-------------|
| execute | 2 | Execute query |
| to_sql | 1 | Generate SQL |

**Review Notes:**
- Adapter abstraction
- Enables multi-database support

---

### lib/selecto/database/dialect.ex
**References:** 1 file references this module
**Purpose:** SQL dialect definitions.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| for_adapter | 1 | Get dialect for adapter |

**Review Notes:**
- Dialect abstraction
- PostgreSQL focus

---

### lib/selecto/database/features.ex
**References:** 1 file references this module
**Purpose:** Database feature detection.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| supports? | 2 | Check feature support |
| available_features | 1 | List supported features |

**Review Notes:**
- Feature detection
- Good for conditional SQL generation

---

### lib/selecto/database/registry.ex
**References:** 1 file references this module
**Purpose:** Database adapter registry.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| register | 2 | Register adapter |
| lookup | 1 | Look up adapter |

**Review Notes:**
- Extensible registry
- Good pattern for plugins

---

### lib/selecto/database/types.ex
**References:** 1 file references this module
**Purpose:** Database type mappings.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| to_db_type | 2 | Convert to database type |
| from_db_type | 2 | Convert from database type |

**Review Notes:**
- Type conversion
- PostgreSQL type support

---

### lib/selecto/db/postgresql.ex
**References:** 1 file references this module
**Purpose:** PostgreSQL-specific adapter.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| execute | 2 | Execute PostgreSQL query |
| to_sql | 1 | Generate PostgreSQL SQL |

**Review Notes:**
- PostgreSQL implementation
- Good for PG-specific features

---

## Utility Modules

---

### lib/selecto/field_resolver.ex
**References:** 2 files reference this module
**Purpose:** Field resolution and validation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| resolve | 2 | Resolve field reference |
| validate | 2 | Validate field exists |

**Review Notes:**
- Central field resolution
- Good error reporting

---

### lib/selecto/field_resolver/parameterized_parser.ex
**References:** 1 file references this module
**Purpose:** Parse parameterized field references.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| parse | 1 | Parse parameterized field |

**Review Notes:**
- Handles dynamic field references
- Good for multi-tenant

---

### lib/selecto/domain_validator.ex
**References:** 1 file references this module
**Purpose:** Domain definition validation.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| validate | 1 | Validate domain structure |
| validate! | 1 | Validate, raise on error |

**Review Notes:**
- Comprehensive validation
- Good error messages

---

### lib/selecto/type_system.ex
**References:** 1 file references this module
**Purpose:** Type system utilities.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| infer_type | 1 | Infer type from value |
| compatible? | 2 | Check type compatibility |

**Review Notes:**
- Type inference
- Good for validation

---

### lib/selecto/option_provider.ex
**References:** 1 file references this module
**Purpose:** Dynamic option value providers.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| get_options | 2 | Get options for field |
| register_provider | 2 | Register option provider |

**Review Notes:**
- Dynamic options (e.g., dropdowns)
- Good for UI integration

---

### lib/selecto/log_sanitizer.ex
**References:** 1 file references this module
**Purpose:** Sanitize values for logging.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| sanitize | 1 | Sanitize value for logs |

**Review Notes:**
- PII protection
- Good security practice

---

### lib/selecto/telemetry.ex
**References:** 1 file references this module
**Purpose:** Telemetry event emission.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| span | 3 | Create telemetry span |
| emit | 2 | Emit telemetry event |

**Review Notes:**
- Standard telemetry integration
- Good for observability

---

### lib/selecto/ecto_adapter.ex
**References:** 1 file references this module
**Purpose:** Ecto integration utilities.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| from_schema | 1 | Build domain from Ecto schema |
| to_ecto_query | 1 | Convert Selecto to Ecto query |

**Review Notes:**
- Good Ecto integration
- Enables gradual adoption

---

### lib/selecto/enhanced_joins.ex
**References:** 1 file references this module
**Purpose:** Enhanced join capabilities.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| build | 3 | Build enhanced join |

**Review Notes:**
- Extended join features
- Good for complex relationships

---

### lib/selecto/dynamic_join.ex
**References:** 1 file references this module
**Purpose:** Runtime dynamic joins.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| create | 2 | Create dynamic join |
| apply | 2 | Apply dynamic join to query |

**Review Notes:**
- Runtime join building
- Good for flexible queries

---

### lib/selecto/pivot.ex
**References:** 1 file references this module
**Purpose:** Pivot query support.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| configure | 2 | Configure pivot |
| build | 1 | Build pivot query |

**Review Notes:**
- Crosstab support
- Good for reporting

---

### lib/selecto/auto_pivot.ex
**References:** 1 file references this module
**Purpose:** Automatic pivot detection.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| detect | 1 | Detect pivotable data |
| suggest | 1 | Suggest pivot configuration |

**Review Notes:**
- Intelligent pivot detection
- Good UX feature

---

### lib/selecto/window.ex
**References:** 1 file references this module
**Purpose:** Window function support.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| configure | 2 | Configure window |
| over | 3 | Define OVER clause |

**Review Notes:**
- Window function API
- Good partition/order support

---

### lib/selecto/subselect.ex
**References:** 1 file references this module
**Purpose:** Subquery support.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| create | 2 | Create subquery |
| correlate | 2 | Add correlation |

**Review Notes:**
- Subquery abstraction
- Good correlation support

---

### lib/selecto/set_operations.ex
**References:** 1 file references this module
**Purpose:** Set operations (UNION, etc.).

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| union | 2 | UNION queries |
| intersect | 2 | INTERSECT queries |
| except | 2 | EXCEPT queries |

**Review Notes:**
- Complete set operations
- Good schema validation

---

### lib/selecto/query_timeout_monitor.ex
**References:** 1 file references this module
**Purpose:** Query timeout monitoring.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| start | 1 | Start timeout monitor |
| cancel | 1 | Cancel monitor |

**Review Notes:**
- Timeout protection
- Good for runaway queries

---

### lib/selecto/phoenix_helpers.ex
**References:** 1 file references this module
**Purpose:** Phoenix integration helpers.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| from_params | 2 | Build query from params |
| to_assigns | 2 | Convert to LiveView assigns |

**Review Notes:**
- Phoenix/LiveView integration
- Good for web apps

---

### lib/selecto/config/overlay.ex
**References:** 1 file references this module
**Purpose:** Configuration overlay support.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| apply | 2 | Apply overlay to config |
| merge | 2 | Merge overlays |

**Review Notes:**
- Configuration composition
- Good for variants

---

### lib/selecto/config/overlay_dsl.ex
**References:** 1 file references this module
**Purpose:** DSL for configuration overlays.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| define | 1 | Define overlay with DSL |

**Review Notes:**
- Declarative overlay definition
- Good developer experience

---

### lib/selecto/helpers/date.ex
**References:** 1 file references this module
**Purpose:** Date handling utilities.

#### Public Functions
| Function | Arity | Description |
|----------|-------|-------------|
| parse | 1 | Parse date string |
| format | 2 | Format date |

**Review Notes:**
- Date utility functions
- Good for filters

---

## Summary

### Strengths
1. **Comprehensive SQL Support** - Covers most PostgreSQL features including JSON, arrays, CTEs, window functions
2. **Good Security** - SQL injection prevention through identifier validation
3. **Clean Architecture** - Well-separated concerns with builder pattern
4. **Type Safety** - Good type handling and validation
5. **Extensibility** - Registry patterns for hooks, adapters, subfilters

### Areas for Improvement
1. **Documentation** - Many functions lack @doc strings
2. **Test Coverage** - Would benefit from comprehensive test documentation
3. **Error Messages** - Some error messages could be more helpful
4. **Multi-Database** - PostgreSQL-focused, limited other DB support

### Key Integration Points
- Entry: `Selecto.configure/2` -> query building -> `Selecto.execute/1-2`
- SQL Generation: `Selecto.Builder.Sql.build/2`
- Output: `Selecto.Output.Formats.format/2-3`
