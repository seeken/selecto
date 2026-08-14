#!/usr/bin/env bash
set -euo pipefail

boundary_pattern='Postgrex|SelectoDBPostgreSQL|Selecto\.DB\.PostgreSQL|postgrex_opts|pg_catalog|pg_proc|pg_stat|pg_trgm|to_regprocedure|to_tsquery|generate_series'
native_type_pattern='(^|[^[:alnum:]_])(tsvector|tsquery|jsonb|int2|int4|int8|float4|float8|bpchar|timestamptz|timetz|bytea|regclass|hstore|macaddr|bigserial|smallserial)([^[:alnum:]_]|$)'
sql_literal_pattern='[$][0-9]+|[$][#][{]|ARRAY\[|(^|[^[:alnum:]_])(ILIKE|TO_CHAR|TO_TIMESTAMP|SPLIT_PART|BTRIM|REGEXP_REPLACE)([^[:alnum:]_]|$)|AT[[:space:]]+TIME[[:space:]]+ZONE|::(int|integer|text|numeric|bigint)([^[:alnum:]_]|$)'

if command -v rg >/dev/null 2>&1; then
  production_matches="$(rg -n -i "$boundary_pattern|$native_type_pattern" lib || true)"
  sql_literal_matches="$(rg -n -i "$sql_literal_pattern" lib/selecto/builder lib/selecto/sql/functions.ex lib/selecto/sql/formatter.ex || true)"
  dependency_matches="$(rg -n -i 'SelectoDBPostgreSQL|selecto_db_postgresql|Postgrex|postgrex' mix.exs | rg -v 'only: :test' || true)"
else
  production_matches="$(grep -RniE "$boundary_pattern|$native_type_pattern" lib || true)"
  sql_literal_matches="$(grep -RniE "$sql_literal_pattern" lib/selecto/builder lib/selecto/sql/functions.ex lib/selecto/sql/formatter.ex || true)"
  dependency_matches="$(grep -niE 'SelectoDBPostgreSQL|selecto_db_postgresql|Postgrex|postgrex' mix.exs | grep -v 'only: :test' || true)"
fi

matches="${production_matches}${sql_literal_matches:+$'\n'}${sql_literal_matches}${dependency_matches:+$'\n'}${dependency_matches}"

if [[ -n "$matches" ]]; then
  echo "selecto PostgreSQL production-boundary violation:" >&2
  echo "$matches" >&2
  exit 1
fi

echo "selecto PostgreSQL production boundary: clean"
