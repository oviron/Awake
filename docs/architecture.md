# Architecture

| Module | Job |
| --- | --- |
| AwakeCore | Policies, sessions, deadlines and recovery |
| AwakeSystem | macOS power, signatures, XPC, processes and installation |
| AwakeApp | SwiftUI menu, AppKit integration and preferences |
| AwakeCLI | Commands, process tracking and AI hooks |
| AwakeHelper | Privileged sleep operations and watchdog |
| AwakeSudo / AwakeSudoHelper | Separate sudo setup and privileged PAM changes |

Swift throughout. No package dependencies, database or analytics.

## Sessions

The helper owns the shared session registry. Each authenticated connection owns
its demands; disconnect or a missed lease releases them. Heartbeats run every
5 seconds with a 30-second lease. Relative deadlines use a continuous clock.

Stop, deadlines, battery protection, thermal cutoff and owner loss outrank recovery. Sessions
never resume after login or reboot. CLI permission is remembered; faults revoke it.
AI uses both sources and at least 20% battery, within user limits. Manual sessions
reject or end AI holds. A stopped task cannot reacquire protection.

## Power

`MacSleepBackend` isolates the undocumented global `pmset disablesleep` flag.
Battery/adapter modes are policies, not independent macOS flags. Unknown readings
suspend protection. All active sessions use Apple’s `caffeinate -i` to prevent idle sleep;
the helper checks its assertion every two seconds. The separate closed-lid policy
adds `pmset disablesleep` only while a session is eligible. Changing that policy
keeps the current session and deadline. With the policy off, closing the lid follows
normal macOS behavior. Recovery and restoration each allow three attempts.
Serious/critical macOS thermal pressure or an unrecognized thermal state stops all
sessions permanently; the helper rejects new starts until the reading is safe.
This is a coarse system pressure reading, not a physical temperature measurement.

Only owned state is restored. A protected root journal records ownership before
changes and survives interruption; invalid files fail closed. Competing privileged
tools can still change the global flag. Ordinary restart requests can be deferred
while the app is active; forced restarts remain outside its control.

## Trust and files

App and CLI use separate XPC endpoints. Both sides verify the exact executable ID
and certificate. Requests are bounded to 128 KiB, with 64 clients and 256 sessions.
The helper accepts no arbitrary command or path. It alone installs the fixed CLI
link. Root files use ownership, permissions, no-follow, locking and atomic writes.

The optional sudo component has its own app identity, icon and administrator
approval. Its helper belongs only to that component; Full Disk Access is not
requested for the menu app or power helper. Only the signed menu app of the
current console user can call its XPC endpoint. It accepts sudo settings and its
own cleanup, with eight clients and 1 KiB requests, then exits when idle.

The Touch ID operation edits the fixed `sudo_local` file, never `sudo`.
It requires the standard macOS PAM stack, preserves password fallback and rejects
custom active rules. Explicit disable can remove an existing Touch ID rule after
confirmation. Updates keep it; uninstall removes only Awake’s owned block.
macOS permission refusals are separate from connection failures. The app offers
Full Disk Access guidance; it never grants access or retries the write automatically.

AI hooks read lifecycle IDs only. Private markers bind a task to its original
process and file identity. Setup merges only Awake hooks, backs up existing
settings and refuses linked, shared-writable or write-ACL-controlled paths. Setup and
removal roll back the skill, marker and settings together. Removal preserves other integrations.

## Updates and removal

Checks and download attempts wait eight hours, persisted across launches. A detected update
starts downloading immediately while the app is idle. A manual check resets the eight-hour
clock and can retry a delayed download after a five-minute cooldown. Version checks fetch the
published `release.json` asset rather than GitHub's rate-limited REST API. Server retry deadlines
remain mandatory. Failures back off to seven days, and a verified download resets its failure
count. Invalid persisted counters are discarded. Background errors stay quiet. No GitHub token
is needed or stored.

Updates verify archive bounds, SHA-256, source metadata and all five executable
signatures, including the sudo component and helper. They retain quarantine and a rollback backup. Removal closes admission,
confirms sleep restoration, removes the helper and owned CLI link, then clears
preferences and recycles the matching signed app in Applications, even when macOS
launched a quarantined copy from App Translocation. The installed copy is verified
before cleanup and again before recycling. Sudo cleanup runs in its own helper before
removing its service; updates preserve the setting. An update records whether the power helper
was enabled, restores it after relaunch and retries from the previous app if replacement fails.
Failed cleanup stays visible and retryable.

## Apple certificate selector

Apple’s certificate selector requires a SHA-1 fingerprint.
It identifies a public certificate; archive integrity uses SHA-256. Native
signature validation remains mandatory and the query stays enabled.
[Apple requirement language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html).
Community signatures also embed a designated requirement for the exact self-signed
anchor and executable identifier. Reciprocal app, CLI and helper authorization keeps
pinning the exact leaf certificate and identifier; neither requirement asks macOS to
trust a separately installed certificate.
