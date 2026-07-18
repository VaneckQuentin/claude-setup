#!/usr/bin/env python3
"""
Ollama delegation MCP server (stdio, zero external deps).

Lets the orchestrator (Claude in hybrid mode, or a local model in full-local
mode) hand bounded, high-volume, low-stakes work to LOCAL Ollama models so it
never touches the paid API context. Only the compact result comes back.

Tools:
  - ollama_list_models : discover local models + when to use each
  - ollama_run         : run a one-shot prompt on a chosen local model

Protocol: MCP over stdio, newline-delimited JSON-RPC 2.0. Stdlib only.
"""
import json
import os
import sys
import urllib.request
import urllib.error

OLLAMA_URL = "http://localhost:11434"
DEFAULT_TIMEOUT = 600      # seconds; big models can be slow on first token
DEFAULT_MAX_TOKENS = 2048  # num_predict cap — delegation returns conclusions, not dumps
MAX_OUTPUT_CHARS = 20000   # hard cap on what flows back into the caller's context
MAX_INPUT_CHARS = 300000   # total cap on injected file content (~75-90K tokens)
KEEP_ALIVE = "30m"         # keep the model loaded between delegations in a session
MAX_NUM_CTX = 131072       # request-level context ceiling (KV cache is RAM)

# Semantic tiers -> concrete local models. Source of truth is
# ~/.claude/local-mode/roles.conf (tier.* lines), synced to tiers.json by
# sync-local.sh. The literals below are only a fallback if that file is absent.
TIERS_FILE = os.path.expanduser("~/.claude/local-mode/tiers.json")
FALLBACK_TIER_MODELS = {
    "code":  "laguna-xs-2.1",  # strong agentic coder, use for real code work
    "cheap": "gemma4:12b",     # fast, for summaries/classification/drafts
}


def load_tier_models():
    try:
        with open(TIERS_FILE) as f:
            data = json.load(f)
        tiers = {k: v for k, v in data.items()
                 if not k.startswith("_") and isinstance(v, str) and v}
        if tiers:
            return tiers
    except Exception as e:
        log(f"[ollama-delegate] tiers.json unreadable ({e}), using fallback tiers")
    return dict(FALLBACK_TIER_MODELS)

SERVER_INFO = {"name": "ollama-delegate", "version": "1.1.0"}


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# Re-read tiers.json when it changes (sync-local.sh rewrites it mid-session);
# an mtime check keeps the per-call cost at one stat().
_tier_cache = {"mtime": None, "tiers": dict(FALLBACK_TIER_MODELS)}


def tier_models():
    try:
        mtime = os.path.getmtime(TIERS_FILE)
    except OSError:
        return _tier_cache["tiers"]
    if mtime != _tier_cache["mtime"]:
        _tier_cache["tiers"] = load_tier_models()
        _tier_cache["mtime"] = mtime
    return _tier_cache["tiers"]


def http_json(path, payload, timeout=DEFAULT_TIMEOUT):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        OLLAMA_URL + path, data=data,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def ollama_tags():
    req = urllib.request.Request(OLLAMA_URL + "/api/tags", method="GET")
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode("utf-8"))


# ---- tool implementations -------------------------------------------------

def tool_list_models(_args):
    try:
        tags = ollama_tags()
    except Exception as e:
        return f"Could not reach Ollama at {OLLAMA_URL}: {e}"
    lines = ["Local Ollama models available:\n"]
    for m in tags.get("models", []):
        size = round(m.get("size", 0) / 1e9, 1)
        params = m.get("details", {}).get("parameter_size", "?")
        lines.append(f"  - {m['name']}  ({params}, {size}GB)")
    lines.append("\nSuggested tiers (pass as `model`):")
    for tier, name in tier_models().items():
        lines.append(f"  - {tier:5} -> {name}")
    lines.append(
        "\nGuidance: use `code` for real code generation/analysis, "
        "`cheap` for summaries/classification/commit drafts. Trivial "
        "one-liners aren't worth delegating — do them inline. Pass input "
        "files by path via `files` — never paste their content into the "
        "prompt."
    )
    return "\n".join(lines)


def read_files(paths):
    """Read local files into prompt blocks. Returns (blocks, error)."""
    blocks, budget = [], MAX_INPUT_CHARS
    for p in paths:
        full = os.path.expanduser(str(p))
        try:
            with open(full, encoding="utf-8", errors="replace") as f:
                content = f.read(budget + 1)
        except OSError as e:
            return None, f"ERROR: cannot read file '{p}': {e}"
        note = ""
        if len(content) > budget:
            content = content[:budget]
            note = f"\n[... truncated: {MAX_INPUT_CHARS}-char total budget reached]"
        budget -= len(content)
        blocks.append(f"=== FILE: {p} ===\n{content}{note}")
        if budget <= 0:
            break
    return blocks, None


