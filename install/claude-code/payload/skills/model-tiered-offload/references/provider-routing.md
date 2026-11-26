# Provider routing and receipts

Use this reference when a task uses a model provider, estimates cost, designs cache or fallback behavior, or reports which route served a request. It describes decisions that must survive model and price changes. Fetch the current official provider pages and the live DreamerOS schemas before choosing a model or quoting a capability.

## Evidence levels

Documentation proves what a provider offers. A live model catalog proves what the current account may request. A successful bounded probe proves what that account served at that moment. Keep those three evidence levels separate.

## Customer-owned connection: one hard boundary

A customer-owned provider connection uses only the member's own vaulted credential. Its lifecycle is connect, verify, select, call, inspect receipt, and revoke. It must never read or fall back to a DreamerOS platform credential. If the member credential fails, the call fails closed or moves only to another route the member explicitly owns and allowed.

Preserve provider reasoning or tool-call state exactly as the current official provider schema requires. Discover that requirement from the schema rather than freezing request fields here.

## Orchestration is not proof

Agent output and advisor output are claims until checked against their cited artifact or runtime. Parallel agents need disjoint file ownership. Scheduled or remote execution needs the same before-record, after-record, and verification as interactive work.

## Receipt contract for routing decisions

Preserve these values when the runtime exposes them:

- requested task class and quality or cost preference
- actual provider and model
- credential origin: platform-managed or customer-owned
- provider billing state and measured cost, or an explicit unknown
- cache hit or miss
- fallback attempts and final served route
- producing lineage and independent-review lineage
- receipt, trace, and request identifiers safe for the operator to retain

Configuration, aliases, and requested values never substitute for the actual served values.

A capability becomes a product claim only after the intended customer can reach it, use it, and inspect evidence from a real run.
