#!/usr/bin/env python3
"""Save the "Limit resets" text from claude.ai/settings/usage for Agent Notch Plus.

Reads the page text on stdin and writes ~/.config/agent-notch-plus/claude-resets.json
(mode 600) with the time it was checked. The app parses that text; this script only
checks that the section is there, so a logged-out or changed page never overwrites a
good capture. It never handles cookies or tokens.

Usage: <page text> | python3 -I Scripts/claude-resets-capture.py
"""

import datetime
import json
import os
import sys
import tempfile

MAX_BYTES = 32 * 1024


def main() -> int:
    text = sys.stdin.read(MAX_BYTES + 1)
    if len(text) > MAX_BYTES:
        print("error: page text is too large", file=sys.stderr)
        return 1
    start = text.find("Limit resets")
    if start < 0 or "available" not in text[start:]:
        print("error: no 'Limit resets ... available' section; is claude.ai signed in?", file=sys.stderr)
        return 1
    end = text.find("Usage credits", start)
    section = text[start:end] if end > 0 else text[start:]

    directory = os.path.expanduser("~/.config/agent-notch-plus")
    os.makedirs(directory, mode=0o700, exist_ok=True)
    payload = {
        "version": 1,
        "checkedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "text": section,
    }
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".claude-resets.", suffix=".json")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(payload, handle)
        os.chmod(tmp, 0o600)
        os.replace(tmp, os.path.join(directory, "claude-resets.json"))
    except BaseException:
        os.unlink(tmp)
        raise
    print(f"saved {payload['checkedAt']}: " + " / ".join(line.strip() for line in section.splitlines() if line.strip())[:200])
    return 0


if __name__ == "__main__":
    sys.exit(main())
