---
name: dreameros-life-of-intent
description: >-
  Keep every substantive DreamWeaver request inside the one DreamerOS Life of
  an Intent path. Use this skill automatically when a request needs reasoning,
  creation, research, a decision, memory, verification, routing, coding, or durable
  action. Treat narrower skill names as mode hints inside this path, never as
  separate pipelines. The Gateway enforces Solo, Duo, and higher-plan access.
  Skip only literal pass-through work that needs no model judgment.
---

# DreamerOS Life of an Intent

One request takes one path. DreamerOS keeps the member's meaning attached,
checks the answer before it is returned, and shows whether DreamerOS was
actually used. Do not ask the member to assemble separate checks or skills.

<!-- DREAMEROS-BOOT-PRECONDITION v1.1.0 -->
`dreameros_session_package` is the only required boot call. Call it first.
When the package directs it or the assigned task needs read-only enrichment,
use this order: (1) `dreameros_session_handoff_read` for the full record when
present, (2) `dreameros_context` and its SCS as the read-only current-state
channel, (3) scoped `dreameros_recall`, and (4) `dreameros_canon` when needed.

## Enter the path

Call the DreamerOS MCP `dreameros_skill` with `skill: auto` and the member's
current request as `content`. That call enters the same Gateway answer path as
`dreameros_chat`; it does not return another standalone skill for the client
to simulate. Use the returned answer and its receipt evidence.

## Gateway Lockstep evidence

Client hooks can verify a bounded Gateway Lockstep record when the host event
supplies it. The record distinguishes `CONFIGURED`, `INVOKED`, `RECEIPTED`, and
`TERMINAL`. A terminal result requires the signed Gateway receipt to bind the
actual `dreameros_skill` input and its signed intent anchor. Terminal states
are `SUCCESS`, `NO-OP`, `BLOCKED`, `STALLED`, and `EXHAUSTED`.

The shared verifier owns the intent-envelope schema, receipt-event schema,
terminal-state enum, client capability matrix, managed-artifact manifest, and
native hook-event adapter table. The SDK must expose typed records and the
Gateway must enforce them. This plugin only carries the contract and maps host
events to it.

Do not treat a client configuration, hook launch, or missing event fields as
proof of the path. A host that cannot supply the record reports `UNSUPPORTED`.
That is an honest capability limit, not a pass or a universal enforcement claim.

The Gateway decides entitlement. If it denies the lifecycle, or if the Gateway
or required MCP tool is unavailable, report the affected step `BLOCKED`. Do not
reproduce a hidden internal profile or substitute an unreceipted local answer.

## One path, not a skill menu

When the member names another skill or slash command, keep the name as a mode
hint. It can change the emphasis, output shape, or check inside the path. It
cannot bypass the path or create a second one.

Use the Gateway response as the answer from this path. A named skill or slash
command can change its emphasis or presentation, but cannot create another
answer path or authorize an action.

## Evidence boundary

Report only steps, engines, checks, costs, receipts, and terminal states that a
tool response or destination reading actually proves. Never turn a configured
component, returned instruction, queued order, passing unit test, merge, or
deployment into a claim that the member completed the whole path.

Do not relax approval boundaries for destructive, irreversible, production,
credential, signing, merge, deploy, spending, publishing, or external actions.
