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
The installer refuses to overwrite an existing file for that reason.

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

## Verified

Fired from the installed path with a real session id and a real rollout.
Covered: a switch fires; no switch stays silent; the same boundary
announces once and not twice; malformed stdin exits 0 without crashing;
a truncated final transcript line costs one record and not the file; a
byte-order mark does not silence it; a session id that matches no
rollout returns nothing rather than reading another session.
