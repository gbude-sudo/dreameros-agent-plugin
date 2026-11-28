> Moved. The done check is now part of the DreamerOS plugin itself, so a
> member installs one plugin. In Claude Code it loads from
> `install/claude-code/plugin`. Install `dreameros@dreameros`. This folder
> keeps the original text below for history.

# DreamerOS Guard

Catches your AI saying "done" when it is not.

When the assistant is about to stop, Guard reads its last message. If the message
claims something Guard can check on your machine, Guard checks it. If the claim does
not match the real state, Guard holds the stop once and tells the assistant exactly
what is wrong. The assistant must fix it, or say plainly that it is left.

## What Guard checks

| The assistant says | Guard checks |
|---|---|
| "I pushed the branch" | Are there commits that are not on the remote? Is a remote branch set? |
| "I committed it", "saved", "pushed" | Do tracked files still have uncommitted edits? |
| "I added `CHANGELOG.md`" | Does that file exist? |
| "All tests pass" | Did a test command run in this session? |

Guard checks only plain, positive statements. It skips sentences with "not", "yet",
"will", "should" and similar words, and it ignores code blocks. It does not treat
"fixed" as a claim that you committed.

## What Guard does not do

- It does not check that tests passed, only that a test command ran.
- It does not read CI. It does not judge the quality of the work.
- It does not catch a claim it has no check for.
- It blocks once per turn and never loops.
- If Guard fails for any reason, it allows the stop. A broken guard must not trap
  a session.
- It does not yet check whether the assistant did everything you asked. That check
  needs your DreamerOS account and is planned.

## Install

Guard needs Python 3 on your PATH.

```
claude plugin marketplace add gbude-sudo/dreameros-agent-plugin
claude plugin install dreameros-guard@dreameros
```

Restart Claude Code after you install. You do not need an account.

## See what it caught

Ask: "What did Guard catch this week?" The `guard-report` skill prints a count by
kind, for example "3 x said pushed, commits were not on the remote".

## Privacy

Guard runs on your machine and makes no network call. It keeps a small log of claim
codes and times at `~/.dreameros-guard/caught.jsonl`, or in the plugin data folder
when Claude Code provides one. The log holds no message text. Delete the file any
time.

## Tested

16 tests run the real hook against temporary git repositories: pushed and unpushed
work, uncommitted edits, missing and present files, test runs, negated sentences,
code blocks, bad input and a repository-free folder. They pass on Linux. They have
not been run on Windows or inside a live Claude Code session yet. The hook input and
output follow the Claude Code hooks reference (the `Stop` event with
`last_assistant_message`, `stop_hook_active`, and `{"decision": "block"}`).

Privacy policy: https://dreameros.app/privacy
Support: https://dreameros.app/contact.php

## License

See LICENSE.
