# Kimi, Fireworks, and Claude routing

Use this reference only when one of these providers is in scope. It describes decisions that must survive model and price changes. Fetch the current official pages and live DreamerOS schemas before choosing a model or quoting a capability.

## Current-source lookup

Start with these maintained sources, then follow the current API reference and changelog they expose:

- Kimi API overview: https://platform.kimi.ai/docs/overview
- Fireworks documentation index: https://docs.fireworks.ai/llms.txt
- Fireworks pricing: https://docs.fireworks.ai/serverless/pricing
- Claude Code documentation index: https://code.claude.com/docs/llms.txt
- Claude Code changelog: https://code.claude.com/docs/en/changelog

Documentation proves what a provider offers. A live model catalog proves what the current account may request. A successful bounded probe proves what that account served at that moment. Keep those three evidence levels separate.

## Kimi: two doors, one hard boundary

Internal Kimi and customer-owned Kimi serve different purposes.

The internal door may use a DreamerOS-managed credential or an approved routing provider. It can gather, generate, or review work according to the current routing policy. Its receipt must disclose the actual provider and model and must not present platform spend as customer-owned spend.

The DreamWeaver BYO door uses only the member's vaulted Kimi credential. Its lifecycle is connect, verify, select, call, inspect receipt, and revoke. It must never read or fall back to the DreamerOS platform credential. If the member credential fails, the call fails closed or moves only to another route the member explicitly owns and allowed.

For either door, preserve provider reasoning or tool-call state exactly as the current Kimi API requires. Discover that requirement from the current official schema rather than freezing request fields here.

## Fireworks: choose the routing shape deliberately

Do not treat all multi-model behavior as one feature. Determine which shape the task needs:

- Explicit fan-out sends independent requests and compares the returned evidence.
- A semantic or cost router selects one eligible model for a request.
- A race runs alternatives and records the winner plus the losing attempts.
- A deployment router distributes traffic for capacity or experiments; it does not imply semantic model selection.
- Adapter multiplexing serves variants of one foundation model; it is not independent multi-model review.

Read the current Fireworks schema for routing headers, cache controls, batch behavior, and supported models. Record whether the response was cached, what isolation or affinity key class was used, what fallback occurred, and what the provider billed. Never expose the key or raw cache isolation material.

## Claude Code: separate orchestration from proof

Claude Code can coordinate agents, workflows, scheduled work, and remote sessions as its current release permits. Inspect the installed version, settings, active hooks, and current official changelog before depending on any feature.

Agent output and advisor output are claims until checked against their cited artifact or runtime. Parallel agents need disjoint file ownership. Scheduled or remote execution needs the same DreamerOS before-record, after-record, authority boundary, and destination verification as an interactive session.

## Receipt contract for routing decisions

Preserve these values when the runtime exposes them:

- requested task class, route, and quality or cost preference
- actual provider and model
- credential origin: platform-managed or customer-owned
- provider billing state and measured cost, or an explicit unknown
- cache hit or miss plus safe isolation and affinity evidence
- fallback attempts and final served route
- producing lineage and independent-review lineage
- receipt, trace, and request identifiers safe for the operator to retain

Configuration, aliases, and requested values never substitute for the actual served values.

## Moats that come from measured operation

The defensible asset is not access to a model. Providers can sell that to everyone. The moat is the accumulated, privacy-safe evidence that DreamerOS can use to improve selection without weakening intent or trust:

- task-to-route outcomes measured against acceptance checks
- cost, latency, cache, fallback, and quality recorded per actual served route
- customer-owned credentials kept cryptographically and operationally separate from platform spend
- independent verification lineage shown rather than implied
- portable receipts and handoffs that let every client resume from the same facts
- failure data that improves routing before a customer repeats the same failure

Each moat begins as a build target. It becomes a product claim only after the intended customer can reach it, use it, and inspect evidence from a real run.
