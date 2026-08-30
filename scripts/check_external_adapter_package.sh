#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_dir="$repo_dir/integration/external_adapter_fixture"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/selecto-external-adapter.XXXXXX")

cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

core_package="$work_dir/selecto-package"
adapter_source="$work_dir/acme-adapter-source"
adapter_tar="$work_dir/acme-selecto-adapter.tar"

mkdir -p "$adapter_source"
cp "$fixture_dir/mix.exs" "$adapter_source/mix.exs"
cp -R "$fixture_dir/lib" "$fixture_dir/test" "$adapter_source/"

(
  cd "$repo_dir"
  mix hex.build --unpack --output "$core_package"
)

(
  cd "$adapter_source"
  SELECTO_EXTERNAL_CORE_PATH="$core_package" \
    MIX_BUILD_PATH="$work_dir/build" \
    MIX_DEPS_PATH="$work_dir/deps" \
    MIX_LOCKFILE="$work_dir/mix.lock" \
    mix deps.get --only test
  SELECTO_EXTERNAL_CORE_PATH="$core_package" \
    MIX_BUILD_PATH="$work_dir/build" \
    MIX_DEPS_PATH="$work_dir/deps" \
    MIX_LOCKFILE="$work_dir/mix.lock" \
    mix test
  env -u SELECTO_EXTERNAL_CORE_PATH mix hex.build --output "$adapter_tar"
)

test -s "$adapter_tar"
