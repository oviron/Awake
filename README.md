# Awake

A native Swift menu-bar application for macOS 14+, Intel and Apple Silicon.
Awake is based on [Limitless](https://github.com/leboonducoin/Limitless).
See [UPSTREAM.md](UPSTREAM.md) for the exact imported revision and license.

The first published build is a **development preview**, ad-hoc signed. It can
display the interface but cannot enable the administrator helper or keep a
closed MacBook awake. A functional signed distribution and physical acceptance
checks remain pending. [Development releases](https://github.com/oviron/Awake/releases).

## Behavior

- Timed, unlimited, date-based and process-based sessions; CLI integration.
- Battery and power-source limits, actual sleep-state observation, bounded
  recovery and a durable ownership journal.
- Stops every hold under serious/critical macOS thermal pressure, or an
  unavailable thermal reading. Cooling does not resume an old session.
- A signed, authenticated root helper controls closed-lid sleep. It exposes no
  arbitrary command or file path. Approval is separate from building.
- Isolated `io.github.oviron.Awake` app/helper identities, preferences, journal,
  CLI integration and update source; original licenses remain unchanged.
- Screen locking remains under macOS control; Awake does not synthesize
  layout-dependent lock-screen shortcuts.

Thermal pressure is Apple's coarse system reading, not a temperature sensor or a
promise that a closed laptop can safely run in an enclosed space.
The macOS `disablesleep` flag is global: the journal preserves a hold observed
before Awake starts, but cannot attribute another application's later write of
the same value. Use one writer for closed-lid sleep; concurrent global writers
cannot be safely coordinated by this flag alone.

## Build and check

Swift 6.2+ and a macOS SDK are required. The local development build also works
with Apple's Command Line Tools. No package dependencies are downloaded.

```sh
swift Tools/ProjectTool.swift check
swift Tools/ProjectTool.swift asan
swift Tools/ProjectTool.swift tsan
swift Tools/ProjectTool.swift bundle
swift Tools/ProjectTool.swift preview
```

The check builds all executables, runs unit/integration doubles, checks Swift
formatting and validates distribution and signature rejection logic. None of
these commands installs a helper or changes system sleep or sudo settings.
A development `.app` is ad-hoc signed and rejects privileged operations.
The preview is inert, has a separate identity and exports a native panel PNG.

For a chosen output directory, set `AWAKE_OUTPUT_DIR` to a new path. For the
installed application's release artifact, follow [distribution](docs/distribution.md).
That path requires a clean committed source tree and a valid signing identity;
a signed distributable release still requires a signing identity.

## Changes from the imported source

- Renamed the products, bundle IDs, CLI, journal and integration paths to Awake.
- Directed release downloads to `oviron/Awake`, preserving signature and
  source-revision verification.
- Added thermal pressure to service telemetry and wire version 11.
- Added permanent thermal cutoff, visible feedback, disabled starts while hot,
  and rejection of start requests by the helper while thermal state is unsafe.
- Preserved existing timer, process identity, ownership, restoration, installer,
  updater and authorization tests; added thermal regressions.

## Acceptance still required

A compiled development bundle does not prove closed-lid operation. Signed helper
installation, physical lid transitions, AC/battery changes, system screen lock,
helper/app crashes, reboot recovery and removal must be verified on the target
Mac. The inherited signed-XPC/update probes are in `Tests/`; the concrete manual
matrix is in [docs/testing.md](docs/testing.md).

[MIT](LICENSE) — original copyright © 2026 Arthur Barreau preserved.
