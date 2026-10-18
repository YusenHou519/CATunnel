# CATunnel — Coding Agent Tunnel

[简体中文](README.zh-CN.md)

A lightweight native macOS menu-bar app that lets remote tools use a local
HTTP proxy through an SSH reverse tunnel.

```text
Remote tool → server loopback proxy port → SSH tunnel → Mac local proxy → Internet
```

## Development status

This is the standalone source preview of CATunnel 0.6.0 (build 4).
Local preview archives use an ad-hoc signature. They are not Developer ID signed
or notarized public releases.

Normal first launch starts with an empty server list. Add, edit, and delete your
own profiles; there is no fixed two-server limit. The offline demo alone starts
with example profiles **A** and **B**. Their `.example` hosts are placeholders,
and real connection attempts are rejected until the host is changed. The current
application interface is in Chinese.

The app manages its own SSH processes and settings. It does not configure remote
tools to use a proxy, modify SSH or shell configuration, or provide a proxy service
itself. A compatible local proxy must already be available.

## Requirements

- **Deployment target:** macOS 13 or later, with Xcode or Command Line Tools providing
  Swift 5.9 or later to build from source. The package has no external dependencies.
- **For a real connection:** a Linux SSH server with `ss` and `curl`, and a Mac
  HTTP proxy or HTTP-compatible mixed proxy port bound to loopback.
- **Authentication:** an existing trusted host entry in `known_hosts`, plus a
  default SSH key, an available SSH agent, or a selected identity file. SSH uses
  strict host-key checking. Encrypted keys must be available through the agent
  for the app's noninteractive connections.

The deployment target is not a claim that every supported OS/architecture has
been tested. See the [validation matrix](docs/VALIDATION.md) for observed results
and remaining checks.

SSH aliases, jump hosts, interactive passwords,
IPv6 SSH host addresses, and in-app host-fingerprint enrollment are not yet
supported. The app deliberately ignores `~/.ssh/config` for its owned connections.

## Build and check

From the repository root:

```bash
bash scripts/check.sh
bash scripts/build-app.sh
```

The first command runs the offline `TunnelCoreChecks` executable. This project
does not currently use `swift test`. The second command creates
`dist/CATunnel.app`, verifies its local ad-hoc signature, and does not launch it.
It builds for the current Mac architecture; this is not a universal binary.

To build a separate review copy without replacing `dist/CATunnel.app`:

```bash
CATUNNEL_OUTPUT_DIR="$PWD/verification/build" bash scripts/build-app.sh
```

Only if a restricted build environment cannot run SwiftPM's manifest sandbox,
use `CATUNNEL_DISABLE_SWIFTPM_SANDBOX=1` before these commands. Regular builds
retain SwiftPM's default sandbox behavior.

## Offline demo and UI checks

These commands require a logged-in macOS graphical session. They use simulated
states and do not create SSH connections or read/write normal app settings.

```bash
./dist/CATunnel.app/Contents/MacOS/CATunnel --demo
./dist/CATunnel.app/Contents/MacOS/CATunnel --ui-check "$PWD/verification/ui/report.json"
```

Run them separately. The UI check exits automatically and writes a JSON report
and rendered previews under `verification/`, which is excluded from Git. The
core checks also exercise short-lived local child processes and temporary files.

## Integration checks and preview archives

The explicit integration check starts disposable SSH services on loopback with
temporary keys and its own host-trust files. It does not connect to configured
servers or use a contributor's proxy. On macOS, a real listener-query adapter
replaces the Linux `ss` command in the fixture; Linux deployment still needs
separate validation.

```bash
bash scripts/check-integration.sh
bash scripts/package-release.sh
```

Packaging builds an independent preview under `verification/release/` and does
not replace `dist/CATunnel.app`. The release process and archive verification
commands are in [RELEASING.md](docs/RELEASING.md). GitHub Actions definitions build
and check the project; local success does not establish that a hosted CI run has
passed. Distribution and installation limitations are recorded in
[VALIDATION.md](docs/VALIDATION.md).

## Normal use

1. Launch `dist/CATunnel.app` and open the menu-bar panel.
2. Choose **Add server** (`添加服务器`) or the **+** button, and enter a display name,
   host, SSH user, SSH port, local proxy port, and remote loopback port. Select
   an identity file if you do not use the default keys or SSH agent.
3. Use **Check setup** (`检查连接准备`) in the editor, then save and start the tunnel.
   Run its website checks if desired.
4. Explicitly point your remote tool at the displayed proxy address to use it.

For example, a remote port of `17892` provides `http://127.0.0.1:17892` on that
server. Starting a tunnel does not change the environment of an existing shell
or configure Codex, Claude, or an editor. Adding, editing, or removing a server
does not edit remote `.codex` / `.claude` directories or remote shell files.

