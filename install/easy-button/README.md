# DreamerOS easy button, v0

One download. Double-click `dreameros-setup.cmd`. Every AI coding tool on the
machine becomes DreamerOS-connected. The customer edits nothing and never
sees a token in a file.

This exists because the operator did the manual version - hooks by hand,
JSON by hand, paths by hand, across four engines, over many hours. The easy
button is the promise that no customer repeats that.

## What it does

1. Probes the machine for tools. It never assumes - only 4 of the
   ~20 Windows config paths in the 2026 market scan are vendor-documented
   literally; the rest must be probed.
2. Fetches the current boot contract from the public manifest
   (`GET https://mcp.dreameros.app/api/v1/agent/manifest`,
   `boot_contract.instruction_text`). Falls back to an embedded copy and
   says so in the report.
3. Writes the binding per tool, in that tool's own format. Creates files
   that do not exist yet - a new customer has none of them.
4. Prints one report table and one remaining human step: paste the token
   into the `DREAMEROS_MCP_TOKEN` environment variable. The script never
   touches token values.

## Source table for every shape it writes

Measured 2026-08-26 on a live install or taken from the vendor doc named.

| Tool | Target | Shape source |
|---|---|---|
| Claude Code | `~/.claude/CLAUDE.md` block merge | Anthropic memory doc: Claude reads CLAUDE.md, not AGENTS.md |
| Claude Code | `claude mcp add --transport http` | CLI, never editing `~/.claude.json` live state |
| Codex | `~/.codex/AGENTS.md` block merge | measured live install |
| Codex | `config.toml [mcp_servers.dreameros]` with `bearer_token_env_var` | measured live install |
| Cursor | `~/.cursor/rules/dreameros.mdc`, `alwaysApply: true` | cursor.com/docs/rules |
| Cursor | `~/.cursor/mcp.json` `mcpServers` + env-reference header | measured live install |
| VS Code | `%APPDATA%/Code/User/mcp.json`, root key `servers`, `type: http` | code.visualstudio.com MCP doc |
| Antigravity | `~/.gemini/GEMINI.md` block merge | Gemini reads GEMINI.md by default, not AGENTS.md |

Known non-portable traps the script already honors: the MCP root key
differs per tool (`mcpServers` vs `servers` vs `mcp` vs `context_servers`);
Claude Code hard-fails a `url` with no `type`; never symlink CLAUDE.md on
Windows; never write a UTF-8 BOM (a BOM made a real settings.json
unparseable with thirteen hooks behind it).

## Tested

Red-green on a fake home (`-HomeOverride`): dry run writes 0 files; real
run provisions 6; second run reports 6 ALIGNED with 0 writes and 0
backups; every JSON parses with the correct root key; no BOM in any output;
the TOML section appears exactly once after repeat runs; no token value
anywhere in any output, proven by pattern scan.

## Not in v0, deliberately

- Hooks. The enforced tier (Duo / UNO / Dreamweaver) binds each engine's
  hook surface to the gateway. That waits for the gateway-side ask ledger
  so the gates have one runtime to call, not N local scripts.
- macOS and Linux. This is the Windows leg.
- Signing and packaging. Next step is an Inno Setup wrapper signed via
  Azure Artifact Signing; an unsigned exe fights SmartScreen forever.
- Zed and JetBrains. No hook surface; reach them via the ACP registry.
- OpenCode, Cline. Need a TS module and a Windows-support probe.

## Verify before v1

Two research claims are high-leverage and not yet independently grounded
(the gateway verify pass returned UNCHECKED - source grounding unavailable):

1. VS Code reads Claude Code hook files by default via
   `chat.hookFilesLocations` (would make `~/.claude/settings.json` reach
   two tools at once).
2. Claude Code hooks support `type: "http"` remote POST with no local
   script (would make the enforced tier scriptless).

Verify both against the live docs before any v1 design stands on them.
