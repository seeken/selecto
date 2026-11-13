# SelectoUpdato telemetry

SelectoUpdato emits vendor-neutral canonical operation spans at
`[:selecto_updato, :telemetry, :operation, :start/:stop/:exception]`. Metadata
uses Selecto's version 1 safe envelope and identifies `:execute` or `:dry_run`
as `operation_kind`. Returned errors finish with a bounded outcome and error
category. SQL, write inputs, row data, and raw errors are excluded.

Legacy `[:selecto_updato, :execute, ...]` and `:dry_run` spans remain during the
migration period. New integrations should consume only canonical events to
avoid duplicate counts.
