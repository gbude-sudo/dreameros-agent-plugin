---
name: external-mcp-client-onboard
description: Wire a third-party MCP client such as Slack, ChatGPT, or Cursor into the DreamerOS Dynamic Client Registration door. Use when a new external client needs MCP access, when a client's connect flow fails with invalid_redirect_uri, or when the operator asks to hook a new tool into DreamerOS. Born 2026-08-13 from the lived Slack onboarding sequence.
---

# external-mcp-client-onboard

The lived sequence from 2026-08-13. A third-party client connects to
DreamerOS through Dynamic Client Registration. The one gate that fails in
practice is the redirect allowlist. Everything else is form filling.

## Step 1: allowlist the client's callback host

The client's callback host must be in APPROVED_REDIRECT_DOMAINS in
gateway/app/oauth.py, inside register_client. When registration fails,
the error text names the exact URI to allowlist. Read the error, do not
guess the host.

Rules for the edit:
- Add ONE host, the one the error names.
- No wildcards. A wildcard turns the allowlist into no list.
- Match the sibling entries' style exactly.

## Step 2: fill the client-side form

The client's MCP connection form wants:

- URL: https://mcp.dreameros.app/mcp
- Authentication: Dynamic Client Registration
- Identity URL: https://mcp.dreameros.app/oauth/userinfo
- Account Identifier: $.email

The userinfo endpoint returns only sub and email. Any account identifier
path other than $.email or $.sub returns nothing and the client shows a
blank identity.

## Step 3: verify from outside

Do not trust the client's own success banner. Probe the door directly with
an unauthenticated POST to /oauth/register carrying the client's
redirect_uri:

- 201 with a client_id in the body means the door is live for this host.
- 400 invalid_redirect_uri means the allowlist gap is still there, or the
  fix is not deployed yet. Check the live SHA before editing again.

## Step 4: test the negative

Send the same POST with a lookalike host, for example the real host with
one character changed. Expect 400. If the lookalike gets 201, the
allowlist match is too loose and the door is open to redirect hijack.
That is a stop-ship finding, not a note.

## Honesty rules

- Registration success is not onboarding success. The client is onboarded
  when it completes a real authenticated MCP call end to end.
- Record the host you added, the PR, the deploy SHA, and both probe
  results in the substrate anchor.
