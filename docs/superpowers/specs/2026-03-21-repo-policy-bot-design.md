# Repo Policy Bot — Design Spec

## Problem

Maintaining an open-source repo is tedious. Issue triage, PR review, duplicate detection, release management — it's all repetitive work that follows rules. OpenOats built an autonomous maintainer powered by Claude Code that handles this via a policy document. This works, but it's tightly coupled to OpenOats and requires manual Claude Code sessions.

Other repo maintainers want the same thing. They need a way to define their repo's maintenance policy and have an AI agent execute it autonomously on GitHub.

## Solution

An npm package (`repo-policy-bot`) that scaffolds an autonomous repo maintainer onto any GitHub repository. Users run one command, customize a policy file, and get AI-powered triage, code review, implementation, and release management — all running as GitHub Actions on top of `anthropics/claude-code-action`.

## Non-Goals

- Multi-provider support (Codex, Gemini) — v1 is Claude-only, though the policy format is provider-agnostic
- Custom label taxonomies — the label system is opinionated and fixed
- Web dashboard or hosted service
- GitHub App packaging — workflows are simpler
- Replacing CI — this orchestrates around existing CI, doesn't replace it

## Architecture

### Three-Layer Execution Model

```
┌─────────────────────────────────────────────────┐
│                 GitHub Events                    │
│         (issues, PRs, comments, labels)          │
└──────────┬──────────────┬──────────────┬─────────┘
           │              │              │
           ▼              ▼              ▼
   ┌──────────────┐ ┌───────────┐ ┌─────────────┐
   │ Policy Agent │ │Gate Runner│ │Release Runner│
   │  (AI layer)  │ │(pure logic)│ │(pure logic) │
   │              │ │           │ │             │
   │ claude-code- │ │ Merge if  │ │ Bump version│
   │ action       │ │ gates pass│ │ Tag release │
   └──────────────┘ └───────────┘ └─────────────┘
```

#### 1. Policy Agent

**Trigger:**
- `issues` (opened, labeled) — new issues and human label changes (e.g., approving `risk:high` work)
- `pull_request` (opened, synchronize, labeled) — new/updated PRs and human label changes
- `issue_comment` (created) — filtered in the workflow YAML with `if: contains(github.event.comment.body, '@claude')` to avoid burning API calls on irrelevant comments

**Guards:**
- Skip if issue/PR is closed or has `state:done`
- Skip if trigger is `labeled` and the label was applied by the bot itself (prevent loops)
- Concurrency: `concurrency: { group: policy-agent-${{ github.event.issue.number || github.event.pull_request.number }}, cancel-in-progress: false }` — one agent run per issue/PR at a time; queues rather than cancels to avoid killing in-progress implementation runs

**How it works:**
- Calls `anthropics/claude-code-action` in automation mode
- The prompt is assembled as: `system-prompt.md` content + contents of `.github/repo-policy.md` + GitHub event context
- Passed via the `prompt` input of `claude-code-action`
- `allowed_tools` includes `Edit`, `Read`, `Write`, `Bash(gh:*)`, `Bash(git:*)` for GitHub CLI and git access
- System instructions encode the label taxonomy, state machine, and gate definitions
- User's policy file provides product guardrails, risk boundaries, and decision rules

**Permissions:** `contents: write`, `issues: write`, `pull-requests: write`

**What it does:**
- Triages new issues (classify kind, assess risk, check for duplicates)
- Reviews PRs (code review, risk assessment, label normalization)
- Implements `risk:low` and `risk:medium` fixes (creates branch, edits files, pushes commits, opens PR)
- Normalizes labels: if multiple labels exist in a namespace, keeps the highest-severity one and removes others
- Applies labels as the state machine progresses
- Comments with reasoning and status updates
- Runs adversarial input checks on submissions
- Escalates `risk:high` items by labeling `state:awaiting-human`
- Resumes work when human changes labels (e.g., `state:awaiting-human` → `state:planned` re-triggers the agent)
- On `synchronize` (new commits pushed to PR): re-reviews only the new changes, does not re-triage from scratch. Comments with incremental review.

#### 2. Gate Runner

**Trigger:** `pull_request` (labeled)

**How it works:** Pure shell/JS logic, no AI. No AI API calls — cost is zero. Triggers when `state:ready-to-merge` label is applied.

**Merge conditions (all must be true):**
- PR has `state:ready-to-merge` label
- PR does NOT have `risk:high` label
- No merge conflicts
- All required status checks pass
- No unresolved reviews requesting changes
- PR body is non-empty (contains user-facing summary)
- `resolution` label is `resolution:none` (the literal label, meaning active/unresolved). If resolution is anything else, the item is already terminal — skip silently, do not post a failure comment.

