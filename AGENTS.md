<!-- DREAMEROS-BOOT-CANON: NOT DUPLICATED HERE -->
<!-- DREAMEROS-PROJECT-BOOT-POINTER v1.1.0 -->
## DreamerOS Boot Canon - proven by a native carrier or session package

The full DreamerOS Boot Canon is generated from
gbude-sudo/dreameros-agent-plugin:bootpack/SOURCE-dreameros-boot-canon.md and delivered
through native carriers and authenticated session packages. This project file
intentionally contains no copy of the canon and cannot import another rule.

Before substantive DreamerOS work, prove either carrier A or carrier B:

A. Native carrier for the active engine:
   1. Claude Code or Desktop: the current generated block is present once in
      ~/.claude/CLAUDE.md.
   2. Codex: the current generated block is present once in ~/.codex/AGENTS.md.
   3. Cursor: Customize shows the local Dreameros plugin, and its
      dreameros-boot-canon rule is set to Always and appears in the active rule
      trace for the fresh Agent chat.

B. Cloud carrier: a successful authenticated `dreameros_session_package`
   response proves one `package_components.boot_canon` component and one
   complete boot-canon wrapper. Component and wrapper schema, version, SHA-256,
   and provenance metadata must match. Recompute the SHA-256 over the complete
   LF-normalized wrapper body and require it to match the component metadata.
   Require the current canary set inside that full body and a canonical UTC
   `composed_at` plus integer `ttl_seconds` from 1 through 3600, allowing
   no more than 60 seconds of clock skew. An optional `expires_at` is not an
   alternate authority. A marker-only, truncated, duplicate, malformed, or
   auth-required package is not proof.

   If the visible package lacks the complete closing wrapper or full hash proof
   but metadata-first `package_continuation` is present, fetch same-tool parts
   1 through N. Verify per-part hashes, order, and user-bound `package_id` plus
   `content_hash`. Reassemble, verify the full content hash and boot-canon
   body, then proceed. Failed reconstruction is BLOCKED.

If both carriers are available, their boot-canon identity metadata must match.
If they differ, report CONFLICT and stop substantive work.

If neither carrier is proven, report BLOCKED and stop substantive work. Do not
use this pointer as a fallback canon.
Repository instructions add project scope after boot; they do not replace the
Human Conductor or the current generated boot rule.

To change a boot rule, edit the shared source and run
bootpack/build-boot-pack.ps1 -Install. Never paste the full canon into a
repository instruction or project rule. A second copy loads later, drifts, and
can override the current machine-wide rule.
<!-- END DREAMEROS-BOOT-CANON POINTER -->
