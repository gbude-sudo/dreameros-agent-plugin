# DreamerOS global Claude Code environment

`dreameros-global-setup.ps1` installs the DreamerOS working environment into a
Claude Code home directory on a Windows machine. It is the packaged form of an
environment that was previously assembled by hand, file by file.

The installer merges settings and managed regions. It does not replace whole
existing configuration files. It preserves existing MCP servers, each unique
permission, and each unique nonretired hook. It removes duplicate and named
retired lifecycle registrations.

## Load this repository as a Claude Code plugin

Three ways, from a one-session test to a permanent load. All three read the
same two things: `.claude-plugin/plugin.json` and `skills/` at the repository
root. Skills arrive namespaced, for example `/dreameros:dreameros-boot`.

1. One session, no install. Needs the `claude` CLI on PATH.

```
claude --plugin-dir <path-to-this-repository>
```

2. Install by name. The catalog is `.claude-plugin/marketplace.json`.

```
claude plugin marketplace add gbude-sudo/dreameros-agent-plugin
claude plugin install dreameros@dreameros
```

For a local clone, give `marketplace add` the clone path instead of the
GitHub name.

3. Permanent load with no CLI and no install. Put this repository under your
personal skills directory. On Windows a directory junction keeps one copy:

```
cmd /c mklink /J %USERPROFILE%\.claude\skills\dreameros <path-to-this-repository>
```

The plugin loads as `dreameros@skills-dir` on the next session. To stop
loading it, remove the junction with `cmd /c rmdir` on the junction path;
that removes the link, not the repository.

The MCP entry in `.mcp.json` carries no credential. A client that needs a
bearer follows the Authentication section of the root README.

## What it installs

```
install/claude-code/
  dreameros-global-setup.ps1     the installer
  README.md                      this file
  payload/
    agents/       15 subagent definitions
    hooks/        18 hook scripts, 13 bash and 5 python
    skills/       18 skill definitions
    CLAUDE.md     the canon file
    settings.fragment.json  permissions and hook registrations to merge
```

Every path inside the payload is a token, not a real path. The installer
expands `__DREAMEROS_CLAUDE_HOME__`, `__DREAMEROS_REPO_ROOT__`, and
`__DREAMEROS_BASH_COMMAND__` after it reads the local machine. The package
holds no operator-specific path, no credential, and no API key.

### Agents

For the 15 named managed agents, the installer owns only the `tools` line and
the `DREAMEROS-READ-ONLY-BOOTSTRAP v1.1.0` block. It merges those two regions
into an existing file. It preserves every other local frontmatter field and
body sequence, and backs up the original file before writing. A malformed or
ambiguous managed region fails closed instead of requiring `-Force`.

| Agent | Job |
| --- | --- |
| canon-citer | verify a claim against canon before asserting it |
| citation-verifier | resolve every file:line before acting on it |
| contract-differ | diff a payload against a schema across two repos |
| count-verifier | run the exact count command given and report the output |
| dreameros-operator | substrate tools pre-loaded, for persistence work |
| file-locator | find files by name or pattern and report paths |
| governance-node | adversarial review against the principle contract |
| grep-scout | run given searches and return hits with file:line |
| mind-eye-auditor | pre-push audit: dashes, destructive payloads, secrets |
| open-loop-auditor | find what was promised and not delivered |
| plain-language-auditor | check prose against ASD-STE100 |
| probe-runner | run given HTTP probes and report results verbatim |
| queue-checker | report git and PR state, with BEHIND detection |
| web-operator | governed live-web action with receipt |
| wolverine | self-healing: watch failure, patch, verify, PR |

### Hooks

| Hook | Event | Job |
| --- | --- | --- |
| dreameros-session-start.sh | SessionStart | loads the portable session package contract |
| open-loop-surface.sh | SessionStart | surfaces uncommitted and unmerged work |
| dreameros_turn_check.py | UserPromptSubmit | checks every message against the DreamerOS gateway and shows the result |
| gate-local-merge-first.sh | PreToolUse Bash | refuses a push that skips local main |
| gate-destructive-write.sh | PreToolUse Write | refuses a write that erases most of a file |
| gate-anchor-size.sh | PreToolUse remember | refuses an anchor the substrate will reject |
| gate-no-archive-without-asking.sh | PreToolUse archive | refuses to end a session without the operator |
| gate-stop-no-half-states.sh | Stop | refuses to end a turn on a half finished state |
| gate-claim-verification.sh | Stop | checks claims against reality |
| dreameros-agent-stack-stop.sh | Stop | pre-close checklist when repositories are dirty |
| model-phase-boundary.sh | Stop | wrapper for the python hook |
| model-phase-boundary.py | Stop | names the model to use at a phase boundary |
| model-switch-ack.sh | Unregistered compatibility file | retained on disk but never registered beside the direct hook |
| model-switch-ack.py | Stop | direct hook that names the engine after it changes |

