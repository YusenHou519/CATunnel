# Contributing

Keep changes small and separate tunnel ownership, network diagnostics, and UI
presentation. Follow the build instructions in the README.

- Run `bash scripts/check.sh` for core changes and `bash scripts/build-app.sh`
  for application changes. UI checks require a logged-in macOS graphical session.
- Use documentation addresses and `.example` domains in fixtures. Do not add
  personal server settings, logs, screenshots of real connections, or credentials.
- Keep default checks offline. Real SSH validation must be explicitly configured
  and must operate only on test connections created for that validation.
  `bash scripts/check-integration.sh` creates such a disposable loopback fixture;
  see [validation](docs/VALIDATION.md) for its platform scope.
- Preserve strict SSH host-key and TLS verification. Only terminate child
  processes owned by this application. Do not change system or remote proxy settings.
- Distinguish SSH state, HTTP transport, IP assessments, and actual application
  access. Do not infer account or model access from an unauthenticated HTTP response.
- Do not add telemetry or silently enable new external requests. Document each
  diagnostic endpoint and the data it receives.

The repository includes dynamic profiles and offline application checks. Keep
setup diagnostics opt-in and test subprocess behavior using temporary fixtures
or injected results. Never use a contributor's real SSH hosts, keys, or proxy to
make the default checks pass. See [ROADMAP.md](ROADMAP.md) for remaining work.
For packaging and artifact verification, follow [RELEASING.md](docs/RELEASING.md).
