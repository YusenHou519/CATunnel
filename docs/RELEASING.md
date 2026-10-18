# Preparing a release

CATunnel 0.6.0 is in development. The default output is an **ad-hoc-signed
preview**, not a notarized public release. Packaging never launches an app,
installs it, changes its preferences, or opens an SSH connection.

## Build and archive

Use a macOS source checkout with the build requirements described in the README:

```bash
bash scripts/check.sh
bash scripts/package-release.sh
```

The script reads version and build numbers from `Resources/Info.plist`, builds
the native architecture, verifies the signature, and creates an isolated
directory under `verification/release/`. For example:

```text
CATunnel-0.6.0-build4-macos-arm64-preview/
  CATunnel.app/
  CATunnel-0.6.0-build4-macos-arm64-preview.zip
  RELEASE.json
```

`RELEASE.json` records the inspected binary architecture, signing state, source
commit and working-tree state, toolchain, and declared deployment target. It
does not claim the OS target or other architectures have been tested. An initial
checkout without a commit records `source.commit` as `null`; this is unsuitable
for a traceable public release.

The script refuses to overwrite an existing release directory. For another
development run, choose a new parent:

```bash
CATUNNEL_RELEASE_DIR="$PWD/verification/release-review-2" \
  bash scripts/package-release.sh
```

This does not replace `dist/CATunnel.app`. `CATUNNEL_OUTPUT_DIR` remains available
for ordinary application builds, while release packaging always supplies its
own staging path. `CATUNNEL_EXPECT_ARCH=arm64` or `x86_64` can assert the expected
native architecture; the script does not produce or claim a universal binary.

This is a repeatable build pipeline, not a promise of byte-identical ZIPs across
toolchains: ZIP timestamps, compiler versions, signing, and notarization can
change bytes.

## Verify the exact artifact

From the produced release directory:

```bash
codesign --verify --deep --strict CATunnel.app
```

Also run the clean extraction verifier described in [VALIDATION.md](VALIDATION.md)
against the ZIP itself. GUI tests require a logged-in graphical session. Keep
the results with that exact ZIP; a source build or an ad-hoc signature
alone does not establish a successful installation under Gatekeeper.

## Optional Developer ID signing and notarization

Default preview builds need no distribution credentials and make no Apple
notarization request. A maintainer who already has a Developer ID Application
identity in Keychain may explicitly choose it:

```bash
CATUNNEL_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  bash scripts/package-release.sh
```

This enables hardened runtime and a timestamp. The archive is still labeled
`preview` until notarization succeeds. It does not create or import a certificate.

If the maintainer has separately configured a `notarytool` Keychain profile,
setting `CATUNNEL_NOTARY_PROFILE` explicitly authorizes uploading the signed app
to Apple for notarization:

```bash
CATUNNEL_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
CATUNNEL_NOTARY_PROFILE='catunnel-notary' \
  bash scripts/package-release.sh
```

The script waits for `Accepted`, staples the ticket, validates it, and runs
Gatekeeper assessment before emitting an archive labeled `notarized`. Failed or
unavailable signing/notarization does not produce a completed release directory.
Keep credentials in Keychain or a separately secured CI setup; never commit
certificates, passwords, API keys, or profile contents. The provided workflow
does not configure secrets or perform notarization.

## CI and publication

`.github/workflows/validate.yml` runs offline core checks, release-verifier
rejection checks, and isolated real SSH checks. It packages each native
architecture on separate macOS 15 runners and verifies clean ZIP extraction
without launching the app. It uploads short-lived **preview artifacts**, not
GitHub Releases. SSH reports are also uploaded when a test fails, if a report
was produced; temporary fixture keys are never uploaded.

The SSH fixture starts disposable loopback-only macOS `sshd` processes with
temporary keys and a private trust store. It needs the system OpenSSH tools,
`lsof`, and Python 3, but no `sudo`, existing SSH credentials, or developer proxy.
An unavailable prerequisite or restricted runner fails the check rather than
reporting success. This tests real SSH transport with a macOS listener adapter;
it does not validate Linux `ss`, Clash, public APIs, or physical sleep/wake.

Runner labels follow the
[GitHub-hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
The first public source commit passed both hosted architecture jobs on macOS
15.7.9; see [the recorded run and scope](VALIDATION.md#hosted-github-actions-validation--2026-10-18).
Check the workflow result for the exact commit being distributed. Hosted checks
do not include graphical app use, a clean-Mac installation, or notarization.

Before a public release:

1. Validate the clean extracted artifact and the SSH integration fixture. Record
   actual architecture/OS coverage and any manual sleep/wake checks separately.
2. Verify the source contains no local profiles, private hosts, keys, logs, or
   personal screenshots. Commit the reviewed source and rebuild from that commit
   with a clean working tree so the metadata identifies the released source.
3. Update `CFBundleShortVersionString` and increment `CFBundleVersion` for changed
   distributions, preserving the existing application identifier/settings path.
4. For ordinary end-user installation, use Developer ID signing and notarization
   and test the downloaded, quarantined archive on a clean Mac/user environment.
5. Publish the ZIP and `RELEASE.json` together with the exact source
   tag, scope of testing, and known limitations. Publishing is a separate action;
   these scripts do not create a repository, commit, tag, push, or release.

Do not advertise Intel, a minimum macOS runtime, universal binaries, Gatekeeper
acceptance, or completed hosted CI solely because the source can target them.
English UI localization, login startup, auto-updates, and Homebrew distribution
remain follow-up work.
