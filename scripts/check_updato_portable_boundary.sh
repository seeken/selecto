#!/usr/bin/env bash
set -euo pipefail

boundary_pattern='Postgrex|SelectoDBPostgreSQL|Selecto\.DB\.PostgreSQL|postgrex_opts|postgres|pg_catalog|pg_trgm|to_tsquery'
native_type_pattern='(^|[^[:alnum:]_])(tsvector|tsquery|jsonb|int2|int4|int8|float4|float8|bpchar|timestamptz|timetz|bytea|regclass|hstore|macaddr|bigserial|smallserial)([^[:alnum:]_]|$)'

if command -v rg >/dev/null 2>&1; then
  matches="$(rg -n -i "$boundary_pattern|$native_type_pattern" lib/selecto_updato lib/selecto_updato.ex || true)"
else
  matches="$(grep -RniE "$boundary_pattern|$native_type_pattern" lib/selecto_updato lib/selecto_updato.ex || true)"
fi

if [[ -n "$matches" ]]; then
  echo "SelectoUpdato portable boundary violation:" >&2
  echo "$matches" >&2
  exit 1
fi

echo "SelectoUpdato portable boundary: clean"
