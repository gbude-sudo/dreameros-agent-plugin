---
name: live-error-triage
description: Triage a production error from Sentry or logs down to a minimal cited fix, and sweep the same log window for secondary defects. Use when Sentry surfaces a new issue, when production logs show a traceback, when the operator pastes an error, or when a NameError or ImportError appears in a deployed service. Born 2026-08-13, when a function-local import gap and two invisible secondary defects came out of one log window.
---

# live-error-triage

The lesson from 2026-08-13. A production NameError came from a function
that imported two sibling modules locally but not connection_store. A
file-level grep said "imported". Only reading the function scope showed
the gap. And the same log window held two more defects the primary error
never pointed at.

## Step 1: locate the failing symbol

Grep the codebase for the exact symbol from the traceback. Collect every
definition and every use site.

## Step 2: distinguish import scopes

This is the trap. A symbol can be imported at file level in one module
and still be undefined inside a specific function in another. Check, in
order:

1. Is the symbol imported at the top of the failing FILE?
2. Is it imported inside the failing FUNCTION? Sibling functions may
   carry local imports the failing one lacks.
3. Which scope does the failing line actually resolve against?

A file-level grep hit is not proof the name is bound at the failing line.
Read the function body.

## Step 3: confirm the call site

Open the file at the traceback line numbers. Confirm the exact lines
match the deployed version. If the local file and the traceback disagree,
the deploy is older than your checkout. Verify the live SHA before
writing any fix.

## Step 4: fix minimally, matching sibling style

If sibling functions solve the same need with a function-local import,
add the same function-local import. Do not refactor imports to file level
as a side quest. The fix diff should be as small as the defect.

Cite the Sentry issue id in the commit message.

## Step 5: sweep the window for secondary defects

While the log window is open, read it in full for defects the primary
error hides. The 2026-08-13 window yielded two:

- An auto-remember 422, a contract drift failing 100 percent of calls
  silently. No traceback, just a status code repeating.
- A foreign-key race, visible only as an occasional constraint error.

Look for: repeating non-200 status codes, constraint violations, retries
that always retry, and warnings that appear every request. File each
secondary find as its own item with its own log line quoted. Do not fold
them into the primary fix.

## Honesty rules

- Quote the log line or traceback verbatim in every finding.
- A fix is SHIPPED at merge plus deploy with the SHA named. It is FIXED
  only when the error stops recurring in the live window.
