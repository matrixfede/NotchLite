#!/usr/bin/env python3
"""Forward Claude Code/Codex hook states over a dedicated SSH connection."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

EVENTS = {"UserPromptSubmit": "working", "PostToolUse": "working",
          "PermissionRequest": "approval", "Stop": "completed", "SessionEnd": "end"}


def event_from_hook(agent, kind, payload):
    if not isinstance(payload, dict):
        raise ValueError("Expected hook object")
    session = payload.get("session_id")
    if not isinstance(session, str) or not session or len(session.encode()) > 200:
        raise ValueError("Missing or invalid session_id")
    return {"agent": agent, "kind": kind, "session": session,
            "cwd": str(payload.get("cwd", ""))[:512],
            "tool": str(payload.get("tool_name", ""))[:80], "ts": time.time()}


def install(args):
    path = Path(args.settings).expanduser() if args.settings else (
        Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "settings.json"
        if args.agent == "claude" else
        Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "hooks.json")
    root = json.loads(path.read_text()) if path.exists() else {}
    hooks = root.setdefault("hooks", {})
    script = str(Path(__file__).resolve())
    prefix = shlex.join([sys.executable, script, "send"])
    for event, kind in EVENTS.items():
        groups = hooks.setdefault(event, [])
        # Remove only our exact command prefix, preserving every other hook.
        kept = []
        for group in groups:
            group = dict(group)
            group["hooks"] = [h for h in group.get("hooks", [])
                              if not str(h.get("command", "")).startswith(prefix + " ")]
            if group["hooks"]:
                kept.append(group)
        command = shlex.join([sys.executable, script, "send", "--target", args.target,
                              "--agent", args.agent, "--kind", kind])
        kept.append({"hooks": [{"type": "command", "command": command}]})
        hooks[event] = kept
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        shutil.copy2(path, path.with_name(path.name + f".notchlite-{time.time_ns()}.bak"))
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(root, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Installed {args.agent} hooks in {path}. Start a new CLI session.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "send"])
    parser.add_argument("--target", required=True, help="Dedicated SSH alias for the Mac")
    parser.add_argument("--agent", required=True, choices=["claude", "codex"])
    parser.add_argument("--kind", choices=list(set(EVENTS.values())))
    parser.add_argument("--settings", help="Override hook settings path (install only)")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@-]{0,200}", args.target):
        parser.error("Invalid SSH alias")
    if args.action == "install":
        install(args)
        return
    if not args.kind:
        parser.error("send requires --kind")
    try:
        raw = sys.stdin.buffer.read(1048577)
        if len(raw) > 1048576:
            raise ValueError("Hook payload too large")
        event = event_from_hook(args.agent, args.kind, json.loads(raw))
        result = subprocess.run(
            ["ssh", "-T", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
             "-oConnectTimeout=2", args.target, "notchlite-event"],
            input=json.dumps(event).encode(), stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=4, check=False)
        if result.returncode:
            print("NotchLite: remote event not delivered (check dedicated SSH alias).", file=sys.stderr)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(f"NotchLite: event skipped ({type(error).__name__}).", file=sys.stderr)
    # Monitoring must never fail a tool or emit an approval response.


if __name__ == "__main__":
    main()