SessionStart and Stop commands are unique across matcher groups. The installer
keeps the first command object and every nonduplicate hook or matcher. It does
not apply cross-group deduplication to `PreToolUse`, where matcher scope changes
meaning. It also removes the retired SessionStart auto-install command. It
preserves `build-boot-pack.ps1 -VerifyInstalled`.

On Windows, the installer resolves and runs Git for Windows `bash.exe` before
it writes settings. It registers the quoted absolute executable path, so a
Claude process does not depend on a later PATH broadcast. During an upgrade it
changes only payload-managed Bash registrations; unrelated owner Bash hooks
stay unchanged. On non-Windows systems, registrations keep the portable
`bash` command name.

### Skills

| Skill | Job |
| --- | --- |
| braid-coordination | run parallel work strands safely with beacon, pulse, and seal messages |
| dreamer-sync | the check-populate-sync loop for substrate and git across all repos |
| estate-branch-triage | classify every local branch and stash before any merge or cleanup |
| estate-pulse | the seven-source morning sweep of the estate |
| external-mcp-client-onboard | wire a third-party MCP client into the DreamerOS registration door |
| image-critique | score an image against its prompt with the 3-engine vision quorum |
| learning-prompts | turn a learn-this request into a ready-to-paste teaching prompt |
| live-error-triage | triage a production error down to a minimal cited fix |
| model-tiered-offload | pick the subagent model tier by who checks the output |
| oauth-setup | cited steps for the operator to register an OAuth app for a connector |
| p37-truth-audit | check every marketing claim against the shipped runtime |
| plain-language | rewrite text into Simplified Technical English without losing evidence |
| pr-unstick-behind | detect and clear auto-merge PRs stuck at BEHIND |
| reachability-audit | find value that exists but reaches nobody |
| render-pass | measured mobile and desktop render audit of a web surface |
| runtime-first-verify | probe the live runtime before reporting any blocker |
| self-catch | find what our own gates caught in the trailing week |
| verified-sprint | the full verify-then-ship loop with the verification trap table |

## The nine requirements

HC stated nine requirements for this environment. This table says which file
satisfies each one. It names gaps instead of hiding them.

| # | Requirement | Satisfied by | State |
| --- | --- | --- | --- |
| 1 | Tell me which model to use | `payload/hooks/model-phase-boundary.py` and `.sh` | PRESENT |
| 1b | Tell me WHEN the engine changed, without being asked | direct `payload/hooks/model-switch-ack.py`, boot canon R17 | PRESENT for Claude Code; PROSE ONLY on vendors with no hook surface |
| 2 | Drift detection | `payload/agents/open-loop-auditor.md`, `payload/agents/citation-verifier.md`, `payload/skills/self-catch/SKILL.md` | PRESENT |
| 3 | No skipped inputs, no hallucinations | `payload/hooks/gate-claim-verification.sh`, `payload/hooks/gate-stop-no-half-states.sh`, the agent hook in `payload/settings.fragment.json` | PRESENT |
| 4 | Know what the gateway enforces | `payload/hooks/operator-standing-orders.sh`, `payload/agents/governance-node.md`, `payload/agents/canon-citer.md` | PARTIAL |
| 5 | Do not archive without asking | `payload/hooks/gate-no-archive-without-asking.sh` plus the deny entry in `payload/settings.fragment.json` | PRESENT |
| 6 | Repeatedly available inline | the two registered SessionStart hooks above | PRESENT |
| 7 | Vendor agnostic | repository root `plugin.json`, `mcp.json`, `skills/` in Agent Plugins v1.0 format | PARTIAL |
| 8 | Sellable and distributable | this folder: `dreameros-global-setup.ps1` and its payload | PRESENT |
| 9 | Life-hack moats versus peers and competitors | no dedicated artifact. `payload/skills/reachability-audit/SKILL.md` carries "moat scour" as a trigger phrase only | MISSING |

Two entries say PARTIAL. Read them exactly.

Requirement 4 is partial because the installed files STATE the contract and
review work against it. No file QUERIES the live gateway for the rule set it
currently enforces. A stated contract can drift from an enforced one.

