"""pabrik Python hook example.

Copy this file to <config_dir>/hooks/register_hook.py:
  Linux:   ~/.config/pabrik/hooks/register_hook.py
  macOS:   ~/Library/Application Support/pabrik/hooks/register_hook.py
  Windows: %APPDATA%/pabrik/hooks/register_hook.py

A per-project hook lives at <cwd>/.pabrik/hooks/register_hook.py and runs
AFTER the global one. A Lua hook (register_hook.lua) sits beside either file
and speaks the same contract — see examples/hooks/register_hook.lua.

The contract is identical to the Lua one: pabrik calls init(event, data) with
exactly one of these events, and you return None or a dict.

  "pre_tool_use"   — before a tool runs.
    data = {tool_name, arguments, session_id, cwd, model}

  "post_tool_use"  — after a tool runs.
    data = {tool_name, arguments, output, session_id, cwd, model}

  "session_start"  — once per agent run, before the first LLM call.
    data = {session_id, parent_session_id, cwd, model, is_sub_agent, message}

  "finish_reason"  — every LLM response that carries a finish_reason, before
                     the loop acts on it.
    data = {session_id, cwd, model, finish_reason, content, tool_count,
            loop_index}
    finish_reason is one of: stop, tool_calls, length, awaiting_user,
    cancelled, null.

  "session_end"    — exactly once per agent run, on every exit path.
    data = {session_id, cwd, model, finish_reason, loop_count, end_reason}
    end_reason is one of: stop, awaiting_user, is_stop, cancelled,
    lease_lost, pending_question, error.

"session_start" and "session_end" fire once per RUN, not once per chat row:
a chat row outlives many runs.

Return None to do nothing. Or return a dict to act:

  pre:           {"deny": "reason"}                — block with an error envelope
  pre:           {"arguments": "{...new json...}"} — rewrite args (valid JSON;
                                                     a dict is serialized for you)
  pre:           {"output": "..."}                 — mock: skip the tool
  post:          {"output": "..."}                 — replace/redact the output
  post:          {"deny": "reason"}                — replace output with an error
  session_start: {"context": "..."}                — appended to the system
                                                     prompt under "## Hook Context"
  finish_reason: {"continue": True, "prompt": "..."}
                                                   — do not end the run; queue
                                                     `prompt` and keep going.
                                                     Honored only on "stop", at
                                                     most 3 times per run.

Anything else (missing file, missing init, an exception, a non-zero exit, a
timeout, unparseable output) fails open: pabrik logs a line and carries on.

The interpreter is `hook_python_bin` from the workspace settings, else
$PABRIK_HOOK_PYTHON, else the first of `python`, `python3`, `py` that is a
Python 3. Each event costs one interpreter spawn (~30-60 ms), so prefer Lua
for hooks on hot paths like pre_tool_use.
"""

import os


def init(event, data):
    if event == "pre_tool_use":
        if data["tool_name"] in ("command", "bash") and "rm -rf" in data["arguments"]:
            return {"deny": "hook: refusing destructive 'rm -rf' command"}

    if event == "post_tool_use":
        if "sk-" in data["output"]:
            return {"output": "[redacted by hook: possible secret in tool output]"}

    if event == "session_start":
        return {"context": "This project uses `zig build test` and never commits to main."}

    if event == "finish_reason":
        if data["finish_reason"] == "stop" and data["loop_index"] == 0:
            if "test" not in data["content"]:
                return {
                    "continue": True,
                    "prompt": "You have not run the tests yet. Run them, then report the result.",
                }

    if event == "session_end":
        with open(os.path.join(os.sep, "tmp", "pabrik-hook.log"), "a") as f:
            f.write(f"{data['session_id']} {data['end_reason']} loops={data['loop_count']}\n")

    return None
