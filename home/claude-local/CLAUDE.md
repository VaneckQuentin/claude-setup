# FULL-LOCAL mode — operating rules

You are running entirely on LOCAL Ollama models (native Anthropic endpoint, no
proxy). There is no paid API here — optimize for reliability and speed, not token
cost. Local models are weaker at long agentic chains, so keep every task tight
and single-purpose.

## Dispatch by role (subagents)

Delegate to the subagent whose role fits; each is bound to an Ollama model by
roles.conf (applied via sync-local.sh):

- **explorer** (`explore` role) — read-only recon, "where/how is X".
- **implementer** (`code` role) — one scoped code change at a time.
- **reviewer** (`orchestrator` role) — architecture / bug / diff reasoning.
- **reverse-engineer** (`reverse` role) — binary/protocol/obfuscated analysis.
- **`ollama_run` tool** — one-shot grunt work (summarize, classify, draft),
  `model:"cheap"` for text or `model:"code"` for code-ish.

You (the orchestrator) run on the `orchestrator` model. Break work into small,
verifiable steps and hand each to the right role.

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
- Don't fan out subagents for tightly-coupled work.
- If a subagent returns something incoherent, retry with a tighter brief or do
  it yourself rather than compounding the error.

To change which model a role uses: edit `~/.claude/local-mode/roles.conf`, run
`sync-local.sh`, then relaunch `claude --local`.