def tool_run(args):
    prompt = args.get("prompt")
    if not prompt:
        return "ERROR: `prompt` is required."
    model = args.get("model", "code")
    model = tier_models().get(model, model)  # allow tier alias or raw name
    system = args.get("system")
    temperature = args.get("temperature", 0.2)
    think = bool(args.get("think", False))
    save_to = args.get("save_to")
    try:
        max_tokens = max(1, int(args.get("max_tokens", DEFAULT_MAX_TOKENS)))
    except (TypeError, ValueError):
        max_tokens = DEFAULT_MAX_TOKENS

    # Inject file content server-side so the caller never pays tokens for it.
    files = args.get("files") or []
    if files:
        blocks, err = read_files(files)
        if err:
            return err
        prompt = "\n\n".join(blocks) + "\n\n=== TASK ===\n" + prompt

    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    # Size the context to the actual input (~3 chars/token + output headroom)
    # instead of relying on the server default, which may be tiny.
    input_chars = len(prompt) + len(system or "")
    num_ctx = min(MAX_NUM_CTX, max(16384, input_chars // 3 + max_tokens + 1024))

    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
        "think": think,  # off by default: delegation wants answers, not latency
        "keep_alive": KEEP_ALIVE,
        "options": {"temperature": temperature, "num_predict": max_tokens,
                    "num_ctx": num_ctx},
    }
    try:
        resp = http_json("/api/chat", payload)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        # Some models reject the `think` field outright — retry without it.
        if "think" in body.lower():
            payload.pop("think", None)
            try:
                resp = http_json("/api/chat", payload)
            except Exception as e2:
                return f"ERROR calling Ollama with model '{model}': {e2}"
        else:
            return f"ERROR from Ollama ({e.code}) using model '{model}': {body}"
    except Exception as e:
        return f"ERROR calling Ollama with model '{model}': {e}"
    content = resp.get("message", {}).get("content", "")

    if save_to:
        full = os.path.expanduser(str(save_to))
        try:
            with open(full, "w", encoding="utf-8") as f:
                f.write(content)
        except OSError as e:
            return f"ERROR: model answered but writing '{save_to}' failed: {e}"
        head = content[:500]
        return (f"Saved {len(content)} chars to {save_to}. First lines:\n{head}"
                + ("\n[...]" if len(content) > 500 else ""))

    if len(content) > MAX_OUTPUT_CHARS:
        content = (
            content[:MAX_OUTPUT_CHARS]
            + f"\n\n[output truncated at {MAX_OUTPUT_CHARS} chars — re-run with a "
              "tighter prompt asking for a compact summary, or use `save_to`]"
        )
    return content or "(empty response)"


TOOLS = [
    {
        "name": "ollama_list_models",
        "description": (
            "List local Ollama models and the recommended tier for each. "
            "Call this first if unsure which local model to delegate to."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "ollama_run",
        "description": (
            "Delegate a bounded, self-contained task to a LOCAL Ollama model "
            "(free, no API tokens). Ideal for: summarizing long logs/files, "
            "classification, drafting commit messages, boilerplate, first-pass "
            "'grep-and-explain'. NOT for multi-step orchestration or critical "
            "code. Pass input files via `files` (the server reads them locally "
            "— never paste file content into the prompt). Returns only the "
            "model's text output."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "description": "The full task/prompt for the local model."},
                "model": {
                    "type": "string",
                    "description": "Tier alias ('code','cheap') or a raw Ollama model name. Default 'code'.",
                },
                "files": {
                    "type": "array", "items": {"type": "string"},
                    "description": "Absolute paths of files to inject into the prompt, read server-side at zero caller cost. ALWAYS use this instead of pasting file content.",
                },
                "system": {"type": "string", "description": "Optional system prompt."},
                "temperature": {"type": "number", "description": "Sampling temperature, default 0.2."},
                "max_tokens": {"type": "number", "description": "Output token cap (num_predict), default 2048. Raise only for genuinely long outputs."},
                "think": {"type": "boolean", "description": "Enable the model's thinking mode (default false — it mostly adds latency for grunt work)."},
                "save_to": {"type": "string", "description": "Write the full output to this file instead of returning it; returns a short confirmation + preview. Use for bulky outputs the caller doesn't need verbatim."},
            },
            "required": ["prompt"],
            "additionalProperties": False,
        },
    },
]

HANDLERS = {"ollama_list_models": tool_list_models, "ollama_run": tool_run}


# ---- JSON-RPC / MCP plumbing ---------------------------------------------

def make_result(id_, result):
    return {"jsonrpc": "2.0", "id": id_, "result": result}


def make_error(id_, code, message):
    return {"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": message}}


def handle(msg):
    method = msg.get("method")
    id_ = msg.get("id")
    is_request = id_ is not None

    if method == "initialize":
        client_ver = (msg.get("params") or {}).get("protocolVersion", "2024-11-05")
        return make_result(id_, {
            "protocolVersion": client_ver,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        })

    if method in ("notifications/initialized", "initialized"):
        return None  # notification, no response

    if method == "ping":
        return make_result(id_, {})

    if method == "tools/list":
        return make_result(id_, {"tools": TOOLS})

    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        fn = HANDLERS.get(name)
        if not fn:
            return make_error(id_, -32602, f"Unknown tool: {name}")
        try:
            text = fn(args)
        except Exception as e:
            text = f"Tool crashed: {e}"
        return make_result(id_, {"content": [{"type": "text", "text": str(text)}]})

    if is_request:
        return make_error(id_, -32601, f"Method not found: {method}")
    return None  # unknown notification


def main():
    log(f"[ollama-delegate] up, talking to {OLLAMA_URL}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        try:
            resp = handle(msg)
        except Exception as e:
            resp = make_error(msg.get("id"), -32603, f"Internal error: {e}")
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
