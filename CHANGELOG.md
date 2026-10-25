# Changelog

## Unreleased

- Close owned SSH processes on system sleep and resume eligible requested connections
  on wake, without restarting manually stopped or terminally failed connections.
- Add an optional, default-off continuous forwarding recovery setting: after the
  existing five-attempt budget, retry every 60 seconds until recovery or manual stop.
  It requires automatic reconnection and a previously established connection.
- Add experimental fixed-entry mode, off by default, with explicit in-app helper
  installation and a shared choice of existing remote Python for installation,
  verification, and connection control. No system Python installation or upgrade.
- Add an explicit fixed-entry status check for the local proxy port, SSH, Python,
  helper, entry, and active backend without changing existing connections. Results
  have check timestamps and distinguish failures, warnings, and unverified items.
- Find existing remote Python interpreters within bounded locations and timeouts;
  show versions and compatibility, and fill only the editor draft on explicit selection.
- Replace the Ping0 check with a button that opens its website in the default browser,
  using the observed exit IP when available and labeling historical IPs. Preserve
  the legacy setting without performing Ping0 requests or parsing its results.
- Retry transient listener-check timeouts and preserve startup preferences
  changed in another window when saving server edits.

## 0.6.0-preview.2 (build 5) — 2026-10-19

- Settings now separates Mac login startup from each server's startup connection
  preference. Older profiles default to manual connection, and changing startup
  preferences does not restart active tunnels.
- Login-item management reports macOS approval and errors, recognizes the previous
  CATunnel LaunchAgent, and changes it only after an explicit switch action.
- Offline checks cover startup selection, persistence, login-item failures and
  settings layout without touching real login items or connections.

## 0.6.0 preview (build 4)

First standalone source preview. The application interface is currently Chinese.

- Native menu-bar panel with compact server tabs, independent connection states,
  adjustable width and font size, and a multi-server overview.
- Empty first launch and editable server profiles, with versioned local storage
  and protection against overwriting invalid configuration files.
- First-use guide, identity-file selection, and explicit connection preparation
  checks. Host-key verification remains strict and noninteractive.
- Owned SSH reverse tunnels with loopback listeners and automatic reconnection
  after transient failures. Stopping a connection leaves other connections alone.
- On-demand network diagnostics and optional Net.Coffee assessments, disabled by
  default. Scores are labeled as reference information.
- Offline application checks, an isolated local SSH integration harness, and
  scripts for packaging and checking preview archives.

This preview does not migrate existing settings or configure remote applications.
It is not a notarized public release. See [validation](docs/VALIDATION.md) for
tested environments and remaining manual acceptance checks.
