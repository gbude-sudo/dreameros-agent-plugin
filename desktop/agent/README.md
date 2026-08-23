# DreamerOS Desktop Agent

The desktop agent is a per-user lifecycle manager and a loopback MCP proxy for
Claude, Codex, and Cursor on Windows, macOS, and Linux.

Vendor configuration contains one URL only:

```text
http://127.0.0.1:18765/mcp
```

OAuth access and refresh tokens are stored only in Windows Credential Manager,
macOS Keychain, or Linux Secret Service. The agent fails closed if the platform
vault is unavailable. It never puts a bearer token in a vendor config or local
state file.

## Commands

- `dreameros-agent install` installs per-user autostart, repairs detected clients,
  and starts browser OAuth when no token exists.
- `dreameros-agent connect` performs OAuth discovery, public DCR, S256 PKCE,
  loopback callback validation, token exchange, and installation registration.
- `dreameros-agent run [--once]` runs repair, proxy, refresh, and heartbeat.
- `dreameros-agent status`, `repair`, `update`, `rollback`, and `sign-out` provide
  bounded lifecycle operations.

The proxy binds only `127.0.0.1:18765`, exposes `/health`, forwards `/mcp` to
`https://mcp.dreameros.app/mcp`, and injects the vault bearer plus the
`X-DreamerOS-Installation` UUID. It does not log request bodies or headers.

## Local checks

```text
python -m pip install -e desktop/agent
python -m unittest discover -s desktop/agent/tests -v
```

Stable updates require an Ed25519-signed release manifest, a matching SHA-256,
and a valid platform package identity. Unsigned stable releases are refused.