Requirement 7 is partial because this installer targets Claude Code on
Windows. The repository root is vendor agnostic under the Agent Plugins v1.0
standard, and any compatible client can load it. The hook gates are not
portable, because hooks are a Claude Code feature.

## How to run it

Dry run first. It prints every action and changes nothing.

```powershell
.\dreameros-global-setup.ps1 -DryRun
```

Then install.

```powershell
.\dreameros-global-setup.ps1
```

Custom locations:

```powershell
.\dreameros-global-setup.ps1 -ClaudeHome D:\claude -RepoRoot D:\code\DreamerOS
```

`-WhatIf` also works, through standard PowerShell `ShouldProcess`.

### Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-ClaudeHome` | `$env:USERPROFILE\.claude` | where Claude Code reads its config |
| `-RepoRoot` | `$env:USERPROFILE\Documents\DreamerOS` | where your repositories live |
| `-PayloadPath` | `payload` next to the script | the payload directory |
| `-BashPath` | auto-detected | optional absolute Git Bash path on Windows; the executable must identify itself as GNU bash |
| `-DryRun` | off | print actions, change nothing |
| `-Force` | off | overwrite differing hook, skill, and canon payload files; managed agent files still merge only their two owned regions |
| `-SkipCanon` | off | do not install CLAUDE.md |

### After the install

Set `DREAMEROS_MCP_TOKEN` in your own user environment, then start a new
Claude Code session. The installer never reads, writes, or stores a token.

The hook gates are Bash scripts. On Windows the installer verifies Git Bash and
stops before any write when it cannot find a working executable. The model
phase boundary hook needs `python` on PATH; a missing Python command remains a
warning because the other gates do not depend on it.

## Safety properties, and how each one was tested

| Property | Test | Result |
| --- | --- | --- |
| Idempotent | run twice against the same home | `settings.json` byte-identical, SHA256 unchanged, every file reported SKIP |
| Merges, never clobbers | run against a copy of a 142-entry live settings.json | `additionalDirectories`, `enabledPlugins`, `extraKnownMarketplaces` and every other key preserved |
| Lifecycle commands stay unique | seed duplicates across SessionStart and Stop matcher groups | first command kept, four later duplicates removed, PreToolUse matcher groups preserved |
| Windows Bash path executes | render a Git Bash path and Claude home that contain spaces, then run the exact command through `cmd.exe` | hook writes its expected marker; a nonexistent launcher exits nonzero and cannot emit a valid hook result |
| Retired auto-install removed | seed SessionStart `build-boot-pack.ps1 -Install` beside `-VerifyInstalled` | install command removed, verify command and session package kept |
| Managed agent hydration merges | seed old UUID tools, local frontmatter, and local body text | portable tools and one bootstrap block installed; every unrelated field and body sequence preserved |
| Backs up before writing | any run that changes a file | timestamped copy under `<ClaudeHome>\backups\dreameros-install-<stamp>\` |
| Refuses a corrupt settings.json | seed an unparseable file, run | merge refused, file untouched, exit code 1 |
| Dry run changes nothing | `-DryRun` against a seeded home | every action printed, no write |
| Fails loudly | any failure | named at the failing boundary, nonzero exit code |

A customer-edited payload hook, skill, or canon file is left alone unless
`-Force` is used. Unrelated customer files are not targets. Managed DreamerOS
agent files use a narrower rule without `-Force`: the installer locks and
backs up each file, updates only `tools` and the bootstrap block, and preserves
the other frontmatter and body content.

## How to roll back

Every run that changed a file wrote a timestamped backup folder. The path
appears at the end of the run.

```powershell
$b = "$env:USERPROFILE\.claude\backups\dreameros-install-20260813-020226"
Copy-Item "$b\settings.json" "$env:USERPROFILE\.claude\settings.json" -Force
```

## How to uninstall

There is no uninstall switch, on purpose. An uninstaller that deletes files is
the exact shape of the accident this environment exists to prevent. Remove
what you want to remove, and read each path before you remove it.

1. Restore `settings.json` from the backup folder, as above. This removes the
   hook registrations and the permission entries in one step.
2. Delete the agent files you no longer want from `<ClaudeHome>\agents\`.
3. Delete the hook scripts you no longer want from `<ClaudeHome>\hooks\`.
4. Delete the skill folders you no longer want from `<ClaudeHome>\skills\`.
5. Restore or delete `<ClaudeHome>\CLAUDE.md`.

Restoring `settings.json` alone is enough to stop every gate from firing.
Files left on disk that no setting points at do nothing.
