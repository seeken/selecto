#!/usr/bin/env bash
set -euo pipefail

boundary_pattern='Postgrex|SelectoDBPostgreSQL|Selecto\.DB\.PostgreSQL|postgrex_opts|pg_catalog|pg_proc|pg_stat|pg_trgm|to_regprocedure|to_tsquery|generate_series'
native_type_pattern='(^|[^[:alnum:]_])(tsvector|tsquery|jsonb|int2|int4|int8|float4|float8|bpchar|timestamptz|timetz|bytea|regclass|hstore|macaddr|bigserial|smallserial)([^[:alnum:]_]|$)'
sql_literal_pattern='[$][0-9]+|[$][#][{]|ARRAY\[|(^|[^[:alnum:]_])(ILIKE|TO_CHAR|TO_TIMESTAMP|SPLIT_PART|BTRIM|REGEXP_REPLACE)([^[:alnum:]_]|$)|AT[[:space:]]+TIME[[:space:]]+ZONE|::(int|integer|text|numeric|bigint)([^[:alnum:]_]|$)'

# These exact lines recognize historical input type aliases; they do not render
# SQL or enable a backend capability. Keep every other match in these files,
# including any altered version of an approved line, subject to the gate.
filter_input_aliases() {
  while IFS= read -r match; do
    path="${match%%:*}"
    numbered_body="${match#*:}"
    line_number="${numbered_body%%:*}"
    body="${numbered_body#*:}"

    if [[ "$line_number" =~ ^[0-9]+$ ]]; then
      case "$path:$body" in
        lib/selecto/json.ex:'      %{type: type} when type in [:json, :jsonb] -> true' | \
        lib/selecto/domain/contract/computed_values.ex:'      t when t in ~w(utc_datetime datetime naive_datetime timestamp timestamptz) -> :datetime' | \
        lib/selecto/domain/contract/computed_values.ex:'      t when t in ~w(jsonb json) -> :json') continue ;;
      esac
    fi

    printf '%s\n' "$match"
  done
}

if command -v rg >/dev/null 2>&1; then
  production_matches="$(rg -n -i "$boundary_pattern|$native_type_pattern" lib || true)"
  sql_literal_matches="$(rg -n -i "$sql_literal_pattern" lib/selecto/builder lib/selecto/sql/functions.ex lib/selecto/sql/formatter.ex || true)"
  dependency_matches="$(rg -n -i 'SelectoDB(PostgreSQL|SQLite|MySQL|MariaDB|MSSQL|DuckDB)|selecto_db_(postgresql|sqlite|mysql|mariadb|mssql|duckdb)|Postgrex|postgrex|Exqlite|exqlite|MyXQL|myxql|Tds|DuckDB' mix.exs | rg -v 'only: :test' || true)"
else
  production_matches="$(grep -RniE "$boundary_pattern|$native_type_pattern" lib || true)"
  sql_literal_matches="$(grep -RniE "$sql_literal_pattern" lib/selecto/builder lib/selecto/sql/functions.ex lib/selecto/sql/formatter.ex || true)"
  dependency_matches="$(grep -niE 'SelectoDB(PostgreSQL|SQLite|MySQL|MariaDB|MSSQL|DuckDB)|selecto_db_(postgresql|sqlite|mysql|mariadb|mssql|duckdb)|Postgrex|postgrex|Exqlite|exqlite|MyXQL|myxql|Tds|DuckDB' mix.exs | grep -v 'only: :test' || true)"
fi

production_matches="$(printf '%s\n' "$production_matches" | filter_input_aliases)"
matches="${production_matches}${sql_literal_matches:+$'\n'}${sql_literal_matches}${dependency_matches:+$'\n'}${dependency_matches}"

if [[ -n "$matches" ]]; then
  echo "selecto PostgreSQL production-boundary violation:" >&2
  echo "$matches" >&2
  exit 1
fi

echo "selecto PostgreSQL production boundary: clean"
