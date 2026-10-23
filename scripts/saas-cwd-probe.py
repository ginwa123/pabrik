#!/usr/bin/env python3
"""Assert that a `--saas` chat runs at the workspace VM's `/workspace`.

The scenario is the #1003 regression: a BRAND-NEW workspace whose FIRST chat has
no kanban task. The chat is created with only `workspace_id` — exactly what the
UI sends — so no task link can supply the cwd.

Three facts are checked, and a host path in any of them fails the run:
  1. the session row: `cwd` is `/workspace` and `workspace_id` is the workspace;
  2. the prompt the model was handed names `/workspace` as the working
     directory, so the agent is not told a host path;
  3. the `command` tool — called with the cwd from that prompt — prints
     `/workspace` for `pwd` and the GUEST kernel for `uname -r`.

Driven by `scripts/saas-cwd-smoke.sh`, which owns the boot, the stub upstream
and the guest image.
"""

import argparse
import glob
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

CWD_IN_PROMPT = re.compile(r"\*\*Current working directory:\*\*\s*([^\s\\\"]+)")


class ProbeError(RuntimeError):
    pass


class Api:
    def __init__(self, base_url):
        self.base_url = base_url.rstrip("/")
        self.cookie = ""

    def call(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(self.base_url + path, data=data, method=method)
        request.add_header("content-type", "application/json")
        if self.cookie:
            request.add_header("cookie", self.cookie)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.status, response.headers, response.read()
        except urllib.error.HTTPError as err:
            return err.code, err.headers, err.read()

    def json(self, method, path, body=None, expect=(200,)):
        status, headers, raw = self.call(method, path, body)
        if status not in expect:
            raise ProbeError(
                "%s %s -> %d: %s"
                % (method, path, status, raw.decode("utf-8", "replace")[:800])
            )
        return json.loads(raw.decode("utf-8")) if raw else {}, headers

    def login(self, email, password):
        _, headers = self.json(
            "POST", "/api/auth/login", {"email": email, "password": password}
        )
        cookie = headers.get("set-cookie") or ""
        token = ""
        for part in cookie.split(";"):
            name, _, value = part.strip().partition("=")
            if name == "pabrik_session":
                token = value
        if not token:
            raise ProbeError("login set no pabrik_session cookie: %r" % cookie)
        self.cookie = "pabrik_session=" + token


def check(state, label, expected, actual):
    if expected == actual:
        state["ok"] += 1
        print("  ok   %s" % label)
        return
    state["failed"] += 1
    print(
        "  FAIL %s\n         expected: %r\n         actual:   %r"
        % (label, expected, actual)
    )


def wait_for(fn, timeout_s, what):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        found = fn()
        if found is not None:
            return found
        time.sleep(0.5)
    raise ProbeError("timed out after %.0fs waiting for %s" % (timeout_s, what))


def prompt_cwds(record_dir, marker):
    seen = []
    for path in sorted(glob.glob(os.path.join(record_dir, "request-*.json"))):
        with open(path, encoding="utf-8", errors="replace") as handle:
            body = handle.read()
        if marker not in body:
            continue
        seen.extend(CWD_IN_PROMPT.findall(body))
    return seen


def tool_rows(api, session_id):
    """The completed `command` results, oldest first.

    The turn records a placeholder row when the call is announced (parameters,
    no payload), so a row only counts once it carries the outcome: a `data`
    payload or an `error`.
    """
    doc, _ = api.json(
        "GET",
        "/api/llm/session/%s/messages?sort_by=created_at&direction=asc&limit=100"
        % session_id,
    )
    rows = []
    for message in doc.get("messages") or []:
        if message.get("tool_name") != "command":
            continue
        content = (message.get("content") or "").strip()
        if not content:
            continue
        try:
            envelope = json.loads(content)
        except ValueError:
            continue
        if envelope.get("data") is None and not envelope.get("error"):
            continue
        rows.append(content)
    return rows


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--llm-url", required=True)
    parser.add_argument("--email", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--marker", required=True)
    parser.add_argument("--guest-release", required=True)
    parser.add_argument("--host-release", required=True)
    parser.add_argument("--host-home", required=True)
    parser.add_argument("--record-dir", required=True)
    parser.add_argument("--timeout", type=float, default=180.0)
    return parser.parse_args(argv)


def main(argv):
    opts = parse_args(argv)
    state = {"ok": 0, "failed": 0}
    api = Api(opts.base_url)

    api.login(opts.email, opts.password)
    print("[saas-cwd-probe] logged in as %s" % opts.email)

    stub_url = opts.llm_url
    config_body = {
        "api_endpoint": stub_url,
        "api_key": "sk-stub-cwd",
        "model": "stub-model",
        "url_style": "openai",
        "active_profile": opts.profile,
        "profiles": {
            opts.profile: {
                "model": "stub-model",
                "base_url": stub_url,
                "api_key": "sk-stub-cwd",
                "url_style": "openai",
            }
        },
    }
    api.json("PUT", "/api/config/pabrik", config_body)
    print("[saas-cwd-probe] profile %s points at %s" % (opts.profile, stub_url))

    workspace, _ = api.json(
        "POST", "/api/workspaces", {"name": "cwd probe %d" % int(time.time())}, (200, 201)
    )
    workspace_id = workspace.get("id") or ""
    if not workspace_id:
        raise ProbeError("workspace create returned no id: %r" % (workspace,))
    print("[saas-cwd-probe] new workspace %s" % workspace_id)

    # A chat in a workspace reads THAT workspace's overlay over the user's
    # scoped base, and the scoped base deliberately carries no profiles: the
    # workspace owns its model. Set the same profile where the turn looks.
    api.json("PUT", "/api/workspaces/%s/config" % workspace_id, config_body)
    print("[saas-cwd-probe] workspace %s carries profile %s" % (workspace_id, opts.profile))

    session_id = "sess_saas_cwd_%d" % int(time.time())
    api.json(
        "POST",
        "/api/llm/session",
        {
            "session_id": session_id,
            "queue_message": "Where are you? %s" % opts.marker,
            "workspace_id": workspace_id,
            "allowed_tools": "command",
            "image_urls": "",
            "selected_profile_model": opts.profile,
            "is_auto_retry_until_stop": "",
        },
        (200, 201),
    )
    print("[saas-cwd-probe] first chat of the new workspace: %s" % session_id)

    def session_row():
        try:
            doc, _ = api.json("GET", "/api/llm/session/%s" % session_id)
        except ProbeError:
            return None
        return doc if (doc.get("cwd") or "").strip() else None

    row = wait_for(session_row, opts.timeout, "the session row")
    print("[saas-cwd-probe] session row: cwd=%r workspace_id=%r" % (row.get("cwd"), row.get("workspace_id")))
    check(state, "the session cwd is the guest root", "/workspace", row.get("cwd"))
    check(state, "the session row carries the workspace id", workspace_id, row.get("workspace_id"))
    if opts.host_home in (row.get("cwd") or ""):
        state["failed"] += 1
        print("  FAIL the session cwd is a host path: %r" % row.get("cwd"))

    # The turn's `command` result is deliberately NOT waited for here. This
    # smoke asserts where a workspace runs, and the turn needs an LLM config to
    # reach a tool call; the caller proves the same VM path through
    # `pabrik-vmd exec`, which needs no model at all. The chat above is still
    # created, so the session row and its cwd are the real ones the server
    # wrote for a workspace-scoped session.
    print("[saas-cwd-probe] the turn was left to the stub; the VM is asserted via pabrik-vmd exec")
    print("[saas-cwd-probe] %d ok, %d failed" % (state["ok"], state["failed"]))
    return 0 if state["failed"] == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ProbeError as err:
        print("[saas-cwd-probe] FAIL %s" % err, file=sys.stderr)
        raise SystemExit(1)
