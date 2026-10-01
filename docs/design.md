# Design

One 340-point menu. Native material, system typography, short labels and no
separate preferences window. Content sets the height; long lists scroll.

- 21-point title. Battery and remaining time share the callout size.
- Standard square menu-bar item: 21-point loop, 5-point orange dot below/right.
- macOS restores the menu-bar position after the user moves the item with Command-drag.
- Small footer: version, blue author link, MIT and GitHub.
- Immediate settings, one Stop button, outside-click dismissal.
- Right-click Check for Updates/Quit/Uninstall follows the app's light/dark appearance; red destructive confirmation.
- Timer and remaining PIDs refresh each second without animation.
- Native opening motion; immediate keyboard and Reduce Motion opening.
- No selected control on opening; Tab keeps its native focus indicator.
- Opaque backgrounds for Reduce Transparency/increased contrast.
- Text and symbols accompany color. Controls have accessibility labels.

Hide unavailable controls before helper approval. Enable launch at login after helper
activation, then respect the user's choice. Login never starts a keep-awake session.
Hide power controls on desktops and the battery limit in adapter mode. Zero warns.
Keep the power-source label above its segmented control so it fits the fixed menu width.
Battery limit accepts digits only, with the one-percent arrows beside the field.
Values above 80 become 80. Return or leaving the field applies it.
Explain a blocked start or battery cutoff beside the session controls, with a red warning symbol.
Only process mode shows the session ceiling; wait for all selected PIDs.

CLI opt-in is remembered without restarting a session. Updates start enabled
after helper approval and install only while idle; background check failures do not add text to the menu.
Manual checks distinguish an up-to-date app, an active cooldown and a network failure.
Uninstall shows progress and keeps a retryable error if cleanup fails.

Touch ID for sudo appears on supported Macs after helper approval. Confirm its
Mac-wide scope before enabling or disabling a setting configured elsewhere.
Show Touch ID errors directly below its toggle, with a red warning symbol.
Permission refusals name the sudo helper's entry and include an orange Full Disk
Access button. It opens only System Settings.
Keep the observed toggle state and the helper connection.

Native previews are inert. Check light/dark appearance, keyboard, VoiceOver,
contrast and reduced motion for each release. [Testing](testing.md).

Keep the translucent native material on macOS 14 and later. Use Liquid Glass
controls on macOS 26+, with standard controls on older versions. Accessibility
settings take precedence over transparency.
