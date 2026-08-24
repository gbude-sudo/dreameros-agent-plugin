# DreamerOS Desktop Agent

Status: Implemented locally. Not published or verified on clean customer machines.

This package is the per-user runtime that will turn DreamerOS desktop
onboarding into one browser sign-in and automatic vendor configuration.

Current local implementation:

- OAuth public-client PKCE and state helpers
- Ed25519 release-manifest verification
- SHA-256 artifact verification
- Windows Credential Manager token vault
- Claude, Codex, and Cursor detection and configuration adapters
- atomic writes with backups
- conflict refusal for malformed or unmanaged configuration
- privacy-bounded heartbeat payloads
- status, repair, and sign-out CLI commands
- browser OAuth, public-client registration, and installation registration
- loopback MCP proxy and Gateway heartbeat
- per-user autostart renderers for Windows, macOS, and Linux
- signed manifest, artifact hash, and platform signature checks
- candidate and protected stable release workflow
- pending-update recovery state and truthful rollback outcomes
- automatic update checks disabled by default until clean-machine recovery passes

Held back before a customer release:

- GitHub release environment and the required signing values
- signed Windows x86_64, macOS arm64, and Linux x86_64 artifacts
- Gateway release registry values and live endpoint readback
- clean-machine install, sign-in, reboot, update, rollback, and uninstall tests
- a stranger install-to-authenticated-MCP-to-receipt walk

The production agent must never place OAuth access tokens, refresh tokens, or
client secrets in vendor configuration files. Tokens belong only in the OS
credential vault.
