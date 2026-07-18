# Operating rules — performance & token discipline

This machine is tuned for high performance at controlled token cost. The core
idea is NOT "many agents" — it's **context isolation + model tiering + local
offload**. Follow the dispatch rules below.

## Two runtime modes

- **Hybrid (default `claude`)**: you — whatever model this session is
  configured with (settings.json `model` / the `/model` command) — orchestrate
  on the API. Delegate volume down to cheaper tiers and to local models. This
  is the normal mode.
- **Full-local (`~/.claude/local-mode/claude-local`)**: the whole session runs
  directly on Ollama, with the models assigned in
  `~/.claude/local-mode/roles.conf`. Slower, weaker at long agentic chains;
  keep tasks tighter.

ALL model assignments (full-local roles, `ollama_run` tiers, hybrid subagent
Claude models) live in `roles.conf` — edit it, then run `sync-local.sh`. Never
assume concrete model names from memory. Subagent Claude models follow the
user's plan budget (`sync-local.sh --plan pro|max100|max200`).

The dispatch rules below apply in BOTH modes. The `ollama-delegate` MCP is the
universal "submodel per task" mechanism and works in either mode.

## Dispatch rules (default reasoning before acting)

(Condensed copy in hooks/dispatch-directive.py — keep the two in sync.)

Before doing volume work yourself, ask: *does this output need to live in my
premium context, or just its conclusion?* If only the conclusion matters,
delegate.

1. **Broad read/search** ("where is X", "how is Y wired", "list all Z") →
   spawn the `explorer` subagent (recon tier). Never read 10+ files into the
   main context yourself.
2. **Scoped code change** (a decided fix/feature in PHP, Rust, etc.) → spawn the
   `implementer` subagent (implementation tier).
3. **Hard reasoning** (architecture, tricky bug, diff review) → spawn the
   `reviewer` subagent when it needs heavy reading or an unbiased fresh
   context (e.g. reviewing work you just orchestrated); handle inline when
   the evidence is already in your context.
4. **Bounded high-volume grunt-work** (summarize a long log/file, classify,
   draft a commit message, boilerplate, first-pass "grep-and-explain") →
   delegate to a LOCAL model via the `ollama_run` tool. This costs ZERO API
   tokens. Use `model:"cheap"` for text, `model:"code"` for code-ish work.
   Pass input files by path via `files` (the server reads them locally) —
   NEVER read a file into your context just to paste it into the prompt.
   For bulky outputs you don't need verbatim, use `save_to`.
5. **Code navigation** → prefer Serena symbol tools (`find_symbol`,
   `get_symbols_overview`, `find_referencing_symbols`) over reading whole files.
6. **Real-browser work** (verify a UI change end-to-end, or any task needing a
   live page: JS-heavy sites, forms, auth flows, scraping rendered content) →
   a browser subagent via Playwright; snapshots and screenshots stay in ITS
   context, only the conclusion returns. BEFORE spawning, ask the user with
   AskUserQuestion whether they want to watch the run: visible browser window
   → spawn `browser-headed`; headless (recommended default) → spawn
   `browser-headless`. Skip the question and go headless when the user already
   said which they want, when running autonomously/unattended, or when there
   is no local graphical session (SSH/CI). For read-only fetching of static
   pages/docs, plain WebFetch/WebSearch is cheaper — no subagent needed.

## Language

- The user writes in whatever language they like (often French or English).
  Respond and WORK IN ENGLISH by default — replies, code comments, commit
  messages, subagent briefs — unless explicitly asked for another language for
  a given deliverable. English is the most token-dense language for the model
  (French costs ~20-40% more output tokens) and keeps agent handoffs
  consistent.
- Never translate or preprocess the user's prompts — read them as-is. Prompt
  input is a negligible share of session tokens; the savings live in the
  output.

## Compaction

When this conversation is compacted (auto or `/compact`), the summary MUST
preserve: the current task and its exact state, decisions made with their
rationale, file paths touched, and what is verified vs still unverified.
Drop exploration transcripts and raw tool output first — never the above.

## What NOT to do

- NEVER commit personal or sensitive data to ANY repo: credentials, tokens,
  private keys, emails, absolute home paths, session/state files (.env,
  .claude.json, history). A PreToolUse guard blocks `git commit` when staged
  changes trip these checks — fix the data, never bypass
  (CLAUDE_COMMIT_GUARD=0 requires explicit user approval).
- Don't fan out subagents for tightly-coupled work — coordination overhead can
  cost more than it saves. Parallelize only genuinely independent tasks.
- Don't delegate orchestration, design decisions, or critical/subtle code to
  local models — they are weaker at multi-step agentic reasoning.
- Don't let tool output you'll never reuse accumulate in context. Delegate it,
  or read narrowly.
- Keep CLAUDE.md and early context stable to preserve prompt caching.

## Pipelines & parallelism

- **Cross-review loop** (non-trivial diffs): `implementer` produces the change
  → spawn `reviewer` on the diff (fresh context = unbiased) → if it finds real
  bugs, `SendMessage` the findings back to the SAME implementer (context still
  warm) to fix. HARD CAP: 2 iterations, then you arbitrate. The reviewer ranks
  by severity; forward only real bugs, drop style opinions. Skip the loop
  entirely for trivial changes.
- **Parallel exploration**: independent questions → several `explorer` agents
  spawned in one message.
- **Parallel implementation**: independent changes in the same repo → several
  `implementer` agents, EACH with `isolation: "worktree"` so they don't trample
  each other's edits. Coupled changes stay sequential in ONE agent.
- **Warm agents**: prefer `SendMessage` to an existing agent over respawning —
  a fresh spawn re-derives context you already paid for. Long-running agents
  work in the background by default; keep orchestrating and collect results
  when notified.
- Local models (`ollama_run`) never review or judge — they do volume only.
  Review quality is the one place not to save.
- Review quality is RELATIVE: never review a change with a model weaker than
  the one that wrote it. The `reviewer` default fits implementer output; when
  YOU (the orchestrator) authored a high-stakes diff inline, spawn the
  reviewer with a `model` override matching your own tier.

## Feature workflow (multi-file changes)

For anything bigger than a one-file fix, the orchestrator PLANS, subagents
EXECUTE:

1. **Recon** — explorer agents (or Serena) gather what the plan needs. Never
   start implementing while the shape of the change is still unknown.
2. **Plan inline** — you are the strongest model in the session: decompose the
   feature into independent, well-scoped tasks yourself. Decide interfaces
   BETWEEN tasks up front so parallel implementers can't drift apart.
3. **Brief tightly** — each implementer starts with an EMPTY context. Its brief
   must carry everything it needs and nothing more: goal, exact files/symbols,
   contracts to respect, conventions, what NOT to touch, and a verifiable
   definition of done ("build passes, test X green"). A vague brief makes the
   agent re-explore the repo at sonnet prices — the distillation is your job.
4. **Review** — cross-review loop per the pipeline rules above.

Don't over-slice: a task that needs constant back-and-forth with you was not
independent — keep coupled edits in ONE implementer.

## Local model tiers (via ollama_run)

Semantic tiers: `code` (real code generation/analysis), `cheap` (summaries,
classification, drafts). Trivial one-liners are NOT worth a delegation
round-trip — do them inline; delegate only when the output has volume. The
tier → model mapping lives in `roles.conf` (`tier.*` lines, synced to
`tiers.json`). Run `ollama_list_models` for the live list.
