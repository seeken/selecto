# Core verification on Beep

The existing CI workflow runs in disposable `beep-vm` guests with pinned
Elixir 1.20.0 and OTP 29.0.2. It retains both authoritative jobs:

- Quality: locked dependencies, full `mix precommit`, the explicit performance
  tests, documentation with warnings as errors, and Hex package assembly.
- Dialyzer: locked dependencies, PLT build, and analysis with unused ignore
  filters reported.

The Core repository contains its test adapters and external-adapter package
fixture, so neither job needs private sibling checkout access. Checkout does
not retain credentials. Actions are pinned to commit hashes, and job permissions
are `contents: read`.

Each job uploads its tested Git commit, actual runtime and check logs, including
on failure. A failing check remains a failing job. Only superseded heads of the
same pull request cancel one another; main, manual and unrelated runs remain
distinct.

The central backend certificate provides additional bounded runtime evidence;
it does not replace Core's complete quality and Dialyzer jobs. Beep's existing
actor/fork/private-destination protections and two-job/one-VM limits apply.