**Merge strategy:** Configurable via `.github/repo-policy.md` — defaults to squash merge, supports `merge` and `rebase`. Set under a `# Merge Strategy` heading.

**Action:** Merge the PR via GitHub API using configured strategy. Apply `resolution:merged` and `state:done` labels. Close the PR (GitHub does this automatically on merge). If the PR body references an issue (e.g., "Fixes #123"), GitHub auto-closes it; otherwise the Gate Runner closes linked issues via `gh issue close`.

**Failure:** If any gate fails, post a comment explaining which gate blocked, remove `state:ready-to-merge`, apply `state:in-progress`.

#### 3. Release Runner

**Trigger:** `push` to default branch (i.e., after merge)

**How it works:** Pure shell/JS logic, no AI. No AI API calls — cost is zero. Finds merged PRs by comparing commits between the latest semver tag and HEAD, then looking up associated PRs via `gh pr list --search "SHA"` for each commit.

**Release conditions:**
- At least one merged PR has `release:patch` or `release:minor` label
- No merged PR in the batch has `release:major` (requires human approval)
- No merged PR in the batch has `risk:high`
- Default branch tip has passing CI

**Version bump rule:**
- Any `release:minor` in batch → bump minor
- Otherwise any `release:patch` → bump patch
- `release:none` PRs don't trigger releases
- `release:major` blocks automatic release, comments asking for human approval

**Version source:** Git tags. The Release Runner finds the latest semver tag (e.g., `v1.2.3`), applies the bump rule, and creates the new tag + GitHub Release with auto-generated notes. If no semver tag exists, starts at `v0.1.0`. The release tag triggers whatever release pipeline the repo already has (e.g., a `release-dmg.yml` workflow).

**Error handling:** If tag creation fails (already exists), skip and log. If no CI status is available, skip release and comment on the most recent merged PR explaining why.

### Label Taxonomy (Built-In, Fixed)

Users do not configure these. They ship with the tool.

| Namespace | Labels | Purpose |
|-----------|--------|---------|
| `kind:` | `bug`, `feature`, `ux`, `docs`, `housekeeping` | Classify work type |
| `state:` | `new`, `needs-info`, `needs-repro`, `planned`, `in-progress`, `awaiting-human`, `ready-to-merge`, `done` | Track workflow stage |
| `risk:` | `low`, `medium`, `high` | Determine autonomy level |
| `resolution:` | `none`, `merged`, `duplicate`, `already-fixed`, `declined`, `out-of-scope` | Terminal state |
| `release:` | `none`, `patch`, `minor`, `major` | Version impact |

Every open issue/PR gets exactly one label from each namespace.

### State Machine Transitions

Valid `state:` transitions (any transition not listed is invalid):

```
new → needs-info          (missing details)
new → needs-repro         (bug without reproduction steps)
new → planned             (accepted, queued for work)
new → awaiting-human      (risk:high or ambiguous, needs human)
new → done                (duplicate, already-fixed, declined, out-of-scope)

needs-info → planned      (info provided)
needs-info → done         (no response, or info reveals duplicate/invalid)
needs-info → awaiting-human

needs-repro → planned     (repro provided)
needs-repro → done        (no response, or can't reproduce)
needs-repro → awaiting-human

planned → in-progress     (work started)
planned → awaiting-human  (new info changes risk assessment)
planned → done            (superseded or no longer needed)

in-progress → ready-to-merge  (PR passes review, for PRs only)
in-progress → awaiting-human  (hit a decision point)
in-progress → planned         (blocked, returning to queue)

awaiting-human → planned      (human approves/decides)
awaiting-human → in-progress  (human approves and work resumes)
awaiting-human → done         (human declines)

ready-to-merge → done         (merged by Gate Runner)
ready-to-merge → in-progress  (gate failed, needs more work)
```

The Policy Agent enforces these transitions. If it encounters an invalid state (e.g., a human manually set a bad label), it normalizes to the nearest valid state and comments explaining why.

### Policy File Format

Located at `.github/repo-policy.md` (or user-configured path). This is the only file users need to write.

```markdown
# Product Guardrails
<!-- What this project values. The agent uses these to make judgment calls. -->
- Example: Privacy by default
- Example: Simplicity over features

# Risk Classification
<!-- Override or extend the default risk rules. -->
## Always High Risk
- Changes to authentication or authorization
- Modifications to the release pipeline
- Database migration changes

## Always Low Risk
- Documentation-only changes
- Test-only changes

# Decision Rules
## Bugs
- Fix if reproducible or obvious from code inspection
- Close as duplicate if an existing issue covers it

## Features
- Accept if it benefits most users
- Decline if it adds disproportionate complexity
- Escalate to human if ambiguous

## External PRs
- The idea matters, the exact code doesn't
- OK to reimplement rather than iterate on the PR

# Merge Strategy
<!-- squash (default), merge, or rebase -->
squash

# Repo-Specific Rules
<!-- Anything unique to this project. -->
- Example: Treat changes to the billing module as risk:high
```

