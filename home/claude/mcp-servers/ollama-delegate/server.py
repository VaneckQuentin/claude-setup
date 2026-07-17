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

# Semantic tiers -> concrete local models. Source of truth is
# ~/.claude/local-mode/roles.conf (tier.* lines), synced to tiers.json by
# sync-local.sh. The literals below are only a fallback if that file is absent.
TIERS_FILE = os.path.expanduser("~/.claude/local-mode/tiers.json")
FALLBACK_TIER_MODELS = {
    "code":  "qwen3-coder:30b",          # strong coder, use for real code work
    "cheap": "gemma4:latest",            # fast, for summaries/classification/drafts
    "tiny":  "llama2-uncensored:latest", # smallest, trivial text munging
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

SERVER_INFO = {"name": "ollama-delegate", "version": "1.0.0"}


def log(*a):
    print(*a, file=sys.stderr, flush=True)


TIER_MODELS = load_tier_models()


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
    for tier, name in TIER_MODELS.items():
        lines.append(f"  - {tier:5} -> {name}")
    lines.append(
        "\nGuidance: use `code` for real code generation/analysis, "
        "`cheap` for summaries/classification/commit drafts, "
        "`tiny` for trivial text munging."
    )
    return "\n".join(lines)


def tool_run(args):
    prompt = args.get("prompt")
    if not prompt:
        return "ERROR: `prompt` is required."
    model = args.get("model", "code")
    model = TIER_MODELS.get(model, model)  # allow tier alias or raw name
    system = args.get("system")
    temperature = args.get("temperature", 0.2)
    try:
        max_tokens = max(1, int(args.get("max_tokens", DEFAULT_MAX_TOKENS)))
    except (TypeError, ValueError):
        max_tokens = DEFAULT_MAX_TOKENS

    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
        "options": {"temperature": temperature, "num_predict": max_tokens},
    }
    try:
        resp = http_json("/api/chat", payload)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        return f"ERROR from Ollama ({e.code}) using model '{model}': {body}"
    except Exception as e:
        return f"ERROR calling Ollama with model '{model}': {e}"
    content = resp.get("message", {}).get("content", "")
    if len(content) > MAX_OUTPUT_CHARS:
        content = (
            content[:MAX_OUTPUT_CHARS]
            + f"\n\n[output truncated at {MAX_OUTPUT_CHARS} chars — re-run with a "
              "tighter prompt asking for a compact summary]"
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
            "code. Returns only the model's text output."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "description": "The full task/prompt for the local model."},
                "model": {
                    "type": "string",
                    "description": "Tier alias ('code','cheap','tiny') or a raw Ollama model name. Default 'code'.",
                },
                "system": {"type": "string", "description": "Optional system prompt."},
                "temperature": {"type": "number", "description": "Sampling temperature, default 0.2."},
                "max_tokens": {"type": "number", "description": "Output token cap (num_predict), default 2048. Raise only for genuinely long outputs."},
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
