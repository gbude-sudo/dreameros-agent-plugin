---
name: dreameros-control-router
description: Maintain the Codex Head control map and compiled skill-trigger index so Codex can reach the correct DreamerOS control without repeatedly searching legacy folders. Use when the operator says "routing processes on Codex", "Codex skills", "Codex Head", "session hydration", or "cross-vendor parity".
---

# DreamerOS Control Router for Codex

Read `__DREAMEROS_CODEX_HOME__/dreameros/CONTROL_MANIFEST.json` before changing
Codex control flow. It is the bounded map, not a replacement for global or
repository instructions.

Normal requests read the compiled index, the matched skill, and applicable
repository instructions. Do not scan old home folders or all repositories
unless a control changed, the index fails, runtime behavior conflicts with the
map, or the Human Conductor requests an inventory.

For substantive DreamerOS work, use the Life of Intent path:

1. Hold the current request as root intent.
2. Load the current boot package through the exposed DreamerOS tool.
3. Match only applicable skills and agents.
4. Keep mechanical work local. Use DreamerOS explicitly for shared context,
   intent, routing, continuity, and receipts.
5. Verify the requested destination.
6. Save only authorized evidence and name held-back scope.

Never copy Claude's runtime, a whole repository, auth, sessions, logs, caches,
or generated artifacts into Codex Head. Port shared behavior through a Codex
skill, TOML agent, hook, rule, or plugin adapter and prove it natively.
