# DreamerOS for Codex

Boot canon R17 (name the engine the moment it changes), Codex half.

## What is here

| File | Event | Job |
| --- | --- | --- |
| `payload/hooks.json` | Stop | registers the hook at the USER level |
| `payload/hooks/model-switch-ack-codex.py` | Stop | names the engine out loud the turn after it changes |

## Install

Copy `payload/hooks/model-switch-ack-codex.py` to `~/.codex/hooks/`,
then copy `payload/hooks.json` to `~/.codex/hooks.json`, replacing
`__DREAMEROS_CODEX_HOME__` with the real path to `~/.codex`.

User level, not repo level, on purpose. A repo-scoped hook binds only
sessions opened inside that repository, and an engine switch is not a
per-repository event.

If `~/.codex/hooks.json` already exists, MERGE rather than overwrite.
The installer refuses to overwrite an existing file for that reason. It uses
exclusive `CreateNew` when the file is absent. If another process creates or
locks the file during installation, the installer stops with `MERGE NEEDED`.

The central boot installer also treats the hook script as shared state. An
aligned file is left untouched. A differing file is locked exclusively and
backed up with a UTC timestamp before update. The installer rechecks the exact
current byte hash immediately before writing. If another process holds or
changes the destination, installation stops with `MERGE NEEDED` and preserves
the owner's bytes for review.

## Two ways it learns the model, and why there are two

Codex passes turn-scoped fields on stdin, so a `model` key there is
authoritative and free. When that key is absent the hook falls back to
the rollout transcript under `~/.codex/sessions/`, where the model sits
at `payload.model` on `turn_context` records. The fallback is not
decoration: it is the path that keeps working if the stdin field is
renamed or dropped, and it was verified against a real rollout file.

## Trust

Codex requires a hook to be trusted before it runs, recorded under
`[hooks.state]` in `~/.codex/config.toml`. A newly installed hook is
untrusted until Codex records its hash. Confirm the hook is trusted and
watch it fire before treating this as covered - a hook that exits 0 is
not a hook that ran.

## Stop output contract

Measured with Codex CLI 0.154.0. A Stop hook that must continue the current
turn emits top-level `decision: block` plus a `reason`. The hook returns no
output when `stop_hook_active` is true, which lets the continued response stop
without recursion. `additionalContextLimit` is not part of this Stop
registration. The repository validator and hook regression suite enforce all
three conditions.

## Verified

Fired from the installed path with a real session id and a real rollout.
Covered: a switch blocks Stop with a reason; the active-hook guard stays
silent; no switch stays silent; the same boundary
announces once and not twice; malformed stdin exits 0 without crashing;
a truncated final transcript line costs one record and not the file; a
byte-order mark does not silence it; a session id that matches no
rollout returns nothing rather than reading another session.
