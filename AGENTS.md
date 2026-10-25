# CATunnel agent guide

面向 AI Agent 的使用与配置指南；帮助用户配置前，请先确认操作范围。

Use this guide for setup, troubleshooting, and development. The [README](README.en.md)
introduces CATunnel. Run the examples below only within the user's requested scope.

## Connection model

CATunnel runs on the user's Mac and owns SSH reverse-forwarding processes:

```text
Remote program → remote 127.0.0.1:17892 → SSH tunnel → Mac 127.0.0.1:7890 → HTTP proxy
```

- The ports above are defaults, not fixed values. CATunnel does not provide the
  local proxy; an HTTP or mixed HTTP/SOCKS proxy must already be running on the Mac.
- The remote listener is restricted to IPv4 loopback. It is not a public proxy.
- Normal first launch has no servers. Demo mode alone supplies example servers.
- Remote Linux needs `ss` for listener checks and `curl` for website checks.
- CATunnel does not automatically configure Codex, Claude, editors, or shells.

## Help a user configure a server

1. Collect a resolvable hostname or IPv4 address, SSH username and port, the Mac's
   local HTTP proxy port, an available remote listener port, and an optional key
   file path. Never request or print private-key contents or API credentials.
2. Prefer **连接设置与日志…** (connection settings and logs) to add or edit a server.
   Active server connection settings cannot be edited or deleted until stopped.
   Stop only the connection authorized by the user.
3. Use the first-use guide and its SSH terminal verification command. Verify any
   new host fingerprint with the server owner before accepting it. CATunnel uses
   key authentication without password prompts; encrypted keys must be available
   through the SSH agent. Supplying a key path enables `IdentitiesOnly=yes`.
4. Run setup diagnostics when requested. They check the local TCP port, key-file
   metadata, SSH authentication/host trust, and remote `ss`/`curl` availability.
   They do not open a tunnel or visit external websites.
5. Connect, then run the network test when requested. Verify the remote program
   separately before describing a migration as complete.

Owned SSH commands use `-F /dev/null`: they ignore `~/.ssh/config`, including its
aliases, identity choices, forwarding rules, and jump-host settings. Enter an
actual resolvable host and explicit connection details. Jump hosts, password
prompts, and IPv6 host literals are not currently supported by the profile UI.
Do not silently rewrite SSH settings to compensate.

## Configuration files

Normal settings belong to the Mac user running CATunnel:
```text
~/Library/Application Support/CATunnel/profiles.json
~/Library/Application Support/CATunnel/ui-preferences.json
```

Prefer the GUI. For authorized JSON editing, explain that quitting CATunnel stops
**all of its owned tunnels**; ensure that interruption is authorized. Quit normally
before editing: profiles load at startup, and GUI writes can overwrite external
edits. Back up, preserve unrelated profiles, validate, then restart within the
authorized scope. Never use `killall ssh`. After the app has exited, back up with:

```sh
catunnel_config="$HOME/Library/Application Support/CATunnel/profiles.json"
if [ -f "$catunnel_config" ]; then
  cp -p "$catunnel_config" "$catunnel_config.backup-$(date +%Y%m%d-%H%M%S)"
fi
```

Schema version 1 example: replace `server.example`, `user`, and the display name
before connecting. Preserve existing IDs; choose distinct IDs for new profiles.

```json
{
  "version": 1,
  "profiles": [
    {
      "id": "server-a", "name": "Server A",
      "host": "server.example", "user": "user",
      "sshPort": 22,
      "remotePort": 17892,
      "localPort": 7890,
      "autoReconnect": true,
      "keepRetryingForwardingFailure": false,
      "identityFile": null,
      "assessIPRisk": false,
      "assessPing0": false,
      "autoConnectOnLaunch": false
    }
  ]
}
```

