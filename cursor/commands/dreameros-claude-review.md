---
name: dreameros-claude-review
description: Build and preflight a clean-context Claude Code review packet. A separate authorized coordinator can later store the reviewed verdict in DreamerOS.
---

# Cursor to Claude Code independent review

Do not send a Claude prompt until the Human Conductor gives the exact current
authorization `CONFIRM CLAUDE REVIEW SEND`. Packet creation and preflight are
read-only except for writing the new packet file.

1. Resolve the current user home from the operating system. Find the existing
   DreamerOS `Offline_Repo` under that user's configured estate roots and
   require exactly one target. Create a timestamped packet under its
   `audits/cursor-claude-review/` directory. Find
   `DREAMEROS_CLAUDE_CODE_FINAL_REVIEW_PACKET_2026-08-26.md` inside that estate
   and use it as the structural reference, but include only evidence for the
   current task. Do not assume a username, drive letter, or home path.
2. Put in the packet the Human Conductor objective to review the latest
   `/dreameros-parity-check` result. Record the exact parent Cursor transcript
   path, SHA-256, byte length, and line count. Include both complete
   `CURSOR_PARITY v1` blocks. Include the raw ordered transcript records for the
   phase bridge, prelaunch boundary, both Task request records, the ledger read,
   and the second block. List later UUID completion callbacks separately and do
   not treat them as pre-emission launch proof. Record the exact hook-ledger
   path, `byte_length`, and `prefix_sha256`. Recompute that prefix hash. Include
   the raw first two complete appended `subagentStart` JSON records. The parent
   transcript omits Shell results, so read these rows directly from the hook
   ledger instead of copying Cursor's summary. For every hash, name the exact
   file path or transcript byte range that it covers. For every diff, name its
   base, head, included states, exact command, and exit code. Separate
   committed, staged, unstaged, and untracked evidence. Include raw test
   commands and exit codes. Record deployment ids, logs, endpoint responses,
   and UTC timestamps separately. List the claims Claude must try to refute.
   Name all held-back scope. Add the exact transcript path to the packet's
   ordered read list. Do not name `/dreameros-claude-review` as the Human
   Conductor objective. Do not include credentials or Cursor's verdict as
   authority.
3. Discover Claude Code from `PATH` first. If it is absent, search only the
   current user's supported install roots. Check platform-local app data,
   `~/.local/bin`, and the Claude desktop package cache. Resolve duplicate links
   to one newest executable. Do not assume a Windows account name or package id.
   Run `--version`, `auth status --json`, and `mcp list`. Record the exact
   version. Enforce a specific or minimum version only when the current review
   packet or repository policy names one. Require logged-in status and a healthy
   DreamerOS MCP. If any fail, stop with
   `CLAUDE_REVIEW=BLOCKED` and name the exact human action. Never copy a token
   from Cursor, Codex, or an environment variable. Never start or automate an
   account or MCP authentication flow from Cursor.
   After authentication, have HC open Claude Code's read-only `/hooks` browser
   and prove the central `dreameros-session-start.sh` is effective. Treat
   server-managed `allowManagedHooksOnly`, `disableAllHooks`, or any duplicate
   DreamerOS hydration hook as `CLAUDE_REVIEW=BLOCKED` until the effective hook
   list is corrected.
   - If `loggedIn` is false, run `auth login --help` only. When current help
     exposes `--claudeai`, tell HC to run the exact resolved executable with
     `auth login --claudeai` and complete the browser flow personally. If that
     option is absent, quote the current help-directed subscription login
     command instead of guessing. After HC finishes, rerun `auth status --json`
     and require `loggedIn=true`.
   - If the header-free `dreameros` HTTP server reports `Needs authentication`,
     run `mcp login --help` only, then tell HC to run the exact resolved
     executable with `mcp login dreameros` and complete OAuth personally. Rerun
     `mcp list` afterward and require `Connected`.
   - Inspect the user-scope `dreameros` entry in `~/.claude.json` structurally.
     Record only `type`, `url`, header property names, and
     `authorization_present=true|false`. Never print, copy, or persist a header
     value or the raw server object.
   - If `authorization_present=true`, explain that the header disables OAuth
     fallback. Do not repair it automatically. Tell HC to back up
     `~/.claude.json`. HC then removes the user-scope `dreameros` entry and adds
     header-free HTTP at `https://mcp.dreameros.app/mcp`. HC uses the same
     human-only `mcp login dreameros` flow above. Rerun the preflight and require
     `Connected`.
4. After explicit send authorization, give Claude Code one clean-context,
   read-only review. Default consequential unverified claims to `REVIEW BLOCK`.
   Remeasure Git and artifact hashes. Inspect source and destination evidence.
   Make no file, memory, canon, PR, deployment, or production writes.
5. Require Claude to return only `REVIEW PASS` or `REVIEW BLOCK`, findings with
   file/line or command evidence, each claim's evidence rung, artifact hashes,
   commands/timestamps, and held-back checks. A pass attests to packet accuracy,
   not deployment or customer completion.
6. Hash the Claude result. A separate authorized coordinator, not Claude and
   not Cursor's original author, stores a content-addressed DreamerOS handoff
   containing the reviewed hashes, verdict, commands, blockers, and timestamp,
   then reads it back. That returned memory id is the cross-vendor sync receipt.

Return:

```text
CLAUDE_REVIEW_PACKET=<absolute path>
PACKET_SHA256=<hash>
CLAUDE_VERSION=<version|BLOCKED>
CLAUDE_AUTH=<READY|BLOCKED>
CLAUDE_DREAMEROS_MCP=<CONNECTED|BLOCKED>
CLAUDE_REVIEW=<PASS|BLOCK|HELD>
DREAMEROS_SYNC=<RECEIPTED memory-id|HELD>
```
