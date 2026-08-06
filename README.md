# DreamerOS Agent Plugin

The official DreamerOS plugin in the [Agent Plugins v1.0](https://agent-plugins.org)
open format. One install gives any compatible agent client (ChatGPT, Codex,
GitHub Copilot, VS Code, Cursor, Kiro, and others adopting the standard)
access to DreamerOS's governed gateway:

- **Cross-session memory** - recall and remember across every AI surface you
  use, in one governed vault you own and can export or delete.
- **Verified answers** - high-stakes claims checked before you act on them.
- **Multi-engine routing** - hard questions answered by the best-fit engine,
  or cross-checked by several, with disagreement surfaced instead of hidden.

## What is inside

```
dreameros/
  plugin.json    identity + spec version
  mcp.json       DreamerOS MCP server (Streamable HTTP)
  skills/
    dreameros-continuity/        recall before work, remember after
    dreameros-verified-answers/  verify before high-stakes claims
    dreameros-governed-routing/  multi-engine consultation
```

## Install

Install mechanics differ per client (each client owns distribution and
permissions under the Agent Plugins standard). In all cases the plugin
directory is this repository's root.

## Authentication

The MCP server at `https://mcp.dreameros.app/mcp` authenticates each user
with their own DreamerOS API key.

1. Sign in at [app.dreameros.app](https://app.dreameros.app) and generate an
   API key from your account settings.
2. Provide the key through your client's own credential mechanism when it
   prompts for the DreamerOS server (as a bearer token).

Per the Agent Plugins specification, this plugin never embeds credentials.
No key ships in any file here, and you should never commit yours.

Capabilities are tier-gated server-side by your DreamerOS subscription, so
the same plugin works on every tier - free included.

## Versioning

Semantic versioning. The plugin tracks Agent Plugins spec 1.0.0.

## License

Proprietary. The plugin manifest and skill texts may be redistributed
unmodified for the purpose of installing the plugin.
