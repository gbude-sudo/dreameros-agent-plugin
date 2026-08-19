# DreamerOS Desktop Agent

Status: Phase 1 foundation. Not released to customers.

This package is the per-user runtime that will turn DreamerOS desktop
onboarding into one browser sign-in and automatic vendor configuration.

Current implemented foundation:

- OAuth public-client PKCE and state helpers
- Ed25519 release-manifest verification
- SHA-256 artifact verification
- Windows Credential Manager token vault
- Claude, Codex, and Cursor detection and configuration adapters
- atomic writes with backups
- conflict refusal for malformed or unmanaged configuration
- privacy-bounded heartbeat payloads
- status, repair, and sign-out CLI commands

Held back until the matching Gateway runtime ships:

- live browser callback and token exchange
- installation registration and heartbeat calls
- connection receipt
- signed release publication
- frozen executable and Authenticode-signed installer
- automatic update and rollback

The production agent must never place OAuth access tokens, refresh tokens, or
client secrets in vendor configuration files. Tokens belong only in the OS
credential vault.
