# Diamond Readiness Gate

Status: local shadow preflight. Not canon. Not runtime. Not a directive
compiler. It generates no adapters and writes no files.

This gate exists because the reviewed Diamond contract forbids compiler work
until the Human Conductor resolves the source owner, three semantic conflicts,
178 candidate groups, and the Gateway publishes an approved Plan IR digest.

Run from the repository root:

    $env:PYTHONDONTWRITEBYTECODE = '1'
    python shadow/diamond/readiness.py `
      --clause-map C:/path/to/DREAMEROS_DIRECTIVE_CLAUSE_MAP_v0_1_0.json `
      --plan-ir-manifest C:/path/to/plan_ir/MANIFEST.json `
      --expected-map-sha256 <64-hex-pin> `
      --expected-plan-manifest-sha256 <64-hex-pin> `
      --hc-decisions C:/path/to/ratified-decisions.json `
      --expected-hc-decisions-sha256 <64-hex-pin> `
      --approved-hc-draft C:/path/to/published-approved-draft.json `
      --expected-approved-hc-draft-sha256 <64-hex-pin>

Exit codes:

- 0: every prerequisite is READY.
- 2: prerequisites are BLOCKED, with deterministic JSON diagnostics.
- 1: an input is unreadable or invalid.

The current corpus is expected to exit 2. That is the guard working.

Tests:

    $env:PYTHONDONTWRITEBYTECODE = '1'
    python -m unittest discover -s shadow/diamond/tests -p "test_*.py" -v

The gate verifies the map and Plan IR pins, recomputes coverage and unresolved
counts instead of trusting summaries, checks source bytes and frozen Git
metadata, and returns empty `writes` and `activation_targets` arrays in every
result.

A source repository or source path with uncommitted changes is blocked even if
the frozen status listing happens to match. A dirty checkout is evidence to
preserve, not an acceptable compiler input.

The HC decision ledger is separate from the clause map. Relabeling a clause as
ratified cannot satisfy the gate unless its decision reference resolves to a
pinned record approved by the Human Conductor and covering that exact clause or
normalized group. Omitting the ledger always blocks.

A ratified ledger must also chain to the exact published pending draft approved
by HC. The gate requires the approved draft SHA, the HC chat source reference,
the agent-plugin as the one decision-ledger repository, exact clause and group
scope equality, exact owner decisions, and exact per-clause conflict
resolutions. Any nonempty replacement text is not enough. The approved draft
and the new ratified ledger must both exist on current `origin/main` at their
versioned `governance/decisions/` paths.

Plan IR is accepted only when the manifest is at its required repository path,
matches `origin/main`, names a nonzero published revision reachable from
`origin/main`, and every required artifact at that revision matches its pinned
hash. A local object or an unrelated committed file is not publication proof.

Held back by design:

- typed Directive IR;
- generated Claude, Codex, Cursor, or generic adapters;
- bundle lock and signatures;
- Plan IR publication;
- installer activation;
- any runtime import, hook, MCP, source, or customer change.
