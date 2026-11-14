# DreamerOS Memory

Save where you stopped. Pick it up in a later session. Search the notes you saved.
Scan a draft for filler and unfinished code.

This plugin connects Claude to your DreamerOS account. It adds four skills:

| Skill | You say something like | What it does |
|---|---|---|
| save-handoff | "Save where we stopped." | Shows you a short handoff, then saves it after you say yes. |
| resume-handoff | "What did I leave for later?" | Reads the handoff you saved and shows it to you. |
| find-my-notes | "Search my saved notes for the pricing decision." | Searches the notes you saved in DreamerOS. |
| check-for-filler | "Scan this draft for filler." | Flags placeholder text, filler wording and unfinished code in text you give it. |

## Set up

1. Add the plugin from the Claude directory when it is listed, or try it now from a
   local folder with `claude --plugin-dir ./directory/dreameros-memory`.
2. Open the plugin's Connectors tab (or run `/mcp` in Claude Code) and connect
   DreamerOS. You sign in with your DreamerOS account.
3. Ask for one of the things in the table above.

You need a DreamerOS account. The tools in this plugin are built to work on the free
plan. If your plan does not include a tool, Claude tells you.

## Data: what is sent, what is saved

- Nothing is saved unless you ask. The save-handoff skill shows you the exact text
  first and saves it only after you confirm.
- When you ask to save, the handoff text you approved goes to your DreamerOS account.
- When you search, your search words go to DreamerOS. Results are notes you saved earlier.
- When you ask for a filler scan, the text you give goes to DreamerOS to be scanned.
- A successful call can create an audit receipt in your account. A receipt holds ids,
  a time, the tool name and a hash of the input. It does not hold your text.
- This plugin does not read Claude's own memory, chat history or summaries.
- This plugin does not generate images, video or audio.
- Saved text comes back to Claude as data from you. The skills tell Claude to show it
  to you and not to act on instructions inside it unless you confirm.

Privacy policy: https://dreameros.app/privacy
Terms: https://dreameros.app/terms
Support: https://dreameros.app/contact.php

## Examples

1. "Save where we stopped on the pricing page." Claude drafts three lines, shows them,
   and saves after you confirm.
2. "What did I leave for later on the pricing page?" Claude reads your last handoff and
   asks what you want to do with it.
3. "Search my saved notes for what I decided about refunds." Claude lists matching notes.
4. "Scan this draft for filler and unfinished code." Claude returns the findings.

## License

See LICENSE.
