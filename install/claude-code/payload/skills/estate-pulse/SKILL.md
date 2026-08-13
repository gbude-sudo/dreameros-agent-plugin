# estate-pulse

The seven-source morning sweep proven 2026-08-11/12. Run when the operator
says estate pulse, morning sweep, what changed overnight, or at any session
start on estate work. The sweep interrogates the remote authority on each
channel, never local clones. The estate is 17 repos, not 5. The highest-yield
source is overnight crashes and new errors, not what did not break.

Use when the operator asks: estate pulse, morning sweep, what changed
overnight, what is the current state, or any session start on estate work.

## The sweep, in order

1. GIT REMOTE AUTHORITY. Run `gh repo list gbude-sudo` to enumerate active
   repos. For each repo, query the remote for: (a) open PRs with age
   timestamp, (b) merged PRs in the last 24 hours with merge timestamp and
   author, (c) failed workflow runs in the last 24 hours with log link. Never
   enumerate from local clones. The remote is the estate state.

2. SENTRY ORG. Query Sentry org dreamer-ai-holdings-llc, region
   https://us.sentry.io. Retrieve unresolved issues sorted by freq descending.
   Filter for firstSeen in the last 24 hours. This is historically the
   highest-yield defect source. Report the issue key, release if tagged,
   affected user count, and a one-line stack trace frame.

3. RAILWAY GATEWAY CHAIN. Project 24761806-4bc1-481b-8a23-7158a319efb7,
   service 3c7d7b14-ccc1-4026-904b-7806d5cdbd04. Retrieve the newest
   deployments. Find the most recent SUCCESS status. Read its commitHash.
   That is the live SHA. Status SKIPPED with reason "No changes to watched
   files" is correct for docs-only merges, not a defect.

4. VERCEL PROJECT. Project prj_QyQqBwuNj0qmNFALbXKHUohvQGxG, team
   team_EELn9y7BdrcUbh9JVWLncymg. Retrieve the newest production deployment.
   Read its state and commitSha. A CANCELED newest deploy after a no-op merge
   is normal.

5. GMAIL UNREAD. Query newer_than:2d excluding label:github and
   category:promotions. Railway crash mails and vendor notices are the signal.
   Ignore transactional confirmations.

6. DRIVE RECENT FILES. Use list_recent_files to find new uploads since last
   sweep. Look for debug logs, crash files, or new runbooks.

7. DREAMEROS SUBSTRATE. Call dreameros_recall on open items from prior
   sessions. Replay any unresolved context.

## Output shape

End with a three-part digest:

- WHAT BROKE: name any defect that has grown in severity or user reach in
  the last 24 hours. State what evidence proves breakage.

- WHAT NOBODY IS WATCHING: name any change that merged without a success
  deploy, any error nobody acknowledged, any alert with no owner named.

- SINGLE HIGHEST-LEVERAGE ACTION: name the one thing that, if fixed now, has
  the broadest effect on customer usability or team velocity.

## Honesty rules

Every claim carries a file path, a tool result, or a screenshot. Never report
an absence untested. Before reporting a defect, run the same query twice -
once from the remote, once from the local checkout - and name which answer
differs. If both say the same thing, you know the answer is true. Cap output
at the 12 strongest findings; rank by (user reach x severity).
