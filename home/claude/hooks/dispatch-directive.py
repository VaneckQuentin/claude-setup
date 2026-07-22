#!/usr/bin/env python3
"""
UserPromptSubmit hook — inject a dispatch protocol next to every non-trivial
prompt, so the ORCHESTRATOR (whatever model the session is configured with)
reliably decomposes and delegates instead of doing everything itself. The
orchestrator makes the routing decision (high quality); this hook only
guarantees it considers routing on every request.

Fail-open and near-zero cost: static text, no network, no local model.
Kill switch: set env CLAUDE_AUTODISPATCH=0 to disable.

NOTE: each directive is a condensed copy of the dispatch rules in the
matching CLAUDE.md (DIRECTIVE -> ~/.claude, LOCAL_DIRECTIVE ->
~/.claude-local) — if you change the rules there, mirror the change here
(and vice versa).
"""
import json
import os
import sys
import unicodedata

DIRECTIVE = """## Dispatch protocol (apply before acting)
Split this request into (a) EXPLORATION (finding/reading/searching code) and (b) REASONING/EDITING. Then route to the cheapest capable target — never redo delegated work yourself:

1. EXPLORATION — delegate to the `explorer` subagent (recon tier) ONLY when it is genuinely heavy: reading/searching 10+ files, or scanning large files/logs. Reason over the summary it returns instead of pulling all that into this context. For light lookups (fewer than 10 small files) just read them yourself — delegating there only adds latency.
2. one scoped code change (a function, a fix)               -> `implementer` subagent (implementation tier)
3. hard reasoning (architecture, tricky bug, diff review)   -> `reviewer` subagent or handle inline
4. bulk grunt text (summarize a long file/log, classify, draft) -> `ollama_run` tool (local, free) — pass inputs by path via `files`, never paste content

Spawn independent subtasks in parallel; only conclusions return here. If the whole request is one trivial step, ignore this and just answer directly — do NOT over-decompose."""

# Full-local sessions have opposite economics: tokens are free, the costs are
# wall-clock (every subagent spawn re-prefills ~25K tokens of system prompt)
# and the orchestrator's own context quality. Ollama also serves ONE request
# per model at a time, so parallel fan-out serializes anyway.
LOCAL_DIRECTIVE = """## Dispatch protocol — LOCAL mode (apply before acting)
Tokens are free here; the real costs are wall-clock time and your own context quality. Route accordingly:

1. EXPLORATION — delegate to the `explorer` subagent (fast recon model) when it is heavy: reading/searching 10+ files, or scanning large files/logs. Reason over its summary. Light lookups: read them yourself.
2. code edits -> do them INLINE by default (with the default roles.conf the implementer runs the same model as you — a spawn buys no quality and costs a full prompt prefill). Spawn `implementer` only when the change needs heavy reading that would bloat your context.
3. bulk grunt text (summarize a long file/log, classify, draft) -> `ollama_run` tool — pass inputs by path via `files`, never paste content.
4. Run subtasks SEQUENTIALLY — Ollama serves one request per model at a time; parallel subagents serialize and just stack prefill overhead.

If the whole request is one trivial step, ignore this and just answer directly — do NOT over-decompose."""


def is_local_session():
    """True when this session runs full-local (claude --local sets
    CLAUDE_CONFIG_DIR=~/.claude-local; hooks inherit the session env)."""
    conf_dir = os.environ.get("CLAUDE_CONFIG_DIR", "").rstrip("/")
    return os.path.basename(conf_dir) == ".claude-local"


def main():
    if os.environ.get("CLAUDE_AUTODISPATCH", "1") == "0":
        return  # disabled
    try:
        data = json.load(sys.stdin)
    except Exception:
        return  # fail-open
    # Field is `prompt` in practice; `user_prompt` kept as a version fallback.
    prompt = (data.get("prompt") or data.get("user_prompt") or "").strip()

    # Guards: skip slash commands and clearly trivial one-liners.
    if prompt.startswith("/"):
        return
    if len(prompt.split()) < 4:
        return

    # Bulk-intent gate: only inject when the request implies EXHAUSTIVE / bulk
    # work (the only case where delegation pays — measured on a large work PHP
    # codebase: always-on cost +31% on normal surgical exploration). Gate on
    # quantifiers and explicit bulk phrasing, NOT on "summarize" alone (which
    # appears in single-flow requests like "summarize the flow").
    # Matching is accent-insensitive: signals below are written WITHOUT accents
    # and the prompt is stripped of its accents before comparison.
    low = "".join(
        c for c in unicodedata.normalize("NFD", prompt.lower())
        if not unicodedata.combining(c)
    )
    BULK_SIGNALS = (
        "every ", "each file", "each of", "each controller", "each model",
        "each module", "all files", "all the ", "all controllers", "all models",
        "all classes", "all functions", "all endpoints", "all routes",
        "all the files", "across the whole", "across the entire",
        "across the codebase", "across the repo", "throughout the",
        "entire codebase", "whole codebase", "entire module", "whole module",
        "one-line", "one line summary", "summarize all", "summarize every",
        "summarise all", "summarise every", "list all", "list every",
        "for each", "go through all", "go through every", "enumerate",
        "classify", "categorize", "categorise", "audit all", "batch of",
        " logs", "log file", "log files", "these files", "all of them",
        # French (accent-free — the prompt is de-accented before matching)
        "tous les ", "toutes les ", "chaque fichier", "chaque module",
        "chaque controleur", "chaque classe", "chaque fonction", "pour chaque",
        "chacun des", "chacune des", "l'ensemble des", "l'ensemble du",
        "tout le code", "toute la codebase", "tout le repo", "tout le projet",
        "dans tout le", "dans toute la", "a travers tout",
        "liste tous", "liste toutes", "lister tous", "lister toutes",
        "resume tous", "resume toutes", "resumer tous", "resumer toutes",
        "enumere", "enumerer", "classifie", "categorise les", "trie les",
        "un par un", "une par une", "fichier par fichier",
        "parcours tous", "parcourir tous", "audit complet", "audite tout",
        "ces fichiers", "fichiers de log", "les logs",
    )
    if not any(sig in low for sig in BULK_SIGNALS):
        return  # not bulk -> no injection, no overhead

    out = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": LOCAL_DIRECTIVE if is_local_session() else DIRECTIVE,
        }
    }
    sys.stdout.write(json.dumps(out))


if __name__ == "__main__":
    main()
