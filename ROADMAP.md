# Roadmap

## 1. Standalone source foundation — implemented

- Separate project, application identity, settings directory, and instance lock.
- Neutral example profiles and offline fixtures.
- Local build and check scripts, MIT license, and portable documentation.
- No automatic import of settings or changes to remote application proxies.

## 2. General-purpose server profiles — implemented

- Empty first-run state and arbitrary profile creation/deletion.
- Editable display names, horizontally scrolling server tabs, and a multi-server overview.
- Versioned configuration and clear invalid-file recovery.
- Legacy-array compatibility, profile deletion confirmation, and preservation of other connections.

## 3. First-use experience — setup flow implemented

- First-use guide and explicit local proxy / SSH / remote dependency checks.
- Identity-file selection and guidance for host fingerprints and encrypted keys.
- Optional Net.Coffee assessment, off by default, and documented service limits.
- Remaining follow-up: English UI localization (current interface is Chinese).

## 4. Repeatable validation — infrastructure implemented

- Offline core checks and archive-verifier rejection cases pass locally.
- GitHub Actions passed core, SSH, archive, and native build checks on macOS
  15.7.9 for arm64 and x86_64. The recorded run is linked in the validation notes.
- A disposable local SSH integration harness uses temporary keys and isolated
  trust files. See [VALIDATION.md](docs/VALIDATION.md) for its observed results.
- Real Linux deployment and physical sleep/wake trials remain manual acceptance
  work. Controlled service failures do not establish public API availability.

## 5. Distribution — preview packaging implemented

- Versioned native-architecture ZIP archives and release metadata, with no
  checksum-file requirement.
- Clean extraction, bundle signature, architecture, and deployment-target checks.
- Optional Developer ID signing/notarization hooks; credentials and a real
  notarized distribution are still pending.
- Source is public on GitHub, with native arm64 and x86_64 CI preview artifacts.
  Minimum-OS runtime validation and broader graphical app trials remain pending.

## 6. Beta validation — clean extraction checked

- The extracted Apple Silicon preview passes offline UI checks with fresh,
  temporary settings. This is not a fresh macOS account or Gatekeeper trial.
- Still needed: a separate test account/Mac, a disposable Linux server, manual
  network-change and sleep/wake checks, and feedback from other users.
- Leave proxy migration to an explicit, separate decision by the user.

## 7. Startup preferences — included in v0.6.0-preview.2

- Separate app login startup and per-server automatic connection preferences.
- Existing profiles stay manual by default; changing a startup preference leaves
  active tunnels intact. Offline mode simulates these switches without system changes.
- Real macOS login registration and a subsequent logout/login remain manual
  acceptance checks; fixture tests do not substitute for that trial.

Later candidates: SSH aliases/jump hosts, automatic updates,
and a Homebrew installation path.
