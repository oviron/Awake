# Installation

**macOS 14+ · Intel & Apple Silicon**

The first release is an ad-hoc development preview. It cannot enable the helper.
The steps below describe a future signed distribution; use
[the README](../README.md) for development checks.

1. When a signed release is available, download it from [GitHub Releases](https://github.com/oviron/Awake/releases).
2. Unzip it, drag **Awake.app** to **Applications** and open it.
3. Click its menu-bar icon, then **Enable Awake**. Approve the macOS prompt.

The same download includes the app, CLI and AI skill. Launch at login turns on
after helper approval. You can turn it off; it never starts a keep-awake session.
Enable **Allow CLI & AI tasks** to use the [terminal and AI integrations](cli.md).

**Keep awake with lid closed** is the main switch. Turning it on starts protection
immediately without a timer; turning it off ends all Awake sessions, including
CLI sessions, while their commands continue. Power-source, battery and temperature
limits still apply. The caption distinguishes active protection, waiting for power
and unconfirmed restoration. For a timer, date or process, choose a stop condition
and click **Start session** instead. Protection ends on app quit and does not
automatically resume at login, after cooling or after a battery cutoff.

If macOS blocks opening, use **System Settings → Privacy & Security → Open Anyway**
when offered. [Apple's instructions](https://support.apple.com/en-gb/102445).

## Touch ID for sudo

Enable it in the menu to use your fingerprint for `sudo`. Your password still
works. This is a Mac-wide setting; it does not change Awake's administrator
prompt. Remote sessions may still need a password.

The first change installs a separate **Awake — Touch ID for sudo** component,
with its own administrator approval. If macOS blocks the change, click **Open Full
Disk Access**. In Settings, enable the entry ending in **Awake.sudo.helper**,
then return to Awake and retry the toggle.

Keep the main app and sleep helper disabled in that list. You can revoke the sudo
helper's access afterward; changing Touch ID or removing its rule needs it again.
This remains a broad macOS permission, held by the separate sudo helper.

## Updates and removal

Automatic updates turn on with the helper and can be disabled. Awake checks every eight
hours and starts installing a detected update immediately while idle. Otherwise, an **Update**
button appears when a version is available and disappears during the retry delay. Right-click
the menu-bar icon → **Check for Updates** to perform a fresh check and install an available
update while idle. A manual check resets the eight-hour timer and can retry a delayed download
after five minutes; server retry deadlines still apply. Checks read the published `release.json`
asset instead of GitHub's rate-limited REST API. Awake requires its source revision to match
the signed app's `Build.json`, verifies the download, then installs and reopens the app.
If the helper was enabled, the reopened version restores it; a failed replacement reopens
the previous app so the same recovery can run. macOS may run a quarantined update from a
temporary, randomized location. Awake verifies the matching signed copy in
Applications before restoring CLI access, replacing it on the next update or moving it
to the Trash. If macOS asks for administrator approval during removal, the power and
Touch ID helpers have separate approvals; a missing Touch ID helper may first need
to be restored to remove a Awake-owned Touch ID rule.

To move Awake farther right in the menu bar, hold Command and drag its icon. macOS remembers
that position for later launches.

Right-click the menu-bar icon → **Uninstall Awake**. This stops sessions and
removes the app, helper, CLI shortcut, login item, preferences and AI integrations
installed by Awake. Existing Touch ID settings and recovery backups are kept.
