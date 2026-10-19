#!/usr/bin/env python3
"""An OpenAI-shaped SSE upstream that answers exactly one tool call.

Proving what an agent DOES needs a model, and a real one is neither
deterministic nor reachable from a CI runner. This stands in for it: the first
request carrying `--marker` is answered with one `--tool` call, everything else
with a plain reply, so the turn runs to completion without a network.

`{cwd}` in `--arguments` is replaced by the working directory the request's own
system prompt names, which makes the tool call carry what the agent was TOLD
instead of what the smoke assumed.

Every request body is written under `--record-dir`, so a smoke can assert on
the prompt as well as on the outcome.
"""

import argparse
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CWD_IN_PROMPT = re.compile(r"\*\*Current working directory:\*\*\s*([^\s\\\"]+)")
CHUNK_ID = "chatcmpl-stub"


def _sse(chunks):
    body = "".join("data: %s\n\n" % json.dumps(chunk) for chunk in chunks)
    return (body + "data: [DONE]\n\n").encode()


def sse_tool_call(model, call_id, tool, arguments):
    head = {
        "id": CHUNK_ID,
        "object": "chat.completion.chunk",
        "model": model,
        "choices": [
            {
                "index": 0,
                "delta": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": call_id,
                            "type": "function",
                            "function": {"name": tool, "arguments": arguments},
                        }
                    ],
                },
                "finish_reason": None,
            }
        ],
    }
    tail = {
        "id": CHUNK_ID,
        "object": "chat.completion.chunk",
        "model": model,
        "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
    }
    return _sse([head, tail])


def sse_text(model, content):
    head = {
        "id": CHUNK_ID,
        "object": "chat.completion.chunk",
        "model": model,
        "choices": [
            {
                "index": 0,
                "delta": {"role": "assistant", "content": content},
                "finish_reason": None,
            }
        ],
    }
    tail = {
        "id": CHUNK_ID,
        "object": "chat.completion.chunk",
        "model": model,
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }
    return _sse([head, tail])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        self.server.record(body)
        payload = self.server.reply(body)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(payload)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        sys.stderr.write("[stub-llm] %s\n" % (fmt % args))


class Stub(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, opts):
        super().__init__(address, Handler)
        self.opts = opts
        self.lock = threading.Lock()
        self.recorded = 0
        self.tool_calls = 0

    def record(self, body):
        with self.lock:
            self.recorded += 1
            name = "request-%03d.json" % self.recorded
        path = os.path.join(self.opts.record_dir, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)

    def reply(self, body):
        wanted = (
            self.opts.marker in body
            and self.opts.tool_call_id not in body
            and '"tools"' in body
        )
        if not wanted:
            return sse_text(self.opts.model, "done")
        with self.lock:
            self.tool_calls += 1
        match = CWD_IN_PROMPT.search(body)
        cwd = match.group(1) if match else "no-cwd-in-prompt"
        arguments = self.opts.arguments.replace("{cwd}", cwd)
        return sse_tool_call(
            self.opts.model, self.opts.tool_call_id, self.opts.tool, arguments
        )


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--record-dir", required=True)
    parser.add_argument("--marker", required=True)
    parser.add_argument("--tool", required=True)
    parser.add_argument("--tool-call-id", required=True)
    parser.add_argument("--arguments", required=True)
    parser.add_argument("--model", default="stub-model")
    return parser.parse_args(argv)


def main(argv):
    opts = parse_args(argv)
    os.makedirs(opts.record_dir, exist_ok=True)

    server = Stub(("127.0.0.1", opts.port), opts)
    port = server.server_address[1]
    with open(opts.port_file, "w", encoding="utf-8") as handle:
        handle.write(str(port))
    print("[stub-llm] listening on 127.0.0.1:%d" % port, flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
