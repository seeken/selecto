#!/bin/sh
# Run README Quick Start in an unconfigured consumer with the real adapter.
# Requires PGHOST, PGPORT, PGUSER and PGDATABASE for a disposable PostgreSQL.
set -eu
core_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
adapter_dir=${SELECTO_README_ADAPTER_PATH:-"$core_dir/../selecto_db_postgresql"}
consumer_dir=$(mktemp -d "${TMPDIR:-/tmp}/selecto-readme.XXXXXX")
trap 'rm -rf "$consumer_dir"' EXIT HUP INT TERM
export SELECTO_README_CORE_PATH="$core_dir" SELECTO_README_ADAPTER_PATH="$adapter_dir"
export SELECTO_ECOSYSTEM_USE_LOCAL=1 SELECTO_ECOSYSTEM_SELECTO_PATH="$core_dir"
cat > "$consumer_dir/mix.exs" <<'EX'
defmodule ReadmeConsumer.MixProject do
  use Mix.Project
  def project do
    [app: :readme_consumer, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end
  def application, do: [extra_applications: [:logger]]
  defp deps do
    [
      {:selecto, path: System.fetch_env!("SELECTO_README_CORE_PATH"), override: true},
      {:selecto_db_postgresql, path: System.fetch_env!("SELECTO_README_ADAPTER_PATH")}
    ]
  end
end
EX
cat > "$consumer_dir/check.exs" <<'EX'
unless Application.fetch_env(:selecto, :default_adapter) == :error do
  raise "consumer must have no default adapter"
end
readme = File.read!(Path.join(System.fetch_env!("SELECTO_README_CORE_PATH"), "README.md"))
[_, quick_start] = String.split(readme, "## Quick Start", parts: 2)
[quick_start | _] = String.split(quick_start, "\n## ", parts: 2)
code = Regex.scan(~r/```elixir\n(.*?)```/s, quick_start, capture: :all_but_first)
       |> Enum.map_join("\n", &hd/1)
{_, bindings} = Code.eval_string(code)
[[2, total, "Acme"]] = bindings[:rows]
true = Decimal.equal?(total, Decimal.new("150.00"))
3 = length(bindings[:columns])
3 = length(bindings[:aliases])
IO.puts("README quick start passed in a fresh consumer without a default adapter")
EX
cd "$consumer_dir"
mix deps.get
mix run check.exs
