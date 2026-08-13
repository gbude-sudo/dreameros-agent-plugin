---
name: model-tiered-offload
description: Use this skill on any multi-step task where subagent dispatch is being considered. It picks the model tier by the verify axis from SUBAGENT_MODEL_TIERING_v1_0_0, names the five micro agents and the mid-tier agents by use case, gives the escalation tell, and routes DreamerOS side quests through governed offload.
---

# Model-tiered offload

Pick the subagent tier by one axis. Not by how hard the task feels.

> Will the coordinator verify this output before acting on it?

Canon: `governance/00_CORE/SUBAGENT_MODEL_TIERING_v1_0_0.md` in the
gateway repo. This skill is the dispatch procedure for that canon.

## The binding clause, verbatim

**Small models gather. They do not conclude.**

A small-model conclusion may never be cited as evidence in a PR body, a
canon document, or a substrate anchor without the coordinator
independently verifying the underlying artifact.

## Tier 1: micro agents (haiku)

Use when the output is mechanically checkable or discarded. Each agent
carries the same hard rule in its body: it gathers and reports, it never
concludes, never edits, never recommends.

| Agent | One-line use case |
|---|---|
| probe-runner | run given curl or HTTP probes, report status and body verbatim |
| grep-scout | run given searches on given paths, return file:line hits, no reading of meaning |
| file-locator | find files or dirs by name or pattern, report paths and sizes |
| count-verifier | count with the exact command given, report command and output |
| queue-checker | report git and PR state read-only, including the BEHIND recipe |

Dispatch rule: give the micro agent the exact command or pattern. The
command is the definition of the task. A micro agent that had to choose
its own method produced an uncheckable result; re-dispatch with the
method spelled out.

## Tier 2: mid agents (sonnet)

Use when the output is a diagnosis with citations you will check against
the cited artifacts.

| Agent | One-line use case |
|---|---|
| contract-differ | diff a payload against a schema across two repos, cite file:line both sides |
| citation-verifier | resolve every file:line and attribution claim in a report before acting on it |
| wolverine | reproduce a failure, patch minimally, verify, file a tiny PR |

## Tier 3: largest model

Use when the output is a judgment acted on without an independent check,
or a wrong answer is not recoverable in one step. Architecture, canon
changes, security, spend, and any file under the destructive-payload
guardrail. Do not delegate these below the top tier.

## The escalation tell

If a subagent report contains a number, a mechanism, or a causal claim
you cannot trace to a file:line or to command output inside the report
itself: discard the report and re-run one tier up. Confident prose is
not evidence.

## Every dispatch carries a bound

Per BOUNDED_EXECUTION_DISCIPLINE_v1_0_0: state the exit bound in the
prompt. Example: if 5 minutes pass with no progress, report PARTIAL and
stop, no loop, at most 2 attempts. A cheap agent does not get a looser
leash.

## DreamerOS side: governed offload

Side quests route through DreamerOS for governed offload to the
Fireworks pool, per Operator Standing Order 2. The tools are
`dreameros_agent` and `dreameros_route`. Rules:

- Use `dreameros_route` with `best_fit` for a single engine answer.
  Use `consensus` only when a claim needs a cross-check; it fans out to
  five engines and stalls if any one hangs, so bound it.
- Use `dreameros_agent` for a governed agent run on the DreamerOS side.
- A native subagent is not a DreamerOS Live agent. Claim DreamerOS
  offload only when the route or agent call returns runtime evidence
  (a receipt id, a route id, a response body). Never fake that
  evidence; if the call did not happen, the offload did not happen.

## The dispatch decision in four steps

1. Name what the subagent will hand back.
2. Ask: will I verify it before acting on it?
   - I will re-run or re-read it anyway: micro agent, exact command in
     the prompt.
   - I will check its citations: mid agent.
   - I will act on it unchecked, or a wrong answer is expensive: top
     tier, or do it in the main thread.
3. Put the exit bound in the prompt.
4. On return, apply the escalation tell before using anything in it.