Sections are optional. Omitted sections use sensible defaults. The agent interprets this document alongside the built-in system instructions.

## npm Package: `repo-policy-bot`

### CLI Commands

```bash
# Full setup — scaffolds everything
npx repo-policy-bot init

# Recreate/sync labels on the repo
npx repo-policy-bot labels
```

### `init` Flow

1. Detect repo root (find `.git/`)
2. Check for `gh` CLI availability
3. Create `.github/workflows/policy-agent.yml` — **skip if exists**, print warning
4. Create `.github/workflows/gate-runner.yml` — **skip if exists**, print warning
5. Create `.github/workflows/release-runner.yml` — **skip if exists**, print warning
6. Create `.github/repo-policy.md` (starter template) — **skip if exists**, print warning
7. Create labels via `gh label create` (skip existing, update descriptions on existing)
8. Check for `ANTHROPIC_API_KEY` repo secret — prompt user to add if missing
9. Print summary of what was created vs. skipped

### `labels` Flow

1. Read expected label taxonomy from `labels.ts`
2. List existing repo labels via `gh label list`
3. Create missing labels with correct name, color, and description
4. Update description/color on existing labels if they differ
5. Never delete labels — only additive

### Package Structure

```
repo-policy-bot/
├── package.json
├── bin/cli.js                    # CLI entry point
├── src/
│   ├── commands/
│   │   ├── init.ts               # Scaffold workflows + policy + labels
│   │   └── labels.ts             # Sync labels
│   ├── templates/
│   │   ├── policy-agent.yml      # Workflow template
│   │   ├── gate-runner.yml       # Workflow template
│   │   ├── release-runner.yml    # Workflow template
│   │   ├── repo-policy.md        # Starter policy
│   │   └── system-prompt.md      # Built-in agent instructions
│   └── labels.ts                 # Label taxonomy definition
└── README.md
```

## System Prompt (Built-In)

The system prompt is the core IP. It's what turns `claude-code-action` into a repo maintainer. It encodes:

- The label state machine and transitions
- Default risk classification rules
- Merge and release gate definitions
- Adversarial input defense (deception checks)
- How to read and apply the user's policy file
- Decision-making framework for bugs, features, PRs
- When to act autonomously vs. escalate to human

This lives in the npm package as `system-prompt.md` and gets injected into the `claude-code-action` prompt alongside the user's policy file. Users don't edit this — it's the framework.

The system prompt is **generic** — it references only the label taxonomy, state machine, and decision framework. It contains no repo-specific CI check names, languages, or tools. All repo-specific behavior comes from the user's policy file. The system prompt tells the agent to check whatever CI checks the repo has configured, not to look for specific named checks.

## Cost and Rate Limiting

- **Concurrency:** Each workflow uses `concurrency` groups keyed by issue/PR number. Only one agent run per item at a time; new triggers cancel in-progress runs.
- **Trigger filtering:** The Policy Agent skips closed items and bot-applied labels to avoid unnecessary invocations.
- **Model selection:** The workflow template defaults to `claude-sonnet-4-6` for cost efficiency. Users can override to `claude-opus-4-6` in the workflow file for higher quality at higher cost.
- **Max turns:** `claude-code-action` supports `--max-turns` to cap agent reasoning loops. Default to 30 turns. The system prompt instructs the agent to self-limit (triage quickly, spend more turns on implementation) rather than bifurcating at the workflow level.
- **Documentation:** README includes expected per-invocation cost estimates and guidance for high-traffic repos (e.g., limit triggers to `labeled` events only, disable implementation for cost control).

## Security Considerations

- **API key management:** Stored as GitHub repo secret, never in code
- **Permission scoping:** Workflows request minimum needed permissions
- **Adversarial input defense:** System prompt includes deception detection instructions
- **Merge restrictions:** Agent cannot merge directly — Gate Runner is a separate, auditable workflow
- **Risk escalation:** `risk:high` always requires human approval, enforced by Gate Runner
- **No secrets in policy:** Policy file is committed to repo, should contain no secrets

## User Journey

1. User discovers `repo-policy-bot` (README, blog post, word of mouth)
2. Runs `npx repo-policy-bot init` in their repo
3. Adds `ANTHROPIC_API_KEY` as repo secret
4. Edits `.github/repo-policy.md` to describe their project's values and risk boundaries
5. Commits and pushes the workflow files
6. Next issue or PR triggers the Policy Agent
7. Agent triages, labels, reviews, and implements as appropriate
8. Gate Runner auto-merges when gates pass
9. Release Runner cuts releases when version-bumping PRs merge
10. User intervenes only for `risk:high` or `release:major` items
