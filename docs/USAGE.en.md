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
  SSH must permit reverse forwarding; the default direct mode requires the chosen remote port to be available.
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

## Experimental fixed entry (off by default)

The current source adds **Fixed entry mode** (`固定入口模式（实验性）`) below the port fields in the server editor.
New and older profiles default to off and continue using the existing direct SSH forwarding path.
Stop that profile before editing its connection settings. Saving does not connect or install a remote service.

The **Install and enable** (`安装并启用`) button is available even when this mode is off.
It uses the current SSH account to install the bundled helper under
`~/.catunnel/fixed-entry/<port>/` and start it in the background. Python 3.9+ must already be
installed on the server. No administrator access, dependency download, or SSH server policy change is used.
If the default `python3` is too old, enter an existing Python 3.9+ executable's absolute path in
**Remote Python path (optional)** (`远端 Python 路径（可选）`), for example `/opt/tools/bin/python3`.
This is a path on the server, not the Mac. Leave it empty to keep using `python3`; `~/` expansion and
shell commands such as `conda activate` are not supported. Installation, verification, and all later
fixed-entry connection, renewal, and release requests use the same choice. It does not change system
Python, PATH, or other environments. This field is available with the mode off; old profiles are not rewritten.

Alternatively, click **Find available Python** (`查找可用 Python`) to check the entered path, default paths,
and common environments over an independent SSH session. The list shows absolute paths, versions, and compatibility;
older versions remain visible but cannot be selected. **Use this Python** (`使用此 Python`) only fills the current form,
without saving, installing, or connecting. Discovery has scope and timeout limits; an unlisted interpreter may still exist
and can be entered manually. Discovery, installation, and setup checks cannot run at the same time. Cancelling or closing the editor
stops the local wait and discards late results. It does not install or upgrade Python or activate environments.

After installation and verification through a second SSH session, the editor fills in the helper's paths and enables the draft's toggle.
You must still save the profile and connect. Closing the editor does not save these draft changes.
Repeated installation reuses a matching idle helper without restarting it; an active entry, occupied port,
or unrecognized installation is rejected without taking over another connection.
Cancel stops the local installation wait. The remote step may already have finished; retrying checks for
and reuses that installation rather than deleting it.

When enabled, provide absolute remote paths for the helper and its private runtime directory.
A compatible [relay.py](../experimental/fixed_entry/relay.py) must already run on the server using Python 3.9+,
under the SSH account, with an owned `0700` runtime directory and the configured remote proxy entry port.
You can use the installation button to prepare it or supply a manually installed helper. Existing default keys,
SSH agent use, and strict host-key verification are preserved. The Mac implementation is native Swift and needs no Python.

The helper keeps the entry open while each SSH connection receives its own temporary reverse port.
The app switches the route only after verifying the new gateway and a listening local proxy.
An old SSH session can retain its temporary port without blocking the new connection; no old process is killed.
A missing helper, unsafe runtime, or mismatched entry port fails explicitly; port mismatch is rejected before takeover.
The ordinary setup check still covers only basic dependencies; connection establishment verifies the helper and channel.

For a saved profile with fixed entry enabled, the panel and connection details provide **Check fixed entry** (`检查固定入口`).
An independent SSH session checks the local proxy TCP port, SSH, selected Python, helper, fixed entry, and active backend.
This is available while connected and does not reuse or stop the tunnel, install, reconnect, request a lease, or change settings.
Results show the last-check time and distinguish passed, warning, failed, and skipped items; they are not live status.
A listener does not establish HTTP proxy or Internet access. An active backend may belong to another session,
and the absence of a backend is reported explicitly. Closing the view or switching servers stops the local check
and discards late results while leaving the connection running.

Recovery obeys the profile's automatic-reconnect choice. Manual stop closes owned resources and attempts to release
only its lease. Delayed messages or wake recovery cannot reclaim an entry already taken over by a newer session.
Ambiguous ownership stops recovery and requires an explicit reconnect. Continuous forwarding-conflict retry applies
only to direct mode; its stored setting is hidden and ignored in fixed-entry mode.

An open entry cannot provide Internet access while the Mac is asleep, and existing TCP requests do not migrate.
Installation does not configure boot startup or a supervisor. After a clean server shutdown, use the button
again to start the matching helper. Residual files after forced termination require separate inspection.
This feature does not claim real Linux deployment or physical sleep/wake validation.
See the [experiment guide](../experimental/fixed_entry/README.md) for isolated checks.

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
| Keep retrying an occupied port (`端口占用时持续重试`) | New in current source and off by default; requires automatic reconnection and a previously established connection |

Changing startup connection preferences does not interrupt or rebuild an active tunnel. The server editor also exposes this option.
Login startup uses macOS login-item services. Settings reports pending approval and links to system settings when needed.
Keep the app in a stable location, normally Applications, before enabling it.

A recognized older CATunnel login item is inspected read-only. Only explicitly changing the switch backs up and handles that item;
unrecognized contents are preserved with an error. Opening Settings alone does not migrate login items.
Login and startup-connection switches are included in preview packages starting with `v0.6.0-preview.2` (build 5).
Offline demo switches affect simulated state only, without login registration, normal settings changes, or server connections.

The current source adds sleep handling and continuous recovery; these changes are not included in that download.
On a system sleep notification, CATunnel closes its owned SSH processes. Wake resumes only servers that were still requested
and had automatic reconnection enabled before sleep. Manually stopped servers, exhausted retries, and servers with automatic
reconnection disabled remain stopped. Connection requests made during sleep wait for wake only when automatic reconnection is enabled;
otherwise, connect manually after wake.
The remote server may retain an old listener; these changes do not guarantee immediate recovery.

After a previously established connection is lost, forwarding conflicts normally retry after 15, 30, 60, 60, and 60 seconds, then stop.
Enabling continuous retry adds one attempt every 60 seconds after that budget, until recovery or a manual stop.
The preference is saved in the server editor for the next connection; it is disabled and has no effect when automatic reconnection is off.
It does not make initial port conflicts, authentication failures, or host-key failures retry indefinitely. SSH forwarding rejection
can also indicate server policy, so inspect the logs.

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

The current source replaces the **Ping0** check with a browser button, not included in the `v0.6.0-preview.2` download.
Only clicking it opens the default browser. A public exit IP from a successful check opens `https://ping0.cc/ip/{ip}`;
historical results are labeled as the last observed exit IP. Without a usable IP, it opens `https://ping0.cc/`.
Read IP type, risk, and shared-user information on the website. The app no longer queries, parses, or caches Ping0 results
and has no option to enable its former check. The browser uses the Mac's network settings rather than sending a lookup
through the selected server's tunnel. Offline demos do not open a browser. See [Ping0's field definitions](https://ping0.cc/ip/faq).

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
missing `assessIPRisk`, `autoConnectOnLaunch`, or `keepRetryingForwardingFailure` defaults to false. `autoReconnect` is stored separately.
The legacy `assessPing0` field remains readable and preserved but no longer triggers a check; no manual migration is needed.

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
| No recovery after sleep | Check the Mac, local proxy, network, and reconnection logs; an old server session may still hold the port; stopped servers stay stopped |
| Configuration load error | Preserve and back up the file, repair its format/version, then restart; do not replace it with an empty configuration |

Remove credentials and private host details before filing an Issue. Build, demo, and test commands are in
[CONTRIBUTING.md](../CONTRIBUTING.md); agent operation boundaries are in [AGENTS.md](../AGENTS.md).
