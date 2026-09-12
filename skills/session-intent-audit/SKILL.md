---
name: session-intent-audit
description: "Audit a working session for every instruction the operator gave and the assistant dropped, using the verbatim transcript rather than anyone's memory of it. Use this whenever the operator asks what you ignored, what you missed, what got lost, whether you actually did everything asked, or says he has had to repeat himself. Also use it proactively at the end of a long session, before a handoff, or when the operator repeats an instruction he already gave, because repetition is the measurement that something is being dropped. Trigger on: what did you ignore, what did you miss, did you do everything I asked, prove you read it, I keep telling you, I already said that, inventory of what was skipped, session audit, intent audit."
---

# Session intent audit

An assistant asked to list what it ignored will answer from memory. Memory is
the thing under audit. This skill reads the record instead.

The session transcript is the only surviving copy of what the operator actually
typed. Everything else - the running summary, the ledger, your recollection -
is derived, and a summary of an instruction is exactly where instructions go to
die. That is the failure this audit exists to find.

## The shape of the work

It is a diff with two sides, and they must be produced separately:

    THE ASKS      extracted mechanically from the transcript
    THE ACTS      read from git, the substrate, the runtime
    THE AUDIT     the rows where one has no match in the other

Keeping them apart matters. A single process that both recalls the ask and
grades itself against it will quietly align the two, which is how a session
convinces itself it did everything.

## Step 1. Extract the asks, mechanically

Find the transcript. It lives at
`~/.claude/projects/<slugged-project-path>/<session-id>.jsonl`. The slug is the
working directory with separators replaced by dashes.

```bash
python ~/.claude/skills/session-intent-audit/scripts/extract_operator_turns.py \
  "<transcript>.jsonl" -o /tmp/asks.txt
```

It prints how many lines it scanned and how many operator turns it found, and
writes them numbered to the output file. It filters tool results and system
reminders, which arrive in the user role and would otherwise inflate the count
with things the operator never said.

If it reports zero turns, that is a finding about the extractor or the path,
never a finding that he asked for nothing. The script says so itself and exits
non-zero.

## Step 2. Have somebody else turn turns into instructions

Dispatch a reader that knows nothing about what was done. Give it the extracted
file and ask only for a numbered list of distinct instructions, each with its
turn number and a short verbatim quote, plus a section listing which ones repeat
and how often.

Do not do this step yourself. You are the thing being audited, and you will
read your own work into his words.

Ask the reader to include instructions phrased as complaints. "You are supposed
to keep this tidy" is an instruction. So is "why didn't you". People give
directions inside frustration, and an extractor tuned only for imperatives
misses them.

## Step 3. Count the repeats first

This is the measurement that matters, and it is available before any judgment.

An instruction the operator typed once is a request. An instruction he typed
eight times is one you kept dropping, and each retype cost him a turn. Lead the
report with the highest repeat count. It is the score.

Lived example: one session showed the same sentence about checking the offload,
git and the substrate typed nearly word for word eight times across 129 turns.
Nothing had gone red. The assistant believed it was carrying the standing task
the whole time.

## Step 4. Verify each row, or mark it unaccounted

For each instruction, find the artifact that would exist if it had been done: a
commit, a merged pull request, a file on the default branch, a live probe, a
substrate anchor. Cite it.

Three verdicts, and only three:

    DELIVERED          with the artifact named
    NOT DONE           with the reading that proves absence, plus a control
    NOT ACCOUNTED FOR  no evidence either way

Use the third one freely. A long session that has been compacted leaves you
holding a summary for the early turns, and marking those rows done or not done
from a summary is the same defect the audit is about. An honest "I cannot
account for 30 of these" is a real result; a confident 53-row table is not.

For every absence you claim, run a control that returns a hit, so an empty
result means empty rather than broken.

## Step 5. Write it so it can be acted on

Group by failure class rather than by turn order, because the classes are what
gets fixed:

- instructions not carried out
- claims asserted without a measurement behind them
- places where your inference replaced his instruction
- turns spent on nothing

Include a section for what DID land. A list of only failures is its own
distortion and it makes the whole document easy to dismiss.

End with the pattern in one line. Usually there are only two: a conclusion
reported without its reading, and an inference acted on as though it were an
order.

## What this skill refuses to do

It does not rank the operator's asks by importance, and it does not quietly
retire the ones that look stale. An instruction stays open until it is
delivered or he retires it. Deciding on his behalf that something no longer
matters is the same category error the audit is looking for.

It also does not propose remedial action the operator did not ask for. Producing
the inventory is the job. What to do about it is his.
