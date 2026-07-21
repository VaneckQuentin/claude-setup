#!/usr/bin/env python3
"""Pure-function tests for ollama-delegate server.py path confinement helpers.

No Ollama, no network, no test framework. Plain asserts + prints; exits
nonzero if anything fails. Builds fake trees under mktemp — never touches
the real $HOME.
"""
import importlib.util
import os
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER_PATH = os.path.join(
    REPO_ROOT, "home/claude/mcp-servers/ollama-delegate/server.py"
)

spec = importlib.util.spec_from_file_location("ollama_delegate_server", SERVER_PATH)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

failures = []


def expect_ok(label, fn, *a, **kw):
    try:
        fn(*a, **kw)
    except ValueError as e:
        print(f"FAIL: {label} (unexpected ValueError: {e})")
        failures.append(label)
    else:
        print(f"PASS: {label}")


def expect_raises(label, fn, *a, **kw):
    try:
        fn(*a, **kw)
    except ValueError:
        print(f"PASS: {label}")
    else:
        print(f"FAIL: {label} (expected ValueError, none raised)")
        failures.append(label)


# ---- validate_save_path ----------------------------------------------------

with tempfile.TemporaryDirectory() as cwd_dir:
    cwd_real = os.path.realpath(cwd_dir)

    expect_ok(
        "write allowed: file directly in cwd",
        server.validate_save_path,
        os.path.join(cwd_dir, "out.txt"),
        bases=[cwd_real],
    )

    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_real = os.path.realpath(tmp_dir)
        expect_ok(
            "write allowed: file in system temp dir",
            server.validate_save_path,
            os.path.join(tmp_dir, "out.txt"),
            bases=[cwd_real, tmp_real],
        )

    expect_raises(
        "write rejected: ~/.zshrc",
        server.validate_save_path,
        "~/.zshrc",
        bases=[cwd_real],
    )

    expect_raises(
        "write rejected: ~/.claude/settings.json",
        server.validate_save_path,
        "~/.claude/settings.json",
        bases=[cwd_real],
    )

    escape_path = os.path.join(cwd_dir, "..", "escaped.txt")
    expect_raises(
        "write rejected: cwd/../escape",
        server.validate_save_path,
        escape_path,
        bases=[cwd_real],
    )

    # Symlink inside cwd pointing at $HOME must not allow escaping via cwd.
    home_real = os.path.realpath(os.path.expanduser("~"))
    link_path = os.path.join(cwd_dir, "escape_link")
    os.symlink(home_real, link_path)
    expect_raises(
        "write rejected: symlink inside cwd pointing to $HOME",
        server.validate_save_path,
        os.path.join(link_path, "pwned.txt"),
        bases=[cwd_real],
    )

    # A sibling directory whose name merely starts with the allowed base's
    # name (e.g. /tmp vs /tmpevil) must not pass a naive substring check —
    # locks in the `base + os.sep` boundary guard in _is_under().
    sibling_dir = cwd_real + "evil"
    expect_raises(
        "write rejected: sibling dir with allowed-base name prefix (/tmp-vs-/tmpevil style)",
        server.validate_save_path,
        os.path.join(sibling_dir, "file.txt"),
        bases=[cwd_real],
    )

# Sanity check on the real, default bases (no override) — should still allow
# a file in the process' actual cwd.
expect_ok(
    "write allowed: default bases, file in real process cwd",
    server.validate_save_path,
    os.path.join(os.getcwd(), "out.txt"),
)

# OLLAMA_DELEGATE_WRITE_DIRS extends the default bases at call time.
with tempfile.TemporaryDirectory() as extra_dir:
    old_env = os.environ.get("OLLAMA_DELEGATE_WRITE_DIRS")
    os.environ["OLLAMA_DELEGATE_WRITE_DIRS"] = extra_dir
    try:
        expect_ok(
            "write allowed: OLLAMA_DELEGATE_WRITE_DIRS extra base",
            server.validate_save_path,
            os.path.join(extra_dir, "out.txt"),
        )
    finally:
        if old_env is None:
            os.environ.pop("OLLAMA_DELEGATE_WRITE_DIRS", None)
        else:
            os.environ["OLLAMA_DELEGATE_WRITE_DIRS"] = old_env


# ---- validate_read_path -----------------------------------------------------

with tempfile.TemporaryDirectory() as fake_home:
    expect_raises(
        "read rejected: ~/.ssh/id_rsa-shaped path",
        server.validate_read_path,
        os.path.join(fake_home, ".ssh", "id_rsa"),
        home=fake_home,
    )
    expect_raises(
        "read rejected: file directly under ~/.aws (dir itself, not just deep paths)",
        server.validate_read_path,
        os.path.join(fake_home, ".aws", "credentials"),
        home=fake_home,
    )
    expect_raises(
        "read rejected: file directly under ~/.claude (dir itself, not just deep paths)",
        server.validate_read_path,
        os.path.join(fake_home, ".claude", "settings.json"),
        home=fake_home,
    )
    expect_raises(
        "read rejected: ~/.git-credentials",
        server.validate_read_path,
        os.path.join(fake_home, ".git-credentials"),
        home=fake_home,
    )
    expect_raises(
        "read rejected: .env",
        server.validate_read_path,
        os.path.join(fake_home, "project", ".env"),
        home=fake_home,
    )
    expect_raises(
        "read rejected: foo.key",
        server.validate_read_path,
        os.path.join(fake_home, "project", "foo.key"),
        home=fake_home,
    )
    expect_raises(
        "read rejected: foo.p12",
        server.validate_read_path,
        os.path.join(fake_home, "project", "foo.p12"),
        home=fake_home,
    )
    expect_ok(
        "read allowed: normal project file",
        server.validate_read_path,
        os.path.join(fake_home, "project", "notes.txt"),
        home=fake_home,
    )


if failures:
    print(f"\n{len(failures)} FAILURE(S): {failures}")
    sys.exit(1)
print("\nAll checks passed.")