| Field | Meaning and constraints |
| --- | --- |
| `id` | Unique stable ID, 1–64 letters, digits, `_` or `-`; used by `--connect-once`. |
| `name` | Display name, 1–80 characters; no control characters. |
| `host`, `user` | Valid hostname/IPv4 and SSH username; `.example` hosts cannot connect. |
| `sshPort` | SSH service port; a new GUI profile starts at `22`. |
| `remotePort` | Remote loopback proxy listener; GUI default `17892`. |
| `localPort` | Mac loopback HTTP proxy destination; GUI default `7890`. |
| `autoReconnect` | Retry eligible failures of a started connection; GUI default `true`. |
| `keepRetryingForwardingFailure` | Current source only: default/omitted `false`; after a previously connected tunnel exhausts five forwarding retries, continue every 60 seconds while `autoReconnect` is enabled. |
| `useFixedEntry` | Current source only: experimental, default/omitted `false`. Connection requires a running compatible remote helper; installation is a separate explicit user action. |
| `fixedEntryHelperPath`, `fixedEntryRuntimePath` | Optional while fixed entry is off; when on, require explicit remote absolute paths. `remotePort` remains the fixed entry and must match the helper's status before takeover. |
| `fixedEntryPythonPath` | Optional remote Python executable absolute path. Omitted or empty uses `python3`; the same choice is used for installation, verification, and every fixed-entry control request. No local expansion of `~/`, shell activation, or automatic interpreter installation. |
| `identityFile` | Absolute or `~/` key path; omitted/null uses OpenSSH default keys/agent. |
| `assessIPRisk` | Opt-in Net.Coffee lookup of the observed public exit IP; omitted means `false`. |
| `assessPing0` | Legacy compatibility field: read and preserve its value, but it no longer triggers a lookup. Omitted means `false`; no migration is required. |
| `autoConnectOnLaunch` | Connect this server on normal app launch; omitted means `false`. |

All ports must be 1–65535. The first eight example fields are required; GUI defaults
are not JSON decoding defaults. Duplicate IDs and `host + sshPort + remotePort`
combinations are rejected. An empty configuration is `{"version": 1, "profiles": []}`.
Invalid files are preserved; profile changes stay disabled until repair and restart.

**Launch at login**, **connect on launch**, and **automatic reconnect** are separate
controls. Login startup is managed in Settings, not in `profiles.json`.
Changing a startup switch does not connect or disconnect the current session.
Do not invent additional JSON fields or a CLI for server CRUD.

Current source observes system sleep/wake only in normal mode. Sleep closes owned
SSH processes; wake resumes only active requested connections with automatic
reconnection enabled. Manually stopped or terminally failed connections stay stopped.
The remote server may still retain an old listener; do not describe this as a guarantee
of immediate recovery. Continuous forwarding retry is a separate default-off profile
choice, does not override authentication/host-key failures or initial port conflicts,
and stops when the user stops the tunnel. Neither feature changes the installed app
until an updated build is installed.

Fixed-entry mode uses the existing owned SSH master, a native Mac loopback gateway,
and the separately managed remote `experimental/fixed_entry/relay.py` helper.
Each transport receives a dynamic reverse port; the helper owns the fixed entry.
The app installs or starts a remote helper only through the explicit **安装并启用**
action on a stopped server. It uses the current SSH user's private
`~/.catunnel/fixed-entry/<port>/` directory, bundles its own Python scripts, and
requires Python 3.9+. It does not use sudo, edit SSH/shell/service settings, or
install missing dependencies. Success fills and enables only the editor draft.
Installation, verification, and connection control use its selected Python path.
If the server's default `python3` is too old, enter an existing Python 3.9+
executable's absolute path, or explicitly use **查找可用 Python** in the editor.
Discovery checks the entered interpreter, default paths, and common environments
with scope and timeout limits; it may not find every installation. Only **使用此 Python**
fills the draft, without saving or installing. Discovery and installation/setup checks
are mutually exclusive. This does not change system Python or activate a Conda environment. Old
profiles keep their existing behavior without a rewrite. Saving and connecting
remain explicit. Cancellation may leave a completed remote install;
retry checks the same managed helper without replacing it. Unknown files, occupied
ports, incompatible installs, and active leases are preserved and rejected.
No boot service is configured; after server reboot, explicitly use the action again
to start a clean stopped installation. Do not claim it reserves a port at the OS
level or provides Internet access while the Mac proxy is unavailable. The forwarding-conflict
continuous retry preference is ignored in fixed-entry mode. Ordinary setup diagnostics
cover basic dependencies; connection establishment checks the helper explicitly.
Preserve old configurations and running connections when building or testing this mode.

