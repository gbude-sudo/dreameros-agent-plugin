---
name: oauth-setup
description: Produce exact, up-to-the-minute, cited instructions for the operator to register an OAuth app for a connector and get its client_id/client_secret. Use when the operator asks how to set up OAuth for a provider (sentry, slack, google, squarespace, ...) or needs the redirect URI, scopes, or Railway env var names.
---

# oauth-setup

Give the operator a precise, source-cited path to obtain a provider's OAuth credentials so a DreamerOS connector can go live. Always cite live docs; never answer OAuth specifics from memory.

## Steps
1. Read the gateway connector `gateway/app/connectors/<provider>.py` for the exact `authorize_url`, `token_url`, `scopes`, `client_id_env`, `client_secret_env`, and any quirks (Basic auth, required User-Agent, comma vs space scope separator, access_type=offline, token lifetimes).
2. WebFetch the provider's OFFICIAL developer OAuth docs (up to the minute) and confirm: where to register the app, where the client_id/client_secret appear, where to add the redirect URL, how scopes are selected, and whether issuance is self-serve or a review queue. Quote and link the sources.
3. Hand the operator a field-by-field walkthrough with these exact values:
   - Redirect URI: `https://mcp.dreameros.app/api/v1/integrations/<provider>/oauth/callback`
   - Scopes: exactly what the connector requests (from step 1) - request the full set up front (many providers cannot change scopes after issuance).
   - Railway vars to set: `<PROVIDER>_OAUTH_CLIENT_ID`, `<PROVIDER>_OAUTH_CLIENT_SECRET`, and confirm `GATEWAY_PUBLIC_URL=https://mcp.dreameros.app` (the redirect host MUST equal this or the callback fails).
   - Logo (if the form needs one): `https://dreameros.app/assets/rgb-thumb-64.png` (the live RGB fingerprint brand mark; 64x64).
   - Terms / Privacy (if needed): `https://dreameros.app/terms`, `https://dreameros.app/privacy`.
4. Flag honestly: self-serve (instant creds, like Sentry) vs review-queue (Squarespace emails creds after manual review; may require a specific plan). Note any plan/eligibility gate from the docs.
5. End with: once creds are set on Railway + redeploy, run the `connect-golive` skill for that provider.

## Always
- Cite every OAuth fact with a markdown link to the official doc. No em dashes (spaced hyphens only).