Changing or removing a profile requires stopping that profile's connection and
checks first. Deletion asks for confirmation and removes only the local profile.
Deleting the selected profile selects a neighboring profile; deleting the last
one returns to the empty list. Other profiles' connections and results are kept.

Each profile has independent connection state, logs, and checks. The top tabs
scroll horizontally when there are many servers. The panel
supports adjustable width and font size. Closing the panel keeps owned tunnels
running; quitting the app stops them. Automatic reconnection is available for
transient errors. Login startup is not configured.

## First-use guide and SSH setup

Open **Getting started** (`使用引导`) from the panel or server overview. The guide
explains preparing a local HTTP/mixed proxy, confirming SSH access, and pointing
remote programs at the tunnel's loopback address. It does not run commands or
edit remote application settings.

The editor's setup check is separate from the website checks. It runs only after
you click its button and reports:

- Whether `127.0.0.1` at the configured local proxy port accepts a TCP connection.
  An open port alone does not establish that it is a working HTTP proxy.
- Whether a selected identity file is accessible, using file metadata only.
- Whether strict, noninteractive SSH authentication succeeds.
- Whether `ss` and `curl` are available on the server.

The SSH setup probe executes a read-only dependency command, creates no reverse
forward or reusable control connection, and does not contact external websites.
Changing form fields or closing the editor cancels the check and clears stale
results. Saving never automatically connects a server.

Unknown or changed host fingerprints remain an error. Copy the editor's terminal
verification command, verify the fingerprint independently, and run it yourself
if you wish to establish trust. CATunnel never accepts a fingerprint or edits
`known_hosts` for you. For encrypted keys, load the selected key into your SSH
agent from a terminal before connecting. Only the file path is saved; key
contents and passphrases are never imported into CATunnel.

## Network checks and data

Checks run only when requested and use the selected server's tunnel:

| Check | Endpoint | What it establishes |
| --- | --- | --- |
| OpenAI API | `https://api.openai.com/v1/models` | HTTPS transport; an unauthenticated 401 is accepted |
| Claude network | `https://claude.ai/cdn-cgi/trace` | HTTPS reachability and the observed exit IP |
| Claude API | `https://api.anthropic.com/v1/models` | HTTPS transport; an unauthenticated 401 is accepted |
| Google | `https://www.google.com/generate_204` | HTTPS reachability |
| Net.Coffee risk | `https://ip.net.coffee/api/iprisk/{ip}` | Third-party assessment of the Claude exit IP |

Net.Coffee is an optional per-server setting, disabled by default. Enable it in
the server editor to include its request when you next run website checks. It
sends the observed public exit IP to that service. With the option off, Claude's
network trace still reports the exit IP, while the assessment is shown as skipped
and Net.Coffee is not contacted. No API keys, cookies, or model prompts are sent.
The app has no analytics or telemetry.
Third-party check failures do not stop an established SSH tunnel.

The score is **for reference only**, not a guarantee of account access or model
availability. Responses based on a containing network are labeled as cached
network assessments rather than exact-IP measurements. External endpoints may
change or become unavailable.

Settings are stored only in:

```text
~/Library/Application Support/CATunnel/profiles.json
~/Library/Application Support/CATunnel/ui-preferences.json
```

The development bundle identifier is `local.catunnel.CATunnel`. This standalone
project does not import settings from other applications. SSH control sockets
use private temporary directories; recent logs and check results stay in memory.
The app does not store passwords, private keys, or API credentials.

Server profiles are saved in a versioned JSON document:

```json
{"version": 1, "profiles": []}
```

The previous array format is still readable and is upgraded only when a profile
change is explicitly saved. Duplicate IDs and conflicting server/port entries
are rejected. Profiles missing `identityFile` use default keys/agent; profiles
missing `assessIPRisk` default to false. If the profile file is unreadable, invalid, or from an unsupported
version, the app shows an error and blocks profile writes, preserving the original
file. Correct the file and restart the app to load it again. A fresh launch alone
does not create a server configuration file.

## Project layout

```text
Sources/CATunnel/          Native menu panel, windows, preferences, lifecycle
Sources/TunnelCore/        SSH ownership, state, validation, connection checks
Tests/TunnelCoreTests/     Offline executable checks
Tests/TunnelIntegrationChecks/  Disposable local SSH integration checks
Resources/Info.plist       Application metadata
scripts/                  Build, local checks, and generated icon
docs/                     Release and validation instructions
```

Local outputs, machine settings, verification records, and backups are excluded
from the repository. See [CONTRIBUTING.md](CONTRIBUTING.md) for development
boundaries and [ROADMAP.md](ROADMAP.md) for the remaining release work.

## License and acknowledgments

[MIT](LICENSE). See [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md) for design references.
