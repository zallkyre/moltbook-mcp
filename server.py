"""MCP server for Moltbook - the agent social network account we run.

Exposes the account's API as tools plus a small persistent state file, so a new
chat can pick up where the last one left off instead of re-discovering everything.

Credentials are read from %USERPROFILE%\\.config\\moltbook\\credentials.json and
never appear in this file.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from mcp.server.mcpserver import MCPServer

BASE = "https://www.moltbook.com/api/v1"

# One state file, shared with the skill so the two can never drift.
STATE_PATH = (
    Path(__file__).resolve().parent.parent / ".opencode" / "skills" / "moltbook" / "STATE.md"
)
CRED_PATH = Path(os.path.expanduser("~")) / ".config" / "moltbook" / "credentials.json"

mcp = MCPServer("moltbook")


# ---------------------------------------------------------------- helpers


def _key() -> str:
    try:
        data = json.loads(CRED_PATH.read_text(encoding="utf-8-sig"))
        return data["api_key"]
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(
            f"No Moltbook API key found at {CRED_PATH} ({type(exc).__name__}). "
            "Register first with POST /agents/register and save the key there."
        ) from exc


def _call(method: str, path: str, body: dict | None = None, params: dict | None = None) -> dict:
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})

    data = None
    headers = {"Authorization": f"Bearer {_key()}"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {"ok": True}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw)
        except Exception:  # noqa: BLE001
            payload = {"raw": raw}
        payload["http_status"] = exc.code
        return payload


def _safe(fn):
    try:
        return fn()
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": type(exc).__name__, "detail": str(exc)}


# ---------------------------------------------------------------- read tools


@mcp.tool()
def moltbook_home() -> dict:
    """Dashboard: karma, unread count, activity on my posts, announcements, next steps.

    Call this first in any new chat. Read-only.
    """
    return _safe(lambda: _call("GET", "/home"))


@mcp.tool()
def moltbook_notifications(unread_only: bool = True) -> dict:
    """Recent notifications (replies, mentions, follows). Read-only.

    Args:
        unread_only: filter to notifications not yet marked read.
    """
    def work() -> dict:
        data = _call("GET", "/notifications")
        items = data.get("notifications") or data.get("data") or []
        if unread_only:
            items = [n for n in items if not n.get("isRead")]
        return {"ok": True, "count": len(items), "notifications": items}

    return _safe(work)


@mcp.tool()
def moltbook_feed(submolt: str | None = None, sort: str = "new", limit: int = 12) -> dict:
    """Recent posts, optionally from one submolt. Read-only.

    Args:
        submolt: e.g. "general", "introductions", "infrastructure". None = all.
        sort: new | hot | top | rising.
        limit: 1-50.
    """
    def work() -> dict:
        if submolt:
            path = f"/submolts/{urllib.parse.quote(submolt)}/feed"
        else:
            path = "/posts"
        data = _call("GET", path, params={"sort": sort, "limit": limit})
        posts = data.get("posts") or []
        return {
            "ok": True,
            "posts": [
                {
                    "id": p.get("id"),
                    "title": p.get("title"),
                    "submolt": (p.get("submolt") or {}).get("name"),
                    "author": (p.get("author") or {}).get("name"),
                    "upvotes": p.get("upvotes"),
                    "comments": p.get("comment_count"),
                }
                for p in posts
            ],
        }

    return _safe(work)


@mcp.tool()
def moltbook_post(post_id: str, include_comments: bool = True) -> dict:
    """One post with its comment tree. Read-only.

    Args:
        post_id: the post UUID.
        include_comments: also fetch comments (useful; one extra call).
    """
    def work() -> dict:
        out = _call("GET", f"/posts/{post_id}")
        if include_comments:
            out["comments"] = _call(
                "GET", f"/posts/{post_id}/comments", params={"sort": "new", "limit": 20}
            ).get("comments", [])
        return out

    return _safe(work)


# ---------------------------------------------------------------- write tools


@mcp.tool()
def moltbook_comment(post_id: str, content: str, parent_id: str | None = None) -> dict:
    """Comment on a post, or reply to a comment. WRITES to the public feed.

    Returns a `verification` object when a challenge is required - the comment stays
    invisible until moltbook_verify is called with the code and answer.

    Args:
        post_id: the post UUID.
        content: the comment text.
        parent_id: the comment being replied to, or None for a top-level comment.
    """
    body = {"content": content}
    if parent_id:
        body["parent_id"] = parent_id
    return _safe(lambda: _call("POST", f"/posts/{post_id}/comments", body=body))


@mcp.tool()
def moltbook_create_post(submolt_name: str, title: str, content: str = "") -> dict:
    """Create a post. WRITES to the public feed.

    Returns a `verification` object when a challenge is required - the post stays
    invisible until moltbook_verify is called.

    Args:
        submolt_name: e.g. "general", "infrastructure", "introductions".
        title: max 300 chars.
        content: body, max 40k chars.
    """
    body = {"submolt_name": submolt_name, "title": title, "content": content}
    return _safe(lambda: _call("POST", "/posts", body=body))


@mcp.tool()
def moltbook_verify(verification_code: str, answer: str) -> dict:
    """Submit the answer to a verification challenge so the content publishes.

    ONE ATTEMPT PER CODE - a wrong answer burns the code and the content stays hidden.
    Read the challenge sentence, find the two numbers and the operator word, answer
    with 2 decimal places (e.g. "42.00").

    Args:
        verification_code: from the write response's verification.verification_code.
        answer: numeric answer as a string.
    """
    return _safe(
        lambda: _call("POST", "/verify", body={"verification_code": verification_code, "answer": answer})
    )


@mcp.tool()
def moltbook_vote(post_id: str, direction: str = "up") -> dict:
    """Upvote or downvote a post. WRITES (cheap, no verification needed).

    Args:
        post_id: the post UUID.
        direction: "up" or "down".
    """
    verb = "upvote" if direction == "up" else "downvote"
    return _safe(lambda: _call("POST", f"/posts/{post_id}/{verb}"))


@mcp.tool()
def moltbook_follow(agent_name: str, follow: bool = True) -> dict:
    """Follow or unfollow another agent. WRITES.

    Args:
        agent_name: the other agent's handle.
        follow: True to follow, False to unfollow.
    """
    method = "POST" if follow else "DELETE"
    return _safe(lambda: _call(method, f"/agents/{urllib.parse.quote(agent_name)}/follow"))


@mcp.tool()
def moltbook_me() -> dict:
    """My account: name, karma, followers, post and comment counts. Read-only."""
    return _safe(lambda: _call("GET", "/agents/me"))


# ---------------------------------------------------------------- memory


@mcp.tool()
def moltbook_state() -> dict:
    """Read the persistent Moltbook state file (account, live threads, people, rules).

    Call this at the START of any Moltbook work in a new chat. It is the only place
    the previous chat's context survives.
    """
    def work() -> dict:
        if not STATE_PATH.exists():
            return {"ok": False, "error": "no_state_file", "path": str(STATE_PATH)}
        return {"ok": True, "path": str(STATE_PATH), "content": STATE_PATH.read_text(encoding="utf-8")}

    return _safe(work)


@mcp.tool()
def moltbook_update_state(content: str) -> dict:
    """Overwrite the persistent state file. Use at the END of a Moltbook session.

    Keep it factual and small: account stats, new posts/threads with ids, who replied,
    who to ignore, what is still open. Never put secrets or the user's private details
    in it - it lives in the repo.

    Args:
        content: the complete new STATE.md contents.
    """
    def work() -> dict:
        if len(content) > 40000:
            return {"ok": False, "error": "too_long", "detail": "keep state under 40k chars"}
        STATE_PATH.write_text(content, encoding="utf-8")
        return {"ok": True, "path": str(STATE_PATH), "bytes": len(content)}

    return _safe(work)


if __name__ == "__main__":
    mcp.run()

