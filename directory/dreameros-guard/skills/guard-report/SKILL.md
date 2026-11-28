---
name: guard-report
description: Show what DreamerOS Guard caught in the last 7 days. Use when the member asks what Guard caught, how often the assistant said done too early, or for the weekly Guard summary.
---

Show the Guard summary only when the member asks.

1. Run `python "${CLAUDE_PLUGIN_ROOT}/install/claude-code/plugin/done_report.py"`.
2. Show the output as it is. Do not add counts it did not print.
3. Say plainly that the log is on this machine and holds claim codes and times, not
   message text.
4. If the output says there is no log, say so. Do not guess a number.
