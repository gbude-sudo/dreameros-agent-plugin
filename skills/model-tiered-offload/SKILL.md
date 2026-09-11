---
name: model-tiered-offload
description: Route multi-step work across models, providers, and subagents by verification risk while keeping cost visible and preserving independent review. Use when choosing an execution model, sending parallel lanes, comparing providers, or planning DreamerOS offload. Do not use it to claim a route ran without runtime evidence.
---

# Model-tiered offload

Choose the best model for the job. Let cost break ties only after every candidate meets the required accuracy, correctness, currency, validity, and intent fidelity.

## Pick the tier by who checks the result

- Use the smallest capable tier for mechanical output that the coordinator will rerun or discard. Give it the exact command, scope, output shape, and stop bound. It gathers; it does not conclude.
- Use a mid tier for a diagnosis whose cited files, commands, or runtime readings the coordinator will inspect before acting.
- Use the largest appropriate tier for architecture, security, spend, irreversible action, canon, or a judgment that will be used without another check.
- Use a different provider or clean-context reviewer when independence from the producing model matters. A same-lineage self-review is not independent proof.

Name the selected model or route, why it fits, what the lane returns, how it stops, and how its output will be verified.

## Read live truth before dispatch

Inspect the tool schema and provider catalog exposed in the current session. Model identifiers, prices, availability, route modes, and receipt fields change. Do not copy them from this skill or from an earlier session.

Treat `dreameros_agent` as planning only. Its output is a plan, not executed work. Treat consensus as a runtime-selected verification mode, not as a fixed engine count. Bound its cost, quorum, timeout, and failure rule from the current schema.

## Prove what actually ran

Do not call a dispatch routed, offloaded, cached, verified, or receipted until the runtime response supports that claim. Preserve the returned receipt identifier and the actual provider, model, billed cost or unknown-cost state, cache result, fallback path, and lineage or independence evidence when those fields are exposed.

Requested route is intent. Served route is evidence. If the response omits a field, report it as unknown instead of filling it from configuration.

## Keep customer and platform credentials separate

Kimi has two valid DreamerOS doors: an internal DreamerOS-funded route and a customer-owned DreamWeaver connection. Never let failure of a customer-owned Kimi credential fall back to a DreamerOS platform key. A BYO call must remain customer-key-only, fail closed, and identify its key origin in the receipt.

## Provider-specific work

Read [Kimi, Fireworks, and Claude routing](references/kimi-fireworks-claude.md) when the task uses those providers, estimates cost, designs cache or fallback behavior, or turns routing evidence into a product moat.
