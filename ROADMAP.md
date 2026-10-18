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
- GitHub Actions defines native macOS builds and archive verification; hosted
  execution remains to be observed after the source is published.
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
- Source publication, hosted CI, additional architectures, and minimum-OS runtime
  validation remain separate release gates.

## 6. Beta validation — clean extraction checked

- The extracted Apple Silicon preview passes offline UI checks with fresh,
  temporary settings. This is not a fresh macOS account or Gatekeeper trial.
- Still needed: a separate test account/Mac, a disposable Linux server, manual
  network-change and sleep/wake checks, and feedback from other users.
- Leave proxy migration to an explicit, separate decision by the user.

Later candidates: SSH aliases/jump hosts, login startup, automatic updates,
and a Homebrew installation path.
