-- pabrik Lua hook example.
--
-- Copy this file to <config_dir>/hooks/register_hook.lua:
--   Linux:   ~/.config/pabrik/hooks/register_hook.lua
--   macOS:   ~/Library/Application Support/pabrik/hooks/register_hook.lua
--   Windows: %APPDATA%/pabrik/hooks/register_hook.lua
--
-- A per-project hook lives at <cwd>/.pabrik/hooks/register_hook.lua and runs
-- AFTER the global one. A Python hook (register_hook.py) sits beside either
-- file and speaks the same contract — see examples/hooks/register_hook.py.
--
-- pabrik calls init(event, data) with exactly one of these events:
--
--   "pre_tool_use"   — before a tool runs.
--     data = { tool_name, arguments, session_id, cwd, model }
--
--   "post_tool_use"  — after a tool runs.
--     data = { tool_name, arguments, output, session_id, cwd, model }
--
--   "session_start"  — once per agent run, before the first LLM call.
--     data = { session_id, parent_session_id, cwd, model, is_sub_agent, message }
--
--   "finish_reason"  — every LLM response that carries a finish_reason,
--                      before the loop acts on it.
--     data = { session_id, cwd, model, finish_reason, content, tool_count,
--              loop_index }
--     finish_reason is one of: stop, tool_calls, length, awaiting_user,
--     cancelled, null.
--
--   "session_end"    — exactly once per agent run, on every exit path.
--     data = { session_id, cwd, model, finish_reason, loop_count, end_reason }
--     end_reason is one of: stop, awaiting_user, is_stop, cancelled,
--     lease_lost, pending_question, error.
--
-- "session_start" and "session_end" fire once per RUN, not once per chat row:
-- a chat row outlives many runs.
--
-- Return nil to do nothing. Or return a table to act:
--
--   pre:        { deny = "reason" }                — block with an error envelope
--   pre:        { arguments = "{...new json...}" } — rewrite args (valid JSON)
--   pre:        { output = "..." }                 — mock: skip the tool
--   post:       { output = "..." }                 — replace/redact the output
--   post:       { deny = "reason" }                — replace output with an error
--   session_start: { context = "..." }             — appended to the system
--                                                    prompt under "## Hook Context"
--   finish_reason: { continue = true, prompt = "..." }
--                                                  — do not end the run; queue
--                                                    `prompt` and keep going.
--                                                    Honored only on "stop", at
--                                                    most 3 times per run.
--
-- Anything else (missing file, missing init, Lua error, bad return shape)
-- fails open: pabrik logs a line and carries on.

function init(event, data)
  if event == "pre_tool_use" then
    -- Example guard: refuse destructive shell commands.
    if data.tool_name == "command" or data.tool_name == "bash" then
      if string.find(data.arguments, "rm%s+%-rf", 1, false) ~= nil then
        return { deny = "hook: refusing destructive 'rm -rf' command" }
      end
    end
  end

  if event == "post_tool_use" then
    -- Example redaction: never let secret-looking output reach the chat.
    if string.find(data.output, "sk%-", 1, false) ~= nil then
      return { output = "[redacted by hook: possible secret in tool output]" }
    end
  end

  if event == "session_start" then
    -- Example context injection: every run of this project starts knowing
    -- the house rules.
    return { context = "This project uses `zig build test` and never commits to main." }
  end

  if event == "finish_reason" then
    -- Example "don't stop yet": the model said it was done, but it never
    -- mentioned the tests. Send it back once.
    if data.finish_reason == "stop" and data.loop_index == 0 then
      if string.find(data.content, "test", 1, true) == nil then
        return { continue = true, prompt = "You have not run the tests yet. Run them, then report the result." }
      end
    end
  end

  if event == "session_end" then
    -- Example observation: append one line per run to a log file.
    local f = io.open("/tmp/pabrik-hook.log", "a")
    if f then
      f:write(data.session_id .. " " .. data.end_reason .. " loops=" .. data.loop_count .. "\n")
      f:close()
    end
  end

  return nil
end
