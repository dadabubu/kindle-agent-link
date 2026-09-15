# Security Policy

## Reporting

Please open a private security advisory (or contact the maintainers directly)
instead of filing a public issue for anything that could expose credentials,
bypass authentication, or allow unauthenticated writes.

## Threat model

The relay is meant to run on infrastructure you control. It exposes:

- one bearer-token scope shared by the device and your agent,
- size-limited endpoints (JSON bodies 4–512 KiB, uploads 64 MiB),
- no multi-tenant isolation — anyone holding your token can read and write
  your reading data.

Run it behind TLS (a reverse proxy or a tunnel). Do not expose it to the
public internet without HTTPS, and rotate the token if it leaks.

## Handling secrets

- Tokens live in the plugin's KOReader settings file (on the device) and in
  the relay's environment or config file (on the server). Never in the repo.
- `scripts/privacy-scan` is run before every release to catch committed
  credentials and private paths; see `docs/http-contract.md` for the exact
  checks and their output.
- Reply texts, selections and notes are user content: the relay stores them
  in a local SQLite database only. There is no telemetry anywhere in this
  repository.
