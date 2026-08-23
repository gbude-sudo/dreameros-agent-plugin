# DreamerOS Desktop Agent

The desktop agent is a per-user lifecycle manager and a loopback MCP proxy for
Claude, Codex, and Cursor. Release targets are Windows x86_64, macOS arm64, and
Linux x86_64.

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

Desktop updates are disabled by default. The explicit command requires
`DREAMEROS_AGENT_UPDATE_ENABLED=true`. Automatic checks also require
`DREAMEROS_AGENT_AUTO_UPDATE=true`. Do not enable either before signed-release
and clean-machine recovery tests pass.

The Linux package adds `DreamerOS Agent Setup` to the application menu. It does
not start setup for other users. The signed-in user chooses that entry or runs
`dreameros-agent install`.

The proxy binds only `127.0.0.1:18765`, exposes `/health`, forwards `/mcp` to
`https://mcp.dreameros.app/mcp`, and injects the vault bearer plus the
`X-DreamerOS-Installation` UUID. It does not log request bodies or headers.
Any process in the signed-in operating-system session can call the loopback
port. The vault protects the bearer bytes; it does not isolate local callers.

## Local checks

```text
python -m pip install -e desktop/agent
python -m unittest discover -s desktop/agent/tests -v
```

Stable updates require an Ed25519-signed release manifest and a matching
SHA-256. Windows checks Authenticode. macOS checks package signing and
Gatekeeper. Linux checks the `dpkg-sig` identity named by the signed manifest.
Unsigned or mismatched stable releases are refused.
