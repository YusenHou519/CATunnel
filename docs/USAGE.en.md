# CATunnel user guide

[Back to README](../README.en.md) · [简体中文](USAGE.md) · [Agent guide](../AGENTS.md)

CATunnel creates an SSH reverse tunnel from a Linux server to an existing HTTP proxy on your Mac.
It manages its own SSH connections; it does not provide a proxy or edit SSH, shell, editor, or remote-tool settings.
The current UI is in Chinese. See [validation boundaries](VALIDATION.md) for observed coverage.

## Download and install

1. Download a preview ZIP from [GitHub Releases](https://github.com/YusenHou519/CATunnel/releases):
   choose `arm64` for Apple Silicon or `x86_64` for Intel. Source archives and build-information JSON are optional.
2. Extract the ZIP, move `CATunnel.app` to Applications, and double-click it.
3. Click the circular two-arrow menu-bar icon to open the panel. There is no Dock icon or automatic main window.
4. Normal first launch has an empty list. Choose **Getting started** (`使用引导`) or **Add server** (`添加服务器`).

Preview packages are ad-hoc signed, without Developer ID signing or Apple notarization, and intended for developer evaluation.
If macOS cannot verify the developer or check the app for malicious software, first confirm that you trust the download source.
Then follow [Apple's instructions](https://support.apple.com/en-us/102445) to allow this specific app:

1. Try opening the app, then dismiss the blocking dialog with Done or Cancel.
2. Open **System Settings → Privacy & Security** and find the CATunnel notice under Security.
3. Choose **Open Anyway**, authenticate as requested, and confirm Open. Labels may vary between macOS versions.

If the button is absent, try opening the app again before returning to settings. Managed Macs may require an administrator.
There is no need to disable Gatekeeper system-wide. If the warning says the app is damaged, will damage your computer,
or contains malware, stop and report the exact message, macOS version, and archive name in an Issue.
Do not treat those warnings as an ordinary missing-notarization notice.

This general process has not yet been tested with a browser download on a fresh Mac/account.
Passing build, signature, and ZIP checks does not establish successful installation on every Mac;
see [installation validation limits](VALIDATION.md#clean-configuration-versus-a-clean-mac).

## Prepare the connection

- **Mac:** deployment target macOS 13+. Start an HTTP or HTTP-compatible mixed proxy listening on `127.0.0.1`.
  A SOCKS-only port cannot directly serve the HTTP proxy checks used here.
- **Server:** an accessible Linux OpenSSH server, with `ss` for listener checks and `curl` for network checks.
  SSH must permit reverse forwarding, and the chosen remote port must be available.
- **Authentication:** a verified host fingerprint in `known_hosts`, plus default keys, an available SSH agent, or a selected key.
  Load encrypted keys into the agent from a terminal before using the app's noninteractive connections.

CATunnel uses `-F /dev/null` and does not read `~/.ssh/config`. Enter the actual IPv4 address or resolvable hostname,
not an alias defined only in your SSH configuration. Jump hosts/`ProxyJump`, interactive passwords,
IPv6 SSH addresses, and in-app initial host trust are not currently supported.
The minimum deployment target is not a claim that every OS version or architecture has been tested.

## Add and manage servers

Choose **Add server** (`添加服务器`) or **+**, then complete the editor:

| Field | Meaning |
| --- | --- |
| Display name | Name shown in the server tab; short names make switching easier |
| Host, SSH user, SSH port | Actual SSH connection parameters; default SSH port `22` |
| Local proxy port | HTTP/mixed proxy port on the Mac, for example `7890` |
| Remote loopback port | Proxy entry for remote tools, for example `17892`; not exposed publicly |
| Identity file | Optional; defaults to standard keys/SSH agent; only its path is saved |

Ports above are examples, not requirements; use the values for your environment, within `1–65535`.
Identity paths may be absolute or start with `~/`. Selected keys must be readable and owner-only (`600` or `400`).
Offline demo `.example` hosts are placeholders and cannot establish real connections.

Before saving, click **Check setup** (`检查连接准备`). It checks:

1. Whether the Mac's local proxy port accepts TCP connections; this alone does not establish a working HTTP proxy.
2. Selected key metadata and permissions, without reading key contents.
3. Noninteractive SSH authentication with strict host-key verification.
4. Whether `ss` and `curl` are available on the server.

This probe executes a read-only dependency command, creates no reverse forward, reuses no other app's control connection,
and contacts no external website. Editing the form or closing it cancels the check and clears stale results.
Save the profile, then click **Connect** (`连接`). Saving alone never connects a server.

Unknown or changed host fingerprints block the connection. Copy the editor's terminal verification command,
independently verify the fingerprint, and run it yourself. That terminal command lets you confirm trust interactively;
CATunnel never automatically accepts fingerprints or edits `known_hosts`. Key contents and passphrases are not stored.

Stop a profile's connection and checks before editing or deleting it. Deletion asks for confirmation and removes only the local entry.
Other connections are preserved; deleting the last entry restores the empty list. Tabs scroll horizontally for larger lists.
Closing the panel leaves tunnels running; quitting the app stops connections it created. Width and font size are adjustable in Settings.

## Point remote tools at the tunnel

After connecting, copy the proxy address displayed in the panel. For a remote port of `17892`:

```text
Remote tool → http://127.0.0.1:17892 → SSH tunnel → Mac 127.0.0.1:7890 → Internet
```

First verify the proxy explicitly in a **terminal on the server**, replacing the port with your configured value:

```bash
curl -q --silent --show-error --noproxy '' \
  --proxy http://127.0.0.1:17892 --connect-timeout 8 --max-time 20 \
  --output /dev/null --write-out 'HTTP %{http_code}\n' \
  https://www.google.com/generate_204
```

Expect `HTTP 204`. This command ignores `.curlrc`, explicitly uses the given proxy, and changes no configuration files.
You can substitute an API endpoint from the table below; an unauthenticated HTTP 401 establishes reachability,
not successful login or model use.

For programs that support standard proxy environment variables, pass them to a single invocation:

```bash
env HTTP_PROXY=http://127.0.0.1:17892 HTTPS_PROXY=http://127.0.0.1:17892 \
  http_proxy=http://127.0.0.1:17892 https_proxy=http://127.0.0.1:17892 your-command
```

Replace `your-command` with the actual command. Supported variables and configuration methods vary by program;
check its documentation. Check whether existing `NO_PROXY`/`no_proxy` rules exclude the target service;
adjust only that invocation's environment if needed. Alternatively, set proxy variables in the current shell before starting the program.
This affects only future child processes of that shell, not existing processes. With authorization, configure a background
service through its actual launch mechanism and restart it, then verify a real request.
CATunnel does not edit `.codex`, `.claude`, or shell files. Network transport and account authentication need separate verification.

## Login startup, automatic connections, and reconnection

The panel's **Settings** (`设置`) page provides the first two controls; reconnection is configured in the server editor:

| Setting | Behavior |
| --- | --- |
| Launch at login (`登录时启动`) | Opens CATunnel after Mac login; does not decide which servers to connect |
| Connect on app startup (`启动后自动连接`) | Per-server choice for the next app launch; off for new and older profiles by default |
| Reconnect after interruption (`意外断开后自动重连`) | Restores an already requested connection; manually stopped servers stay stopped |

Changing startup connection preferences does not interrupt or rebuild an active tunnel. The server editor also exposes this option.
Login startup uses macOS login-item services. Settings reports pending approval and links to system settings when needed.
Keep the app in a stable location, normally Applications, before enabling it.

A recognized older CATunnel login item is inspected read-only. Only explicitly changing the switch backs up and handles that item;
unrecognized contents are preserved with an error. Opening Settings alone does not migrate login items.
These switches are included in preview packages starting with `v0.6.0-preview.2` (build 5).
Offline demo switches affect simulated state only, without login registration, normal settings changes, or server connections.

## Network checks and data

Checks run when requested and use the selected server's tunnel:

| Check | Endpoint | What it establishes |
| --- | --- | --- |
| OpenAI API | `https://api.openai.com/v1/models` | HTTPS reachability; unauthenticated 401 accepted |
| Claude network | `https://claude.ai/cdn-cgi/trace` | HTTPS reachability and public exit IP |
| Claude API | `https://api.anthropic.com/v1/models` | HTTPS reachability; unauthenticated 401 accepted |
| Google | `https://www.google.com/generate_204` | HTTPS reachability |
| Net.Coffee risk | `https://ip.net.coffee/api/iprisk/{ip}` | Third-party assessment of the Claude exit IP |

Net.Coffee is a per-server option, **off by default**. Enabling it sends the observed public exit IP to that service on the next check.
With it off, Claude's network trace still reports the exit IP; the assessment is skipped and Net.Coffee is not contacted.
No API keys, cookies, or model prompts are sent. There is no analytics or telemetry.
Third-party check failures do not stop established tunnels. Scores are **for reference only**, not a guarantee of account or model access.
Responses based on a containing network are labeled as cached network assessments, not exact-IP real-time measurements.
Claude's network check does not validate browser challenges on the Claude website. Third-party endpoints may change.

## Settings and logs

Local configuration is stored in:

```text
~/Library/Application Support/CATunnel/profiles.json
~/Library/Application Support/CATunnel/ui-preferences.json
```

The server document has the form `{"version": 1, "profiles": []}`. Prefer the UI and back up before editing;
do not edit the file while the app is running, as its in-memory configuration may conflict.
The legacy array format remains readable and is upgraded only on an explicit save.
Duplicate IDs and conflicting server/port entries are rejected. Missing `identityFile` uses default keys/agent;
missing `assessIPRisk` or `autoConnectOnLaunch` defaults to false. `autoReconnect` is stored separately.

Unreadable, invalid, or unsupported-version files produce an error and block writes, preserving the original file.
Correct the file and restart to reload it. A fresh launch alone does not create a server configuration file.
The bundle identifier is `local.catunnel.CATunnel`; settings from other apps are not imported.
SSH control sockets live in private temporary directories; recent logs and check results stay in memory.
Passwords, private keys, and API credentials are not saved.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Local proxy port unavailable | Proxy is running, port is correct, and HTTP/mixed mode is supported |
| Terminal SSH works, app fails | Terminal may rely on aliases, jump hosts, or SSH config; verify actual host, user, port, and agent |
| Unknown or changed host key | Verify the fingerprint independently before updating trust; do not disable host verification |
| Key authentication fails | Check key path, permissions, user, and agent; the app does not prompt for a password |
| Remote port occupied or forwarding refused | Choose an available loopback port or ask the administrator about SSH policy; do not kill unknown processes |
| Connected tunnel, unusable tool | Test with explicit `curl --proxy`, then check the program's proxy support, login state, and service permissions separately |
| No recovery after sleep | Check that the Mac, local proxy, and network are available; inspect reconnection settings and logs; stopped servers stay stopped |
| Configuration load error | Preserve and back up the file, repair its format/version, then restart; do not replace it with an empty configuration |

Remove credentials and private host details before filing an Issue. Build, demo, and test commands are in
[CONTRIBUTING.md](../CONTRIBUTING.md); agent operation boundaries are in [AGENTS.md](../AGENTS.md).