For profiles with fixed entry enabled, **检查固定入口** in the panel or connection
details explicitly checks local proxy TCP, SSH, selected Python, helper status,
entry listener, and active backend. It uses independent strict SSH, does not request
a lease, and is available while connected without changing the tunnel or settings.
Results have a last-check timestamp and passed/warning/failed/skipped states; do not
describe them as live status, end-to-end Internet access, or proof that a backend
belongs to this Mac. Closing the view or switching profiles cancels the local wait
and discards late results. Python discovery follows the same cancellation boundary;
do not promise that every remote probe stops immediately. Offline modes never run
these SSH checks.

Ping0 is now an explicit default-browser action, not part of network diagnostics.
Use a successful check's public exit IP when available, label historical IPs, and
open the homepage when no usable IP exists. The app no longer fetches or parses
Ping0 pages. The browser uses the Mac's network settings; offline demos do not open it.

## Launch and offline commands

Open the installed menu-bar app normally:

```sh
open -a CATunnel
```

This starts a new normal GUI process and requests an existing profile ID once.
It does not control a running instance or persist a startup preference; profiles
with `autoConnectOnLaunch` also connect. Only one normal instance can run. Do not
quit one to use this command without authorization to interrupt its tunnels.

```sh
/Applications/CATunnel.app/Contents/MacOS/CATunnel --connect-once server-a
```

The installed path may differ. For offline inspection, run these independently
in a logged-in macOS graphical session; close the demo before starting the UI check:

```sh
/Applications/CATunnel.app/Contents/MacOS/CATunnel --demo
```

```sh
catunnel_ui_dir="$(mktemp -d "${TMPDIR:-/tmp}/catunnel-ui.XXXXXX")"
/Applications/CATunnel.app/Contents/MacOS/CATunnel --ui-check "$catunnel_ui_dir/report.json"
```

Offline modes use in-memory examples without real tunnels or normal settings/login
item changes, and cannot combine with `--connect-once`.
`--preview /tmp/catunnel-panel.png` is another offline mode; run it separately
from `--ui-check`. These flags are not a headless daemon or remote management API.

## Verify and configure remote tools

After an authorized connection, run this **on the remote server**, adjusting the
port. It ignores `.curlrc`/`NO_PROXY`, verifies TLS, and sends no credentials:

```sh
curl -q --silent --show-error --noproxy '' \
  --proxy http://127.0.0.1:17892 --connect-timeout 8 --max-time 20 \
  --output /dev/null \
  --write-out 'CONNECT=%{http_connect} HTTP=%{http_code} TLS=%{ssl_verify_result}\n' \
  https://api.openai.com/v1/models
```

Successful curl exit with CONNECT `200`, TLS `0`, and API HTTP `401` establishes
transport reachability, not login, model access, or a successful agent request.
Claude trace does not prove browser challenge clearance; Net.Coffee scores are
third-party references, not access guarantees.

For a program supporting proxy environment variables, replace `your-command`:

```sh
env HTTP_PROXY=http://127.0.0.1:17892 HTTPS_PROXY=http://127.0.0.1:17892 \
  http_proxy=http://127.0.0.1:17892 https_proxy=http://127.0.0.1:17892 \
  your-command
```

Only that command and its children are affected; existing processes keep their
environment. Check whether `NO_PROXY`/`no_proxy` excludes the target; adjust only
this invocation's bypass list if necessary. Support varies by tool/version.
Persistent shell, service, `.codex`,
or `.claude` edits and process restarts need authorization covering that change.
Back up and retain working fallbacks until actual tool usage passes. Never bypass
TLS or SSH host-key checking, or kill unrelated background processes.

## Development reference

See [CONTRIBUTING.md](CONTRIBUTING.md) for builds/tests. Verify against `AppMain.swift`
(flags), `Models.swift`/`ServerConfiguration.swift` (profiles), `TunnelStore.swift`
(persistence), and `SSHCommands.swift`/`SetupDiagnostics.swift`/`WebsiteProbe.swift`
(connections/checks). Keep tests isolated from real environments.
