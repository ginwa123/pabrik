"""The tool set a freshly-created agent / kanban item is seeded with.

One copy, because there used to be four. `agent_tools_toggle_test`,
`agent_tools_defaults_test`, `command_tool_test` and an inline literal in
`agent_kanbans_test` each carried their own transcription of the same
26-name list. PR #744 added `add_document` + `edit_document` to
`DEFAULT_AGENT_TOOLS` and updated none of them, so the next
`zig build functional-test-all` failed 18 tests that were all really one
assertion — and a reviewer reading the CI log had to diff four files to
find that out. `search_documents` (2026-10-02) repeated the cycle once
more.

The backend's list is `DEFAULT_AGENT_TOOLS`, plus `DEFAULT_KANBAN_TOOLS`
for kanban items — `src/modules/agent/tools/tools_equipped.zig`. Both are seeded
once at creation by `workspace_items_create_agent.zig` /
`workspace_items_create_kanban.zig`; nothing backfills them on read, so a
fresh item is the only place this is observable.

WHEN YOU ADD A TOOL TO `DEFAULT_AGENT_TOOLS`: add it here too, in sorted
order. The assertions that consume these lists are exact-equality, which
is the point — the set of tools a new agent is born with IS the contract.
A stale entry here is a red build that names the one file to edit.
"""

from __future__ import annotations

# Mirrors `DEFAULT_AGENT_TOOLS` — 35 names, sorted ASC, matching the
# wire order of `GET /api/agents/:agent_id/tools`.
#
# `delete_document` is deliberately ABSENT. It is irreversible, so it is
# registered (and therefore one tick away in the Settings → Tools
# checklist, which reads the same registry) but never seeded. Registered
# and handed-out are two different decisions; see the static contract test
# `search_documents is seeded by default but delete_document is NOT` in
# `src/agentic_loop/tools_exec_document.zig`.
DEFAULT_AGENT_TOOLS: list[str] = [
    "add_document",
    "add_skill",
    "ask_user",
    "command",
    "edit_document",
    "edit_skill",
    "get_plan",
    "glob",
    "list_agents",
    "list_directory",
    "list_secrets",
    "list_web_search_providers",
    "load_memory",
    "present_files",
    "process",
    "read_file",
    "read_workspace_session",
    "remove_file",
    "remove_skill",
    "run_session",
    "save_memory",
    "search",
    "search_documents",
    "search_skills",
    "search_tool",
    "spawn_sub_agent",
    "text_replace",
    "update_plan",
    "use_skill",
    "use_tool",
    "used_tools",
    "view_session",
    "view_tool",
    "web_search",
    "write_file",
]

# Mirrors `DEFAULT_KANBAN_TOOLS` — the two tools seeded on top for a
# kanban item, and nothing else.
DEFAULT_KANBAN_TOOLS: list[str] = [
    "kanban_list",
    "kanban_move_task",
]

# A fresh kanban item seeds the agent defaults PLUS the kanban pair, so
# this is `GET /api/agent-kanbans/:id/tools` on a new board (and the
# `tools` checklist on its `agent_kanban` bundle).
DEFAULT_KANBAN_SEEDED_TOOLS: list[str] = sorted(
    DEFAULT_AGENT_TOOLS + DEFAULT_KANBAN_TOOLS
)


def agent_defaults_without(tool_name: str) -> list[str]:
    """The seeded agent list minus one tool, still sorted ASC.

    Used as the post-DELETE expectation: disabling `command` must leave
    exactly the defaults that are not `command`, not a re-derived set.
    """
    return [name for name in DEFAULT_AGENT_TOOLS if name != tool_name]
