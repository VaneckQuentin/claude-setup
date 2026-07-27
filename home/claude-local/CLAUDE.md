# FULL-LOCAL mode — operating rules

You are running entirely on LOCAL Ollama models (native Anthropic endpoint, no
proxy). There is no paid API here: tokens are FREE. The scarce resources are
wall-clock time, your own context QUALITY (local models degrade on long
context well before the window is full), and review independence. Optimize
for those — the hybrid-mode token-saving reflexes do not apply.

## Dispatch (local calculus)

A subagent spawn re-prefills its ~25K-token system prompt at local speeds —
real seconds of overhead before any work starts. Delegate only when it buys
one of the two things that matter here: **context protection** (the work
would drag volumes of file/log content into your context) or **speed** (the
recon model is much faster than you).

- **Edit inline by default.** With the default roles.conf the `implementer`
  runs the same model as you (`code` = `orchestrator`) — a spawn buys no
  quality and costs a prefill. Spawn it only when the change needs heavy
  reading you don't want polluting your context, or if you've assigned
  `code` a stronger model than yours.
- **Sequential, never parallel.** Ollama serves ONE request per model at a
  time — "parallel" subagents serialize and just stack prefill overhead. Run
  subtasks one after another.
- **Use `explorer` liberally** (`explore` role, fast recon model) for heavy
  "where/how is X" sweeps and large-file scans — the one genuinely faster
  tier. Light lookups (a few small files): read them yourself.
- **`ollama_run` tool** for one-shot grunt work (summarize, classify, draft):
  `model:"cheap"` for text, `model:"code"` for code-ish; pass inputs by path
  via `files`.
- **reverse-engineer** (`reverse` role) for binary/protocol/obfuscated
  analysis — needs a tool-capable model to drive radare2.

## Review (know its limits here)

With the default roles.conf the local `reviewer` runs the same model as the
implementer — same blind spots, correlated misses. Treat local review as a
smoke check: a fresh context catches slips, not subtle bugs. For any diff that matters, escalate:
review it in HYBRID mode (`claude`) — a diff review costs almost nothing in
API tokens and is the best hybrid/local synergy available.

## Testing discipline

- Bug fix: write a failing repro test FIRST, confirm it fails, then fix,
  then confirm green.
- New behavior with a clear spec: same — test first, red, then implement to
  green. Skip for config, one-liners, throwaway scripts.
- Never weaken or adapt a test to make code pass — report a suspect test
  instead.

## Code quality bar

- Readable, self-explanatory names; functions split by responsibility.
- Simplest design that works — no speculative abstraction; a design pattern
  only when the problem demands it.
- Follow the codebase's existing conventions over personal preference.

## What NOT to do

- Don't chain many speculative steps — local models drift. Decide, act, verify.
- Don't fan out parallel subagents — see Dispatch: it buys nothing here.
- If a subagent returns something incoherent, retry ONCE with a tighter brief
  or do it yourself rather than compounding the error.
- Don't litter the repo root with working files. Scratch artifacts (dumps,
  one-off scripts, extracted data, notes) go to the session scratchpad or ONE
  untracked dir (e.g. `.work/`); deliverables follow the project's existing
  layout.

To change which model a role uses: edit `~/.claude/local-mode/roles.conf`, run
`sync-local.sh`, then relaunch `claude --local`. Keep the Ollama server tuned:
context length >= 64K and `OLLAMA_KEEP_ALIVE` >= 30 min (1h or -1
recommended; the default 5m unloads the orchestrator between turns) —
`claude-local --status` checks both.
