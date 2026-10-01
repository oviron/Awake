# Testing

## Check a code change

On a Mac with Swift 6.2+ and a matching macOS SDK, run this from the repository root.
The development checks also work with Command Line Tools:

```sh
swift Tools/ProjectTool.swift check
```

It checks formatting, builds the app and runs the tests. Success ends with
**All current local checks passed.** It installs nothing and does not change
sleep, login or sudo settings.

For memory and concurrency checks, also run:

```sh
swift Tools/ProjectTool.swift asan
swift Tools/ProjectTool.swift tsan
```

If the repository is in an iCloud-synced folder, keep build files outside it:

```sh
env AWAKE_BUILD_PATH=/private/tmp/awake-build swift Tools/ProjectTool.swift check
```

Set `SDKROOT` to an installed SDK path if the selected SDK and Swift compiler do not match.

## Preview the interface

```sh
swift Tools/ProjectTool.swift preview
```

Open the **Awake.app** path printed at the end. This is an inert preview,
with a PNG beside it. It cannot keep the Mac awake or install the helper.
Previews use a separate app identity so they do not replace Awake in macOS settings.
For the setup screen instead:

```sh
env AWAKE_PREVIEW_STATE=setup swift Tools/ProjectTool.swift bundle
```

Other previews: `inactive`, `thermal`, `process`, `desktop`, `external`, `battery-unknown`, `battery-low`,
`touch-id-external` and `touch-id-permission`. Check light/dark mode, Tab navigation, VoiceOver and
Reduce Motion/Transparency. Check that content stays within the menu on first opening and when
Automatic updates changes or an Update button appears. Keyboard input must follow the Mac's
layout and locale.

## Test the installed app

Use a real installation, not the preview. Record the app version, Mac model,
macOS version and any steps that fail.

- Enable the helper; verify launch at login turns on. Turn it off and reopen the
  app: it must stay off. Login must never start a session.
- Restart the Mac and record how long the adaptive helper takes to reconnect after login.
  It must become responsive without manual intervention or weakened client validation.
- Start a short timer, then try Stop, a date and multiple PIDs.
- On a laptop, test lid open/closed, switching power and the battery limit.
- Confirm a serious/critical thermal reading stops all sessions and restores the
  owned sleep override. Cooling must not restart those sessions. Use the `thermal`
  fixture for interface checks; do not deliberately overheat the Mac to test this.
- Type a battery limit, press Return or leave the field, then try the arrows.
  Letters are refused; 81 becomes 80. A blocked start or battery cutoff explains why.
- Run two AI tasks. The last one ending stops their hold; manual sessions stay yours.
- Try Touch ID, Cancel and password fallback for sudo.
  Its setup component uses the Awake icon and **Awake — Touch ID for sudo**
  name. Full Disk Access can list its helper as **io.github.oviron.Awake.sudo.helper**.
  Keep access off for the main app and power helper.
  A refused change must show a red warning and orange button below the sudo switch,
  without interrupting an awake session. The button must open only System Settings.
  Enable the sudo helper's entry and retry; no automatic retry. Revoke access and
  verify that a later change fails.
- Right-click **Check for Updates**. An available update installs immediately while idle;
  a manual check resets the eight-hour clock and can retry a delayed download after five
  minutes. The current release must report that it is up to date without contacting
  `api.github.com`. During that delay, verify that the inline **Update** button is absent. Confirm the
  published archive accepts the bundled `Awake Sudo.app` path. Verify the helper returns after the reopened
  app; if replacement is deliberately failed, verify the previous app reopens and restores it.
  After approving a quarantined update, verify that CLI opt-in is restored even if macOS
  starts the app from a randomized path; the next update must still target the signed app
  in Applications. Do not remove quarantine to make this pass.
- Command-drag the Awake icon farther right, relaunch the app and verify that macOS restores
  its position.
- Then uninstall: the app should close and its integrations disappear.
  Cancel the sudo component's administrator prompt, retry removal, and verify both
  helpers disappear. An existing external sudo setting must remain unchanged.
  Repeat after a quarantined update that launches through App Translocation: the
  signed app in Applications must move to the Trash, not the temporary running copy.
  If that installed copy is missing or has a different version, removal must stop
  before changing the helpers or preferences.

For long runs, keep the Mac ventilated and leave battery protection enabled.
If stopping or uninstalling fails, keep the app and report the error before retrying.

## Before distribution

Hosted CI and signed installation must be verified before declaring a release ready.
The local `.github/workflows/check.yml` checks native code, a universal
development bundle and both sanitizers on macOS 15/Xcode 26.3. Action revisions
are pinned. It must pass on GitHub after authorized publication; local workflow
linting is not evidence of a successful hosted run.
Run the local checks and both sanitizers against the final source, then the signed
XPC/update probes and installed-app matrix above. A universal build alone does not
prove execution on Intel or older macOS versions. Automated results do not replace
the installed-app checks. Commit, publication and helper installation require the
owner's authorization.
