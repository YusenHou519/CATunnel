# Changelog

## Unreleased

- Close owned SSH processes on system sleep and resume eligible requested connections
  on wake, without restarting manually stopped or terminally failed connections.
- Add an optional, default-off continuous forwarding recovery setting: after the
  existing five-attempt budget, retry every 60 seconds until recovery or manual stop.
  It requires automatic reconnection and a previously established connection.
- Add a separate, default-off Ping0 public-page check for IP type, risk value,
  and shared-user estimates, bound to the observed Claude exit IP. Provider
  errors do not interrupt tunnels; unavailable fields remain explicitly unknown.
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
