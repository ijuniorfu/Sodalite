#!/usr/bin/env python3
"""Publish ROADMAP.md into a single, self-updating Discord message.

The message is created once and edited from then on, so the channel holds one
pinned roadmap rather than a growing pile of copies.

Environment:
  DISCORD_ROADMAP_WEBHOOK     webhook URL of the target channel (required)
  DISCORD_ROADMAP_MESSAGE_ID  id of the message to edit; unset means "post a
                              new one and print its id"

Usage:
  Scripts/roadmap-to-discord.py [--dry-run] [--roadmap PATH]
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

REPO_URL = "https://github.com/superuser404notfound/Sodalite"
ROADMAP_URL = f"{REPO_URL}/blob/main/ROADMAP.md"
EMBED_TITLE = "Sodalite roadmap"
EMBED_COLOR = 0x007AFF  # the app's accent
DESCRIPTION_LIMIT = 4096
USER_AGENT = "Sodalite-Roadmap/1.0 (+%s)" % REPO_URL


def unwrap(markdown: str) -> str:
    """Join a paragraph's hard-wrapped lines.

    The file wraps at column 98 for the sake of a diff. Discord honours every
    single newline, so shipping those wraps breaks sentences mid-air in a
    column half that wide. Headings, list items, quotes and fenced blocks keep
    their own lines.
    """
    out: list[str] = []
    paragraph: list[str] = []
    fenced = False

    def flush() -> None:
        if paragraph:
            out.append(" ".join(paragraph))
            paragraph.clear()

    for line in markdown.splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            flush()
            fenced = not fenced
            out.append(line)
        elif fenced:
            out.append(line)
        elif not stripped or stripped[0] in "#-*>|" or stripped[:2].rstrip(".").isdigit():
            flush()
            out.append(line)
        else:
            paragraph.append(stripped)
    flush()
    return "\n".join(out)


def build_description(markdown: str) -> str:
    """Drop the file's own H1 (the embed carries the title) and fit the limit."""
    lines = markdown.splitlines()
    if lines and lines[0].startswith("# "):
        lines = lines[1:]
    body = unwrap("\n".join(lines)).strip()

    if len(body) <= DESCRIPTION_LIMIT:
        return body

    tail = f"\n\n[Read the rest on GitHub]({ROADMAP_URL})"
    budget = DESCRIPTION_LIMIT - len(tail)
    cut = body.rfind("\n### ", 0, budget)
    if cut == -1:
        cut = body.rfind("\n\n", 0, budget)
    if cut == -1:
        cut = budget
    return body[:cut].rstrip() + tail


def build_payload(description: str) -> dict:
    return {
        "embeds": [
            {
                "title": EMBED_TITLE,
                "url": ROADMAP_URL,
                "description": description,
                "color": EMBED_COLOR,
                "footer": {"text": "Updated automatically from ROADMAP.md"},
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
        ],
        "allowed_mentions": {"parse": []},
    }


def request(method: str, url: str, payload: dict) -> dict:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", USER_AGENT)
    with urllib.request.urlopen(req, timeout=30) as response:
        raw = response.read().decode("utf-8")
    return json.loads(raw) if raw else {}


def send(method: str, url: str, payload: dict) -> dict:
    """One retry, and only for a rate limit, which is the one retryable answer."""
    for attempt in range(2):
        try:
            return request(method, url, payload)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")
            if error.code == 429 and attempt == 0:
                try:
                    wait = float(json.loads(body).get("retry_after", 1.0))
                except (ValueError, AttributeError):
                    wait = 1.0
                print(f"rate limited, retrying in {wait:.1f}s", file=sys.stderr)
                time.sleep(min(wait, 30.0))
                continue
            raise SystemExit(f"discord answered {error.code}: {body}")
    raise SystemExit("discord kept rate limiting")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="print the payload instead of sending it")
    parser.add_argument("--roadmap", default="ROADMAP.md")
    args = parser.parse_args()

    try:
        with open(args.roadmap, encoding="utf-8") as handle:
            markdown = handle.read()
    except OSError as error:
        raise SystemExit(f"cannot read {args.roadmap}: {error}")

    description = build_description(markdown)
    payload = build_payload(description)
    print(f"description: {len(description)} of {DESCRIPTION_LIMIT} characters")

    if args.dry_run:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return

    webhook = (os.environ.get("DISCORD_ROADMAP_WEBHOOK") or "").strip()
    if not webhook:
        raise SystemExit("DISCORD_ROADMAP_WEBHOOK is not set")
    webhook = webhook.rstrip("/")
    message_id = (os.environ.get("DISCORD_ROADMAP_MESSAGE_ID") or "").strip()

    if message_id:
        try:
            send("PATCH", f"{webhook}/messages/{message_id}", payload)
            print(f"edited message {message_id}")
            return
        except SystemExit as error:
            # A deleted message must not wedge the workflow forever.
            if "404" not in str(error):
                raise
            print("message is gone, posting a fresh one", file=sys.stderr)

    created = send("POST", f"{webhook}?wait=true", payload)
    new_id = created.get("id", "")
    print(f"posted message {new_id}")
    print(
        "Set the repository variable DISCORD_ROADMAP_MESSAGE_ID to "
        f"{new_id} so the next run edits this message instead of posting again."
    )
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and new_id:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(
                "### Roadmap posted\n\nSet repository variable "
                f"`DISCORD_ROADMAP_MESSAGE_ID` to `{new_id}`, then pin the "
                "message in Discord.\n"
            )


if __name__ == "__main__":
    main()
