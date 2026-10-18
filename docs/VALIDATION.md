# Validation boundaries

CATunnel separates offline behavior checks, artifact inspection, isolated SSH
integration, and manual release trials. A passing result at one layer does not
establish the others.

## Startup-settings validation — 2026-10-19

Native login-item management and per-server startup preferences are included in
`v0.6.0-preview.2` (build 5). The following offline results were recorded earlier
against a separate Apple Silicon build 4 bundle containing those source changes,
without replacing the installed copy during validation. They are not a test of
the exact build 5 release archives; see the
[preview.2 release notes](https://github.com/YusenHou519/CATunnel/releases/tag/v0.6.0-preview.2)
for evidence tied to those artifacts.

- Offline core checks: **40 / 40**, including old-profile compatibility and the
  independence of startup connection preferences from automatic reconnection.
- Offline app checks: **119 / 119**, including startup selection, persistence and
  write failure, connected-session preservation, login-item registration errors,
  approval states, legacy-item preservation/backups, and narrow/large-font layouts.
- Login-item checks use injected backends and temporary home directories. They
  never register/unregister a real login item or unload a live LaunchAgent.
- The running app, its tunnels, installed bundle, and existing proxy/login
  configuration were preserved during this validation.

Evidence is generated locally under `verification/startup-settings/` and is not
committed. Run the independent build and offline check with:

```bash
CATUNNEL_OUTPUT_DIR="$PWD/verification/startup-settings/build" bash scripts/build-app.sh
./verification/startup-settings/build/CATunnel.app/Contents/MacOS/CATunnel \
  --ui-check "$PWD/verification/startup-settings/ui/report.json"
```

Actual ServiceManagement registration/approval and a subsequent macOS login
with selected servers are still manual acceptance checks. Passing the fixtures
does not establish those system interactions on every supported macOS version.

The startup-settings source commit, `81ed4bc`, also passed
[both hosted architecture jobs](https://github.com/YusenHou519/CATunnel/actions/runs/39147684302)
on Apple Silicon and Intel, including core checks, isolated SSH checks, native
packaging, and archive verification. This run predates the build 5 version bump;
it does not establish graphical Intel use, real login-item registration, or
clean-Mac installation of the new release archives.

## Recorded preview validation — 2026-10-18

The following results apply to **CATunnel 0.6.0, build 4**, built and run on
**macOS 26.2 / Apple Silicon (arm64)**. The preview has an ad-hoc signature;
Developer ID signing and notarization have not been completed.

| Validation | Recorded result | Scope |
| --- | --- | --- |
| Offline core checks | 39 / 39 passed | Temporary files and local process fixtures |
| Unsafe ZIP rejection checks | 11 / 11 passed | Traversal, invalid roots, symlinks, special files, permissions, duplicate paths, and missing files |
| Packaged app inspection | Passed | ZIP structure, bundle version, arm64 architecture, deployment target, signature, library locations, and personal build-path removal |
| Extracted app offline UI | 92 / 92 passed | Actual release executable, temporary extraction, simulated states and isolated settings |
| Verification cleanup | Passed | UI process exited and temporary extraction was removed |
| Isolated real SSH integration | 18 / 18 passed | Two disposable macOS SSH servers, real forwarding, strict trust checks, reconnect, injected diagnostic failures, and cleanup |
| Failed integration-run cleanup | Passed | Deliberately failed runner exits nonzero; fixture listeners, SSH clients, and temporary keys are removed |
| Linux SSH server integration | Pending | Requires a disposable Linux server trial |
| Intel graphical app runtime | Pending | Headless core/SSH checks and native packaging pass in hosted CI below; Intel GUI use has not been tested |
| Minimum macOS 13 runtime | Pending | The declared deployment target is 13.0; this is not a macOS 13 trial |
| New macOS account and downloaded-app Gatekeeper flow | Pending | Temporary extraction does not reproduce a fresh account or download quarantine |
| Physical sleep/wake and network switching | Pending | No disruptive host power or network changes were performed |
| Public diagnostic services and model/account access | Pending | Offline validation made no real SSH connections or proxy requests |

The local, Git-ignored evidence is stored at:

```text
verification/release/extracted-app-trial/release-verification.json
verification/release/extracted-app-trial/ui/report.json
verification/release-checkpoint/CATunnel-0.6.0-build4-macos-arm64-preview/RELEASE.json
verification/release/integration/report.json
verification/release/integration/failure-path.json
```

To repeat the extracted-package trial, use a new report directory:

```bash
bash scripts/verify-release.sh \
  "$PWD/verification/release-checkpoint/CATunnel-0.6.0-build4-macos-arm64-preview/CATunnel-0.6.0-build4-macos-arm64-preview.zip" \
  "$PWD/verification/extracted-app-repeat" --ui-check
```

The source checkout does not contain these generated artifacts. From a fresh
checkout, set `CATUNNEL_RELEASE_DIR="$PWD/verification/release-checkpoint"` when
running `bash scripts/package-release.sh` to reproduce the archive location.

## Hosted GitHub Actions validation — 2026-10-18

The first public source commit, `f0215fc`, passed
[both jobs in GitHub Actions](https://github.com/YusenHou519/CATunnel/actions/runs/39124655875).
The downloaded SSH reports record macOS **15.7.9** on both hosted architectures.

| Architecture | Core checks | Archive rejection checks | Real SSH fixture | Native preview and extraction |
| --- | --- | --- | --- | --- |
| Apple Silicon / arm64 | 39 / 39 | 11 / 11 | 18 / 18 | Passed |
| Intel / x86_64 | 39 / 39 | 11 / 11 | 18 / 18 | Passed |

Each job uploads its SSH report and an ad-hoc-signed native preview with release
metadata and the archive verification report. Both SSH reports confirm temporary
fixture removal. These jobs run no graphical UI checks, no public diagnostic
requests, and no Linux server tests. They do not establish macOS 13 compatibility,
Gatekeeper acceptance, notarization, or everyday GUI use on Intel.

See the [workflow](https://github.com/YusenHou519/CATunnel/actions/workflows/validate.yml)
for the result on newer commits; this table records the linked run specifically.

## Offline core and UI checks

From a source checkout on macOS:

```bash
bash scripts/check.sh
CATUNNEL_OUTPUT_DIR="$PWD/verification/review-build" bash scripts/build-app.sh
./verification/review-build/CATunnel.app/Contents/MacOS/CATunnel \
  --ui-check "$PWD/verification/review-ui/report.json"
```

Use a new output directory for each review. The core checks run temporary file
and child-process fixtures; they do not contact a server. The UI command requires
a logged-in macOS graphical session and exits on completion. It uses simulated
connection states and injected temporary settings directories. It tests fresh
empty configuration, profile add/edit/delete and reload behavior, error handling,
preferences, setup guidance, and rendered layouts. The report records the checks
and confirms that no real SSH connections or proxy requests were made.

The `--ui-check` path skips the normal application instance lock and does not
read or write the real application settings. The generated screenshots and JSON
reports are local evidence under the ignored `verification/` directory.

## Isolated real SSH checks

```bash
bash scripts/check-integration.sh --output "$PWD/verification/integration/report.json"
```

The fixture starts two unprivileged system `sshd` processes on ephemeral loopback
ports. It generates temporary client/server keys in a private user temporary
directory, keeps strict host-key checking and server `StrictModes` enabled, and
uses separate trust files without accessing the user's SSH agent or settings.
It requires macOS, system OpenSSH, `lsof`, Python 3, and permission to open local
sockets. An unavailable prerequisite fails the check rather than reporting a pass.

The application controller establishes the real reverse forwards. Checks compare
exact bytes from local HTTP fixtures, stop/restart one connection while the other
continues, exercise occupied ports and rejected keys, and close an owned master
to observe automatic reconnection. Unknown and changed host keys are rejected
without altering the temporary trust files.

The macOS fixture queries actual listeners with `lsof` and adapts its output to
the format expected from Linux `ss`. For diagnostic failure tests, the fixture's
SSH command allowlist returns a synthetic Claude trace and service-error
responses; it does not execute public HTTP requests. This checks that failed
diagnostics leave established tunnels working, without claiming public service
availability. The fixture verifies listener/process cleanup and removes its
temporary keys even when the test runner fails.

## Inspect and run an extracted release

After packaging, use the actual archive path printed by the packaging command:

```bash
bash scripts/verify-release.sh /path/to/CATunnel-release.zip \
  "$PWD/verification/package-inspection"
```

This validates ZIP paths, permissions and size bounds before extracting into a
new temporary directory. It rejects symlinks, special files, path traversal,
duplicate paths, and unexpected archive roots. It verifies required bundle files,
version metadata, architecture, library locations, code signature, and absence
of personal build-directory paths in the executable. A sibling `RELEASE.json`,
if present, must match the bundle metadata. Temporary extraction is removed
after the check. No checksum file is required or created.

The verifier's archive rejection fixtures are reproducible with
`bash scripts/check-release-verifier.sh`. They create temporary malformed ZIPs
and assert that each is rejected before extraction.

To run the extracted app's offline UI checks as well:

```bash
bash scripts/verify-release.sh /path/to/CATunnel-release.zip \
  "$PWD/verification/extracted-app-trial" --ui-check
```

The report folder must not contain a previous `release-verification.json`.
The application is executed directly from the temporary extraction directory,
avoiding Launch Services selecting an already installed copy. It is not copied
to `/Applications`; the normal app mode is not launched. The report and UI
screenshots are retained in the requested report directory.

The verifier does not establish the publisher's identity or assess Gatekeeper
acceptance. A valid ad-hoc signature is suitable for a development preview but
does not mean Developer ID signing or Apple notarization. Release metadata is
descriptive and is not an authenticated provenance record.

## Clean configuration versus a clean Mac

Temporary extraction plus injected empty settings verifies that the bundle can
run away from its build directory and that app behavior is independent of saved
profiles. It does **not** reproduce a newly created macOS account, a separate Mac,
browser download quarantine, a fresh Keychain, missing development tools, or
every supported operating system version.

Before describing a public build as broadly verified, perform a manual trial on
a separate test account or Mac:

1. Download the intended release and record its version, build, architecture,
   macOS version, signature type, and any Gatekeeper result. Do not disable
   Gatekeeper globally to make a trial pass.
2. Open the app and confirm an empty server list and first-use guidance.
3. Add a disposable Linux SSH server using an independently verified host key,
   a dedicated key, and an already running local HTTP proxy. Confirm that saving
   alone makes no connection and leaves shell and SSH configuration unchanged.
4. Connect, verify the remote listener is loopback-only, and send a harmless
   request through the tunnel. Exercise independent profiles, occupied ports,
   rejected authentication, connection loss and reconnection.
5. Check sleep/wake and network changes on the test Mac, then quit the app and
   verify only its owned SSH processes and forwards stop.
6. Remove the disposable profile, quit, reopen, and confirm the empty list.
   Record failures with redacted logs and exact reproduction steps.

Do not perform sleep/wake or destructive network trials on a Mac that is hosting
someone's active work. An isolated local test cannot establish live third-party
API availability or account access. Network and Net.Coffee checks are separate,
user-triggered actions.

The deployment target in `Info.plist` is a build setting, not evidence of a
successful trial on that minimum macOS version. Each architecture and operating
system combination needs its own recorded result before support is claimed.
