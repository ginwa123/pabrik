package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Wire row → card model.
 *
 * Every payload here is shaped like one the backend actually emits, taken from
 * the per-tool builders. The field names that look wrong in isolation —
 * `file_write` for a write path, `agents` for an agent list, a *number* for
 * `glob`'s `truncated` — are the ones a client guesses wrongly, so they are
 * the ones asserted.
 */
class ToolCardModelTest {

    private fun toolRow(
        toolName: String,
        data: String,
        parameters: String = "{}",
        success: Boolean = true,
        error: String? = null,
        toolCallId: String = "call_1",
    ): ChatMessage {
        val payload = if (data == RAW) {
            "not an envelope"
        } else {
            """{"tool":"$toolName","parameters":$parameters,"success":$success,
               "data":$data,"error":${error?.let { "\"$it\"" } ?: "null"},"v":1}"""
        }
        return ChatMessage(
            id = "row_1",
            role = ChatMessage.ROLE_TOOL,
            content = payload,
            createdAtEpochMillis = 0L,
            sortKeyNanos = 0L,
            toolName = toolName,
            toolCallId = toolCallId,
            finishReason = ChatMessage.FINISH_REASON_TOOL,
        )
    }

    // ─── read_file ──────────────────────────────────────────────────────────

    @Test
    fun `read_file shows its path and line count`() {
        val model = ToolCard.from(
            toolRow(
                "read_file",
                """{"path":"/x.txt","content":"a\nb\nc\n",
                   "total_lines":3,"start_line":10,"end_line":12}""",
            ),
        )

        assertEquals(ToolKind.ReadFile, model.kind)
        assertEquals("/x.txt", model.primary)
        assertEquals("3L", model.rightMeta)
        val body = model.body as ToolBody.ReadFile
        // The backend's `start_line` is a 0-based offset, so line 10 is the
        // 11th line and the gutter has to say 11.
        assertEquals(11, body.firstLineNumber)
        assertEquals(listOf("a", "b", "c"), body.lines)
    }

    @Test
    fun `a running read_file shows the requested path from its arguments`() {
        // The placeholder row carries no result at all, so the path has to come
        // from `parameters` or the card says "unknown" for the whole run.
        val model = ToolCard.from(
            toolRow("read_file", "null", parameters = """{"path":"/secret.txt"}"""),
        )

        assertTrue(model.pending)
        assertEquals("/secret.txt", model.primary)
        assertEquals("·", runningGlyph(model))
    }

    // ─── write_file ─────────────────────────────────────────────────────────

    /**
     * `write_file` names its result key `file_write`; there is no `path` on the
     * success payload. A client that reads `path` renders an empty card for
     * every write.
     */
    @Test
    fun `write_file reads file_write, not path`() {
        val model = ToolCard.from(
            toolRow("write_file", """{"file_write":"/out.txt","error":null}"""),
        )

        assertEquals(ToolKind.WriteFile, model.kind)
        assertEquals("/out.txt", (model.body as ToolBody.WriteFile).path)
        assertEquals("/out.txt", model.primary)
    }

    // ─── shell family ───────────────────────────────────────────────────────

    @Test
    fun `bash parses its eight-field payload`() {
        val model = ToolCard.from(
            toolRow(
                "bash",
                """{"command":"ls -la","stdout":"a\nb\n","stderr":"","exit_code":0,
                   "truncated":false,"timeout":false,"stdout_lines":2,
                   "stderr_lines":0}""",
            ),
        )

        val body = model.body as ToolBody.Shell
        assertEquals("ls -la", body.command)
        assertEquals(0, body.exitCode)
        assertFalse(body.hasStderr)
        assertFalse(body.hasFailure)
        assertTrue(model.success)
    }

    /**
     * A non-zero exit is a *result*, not a tool failure: the shell ran and
     * reported faithfully, so the envelope says success and the card keeps its
     * tick. The distinction is carried by the exit code in the header, which
     * is the only thing a collapsed card can show.
     */
    @Test
    fun `a non-zero exit code shows in the header without failing the card`() {
        val model = ToolCard.from(
            toolRow(
                "bash",
                """{"command":"false","stdout":"","stderr":"boom","exit_code":1,
                   "truncated":false,"timeout":false,"stdout_lines":0,
                   "stderr_lines":1}""",
            ),
        )

        assertTrue(model.success)
        assertEquals("1", model.rightMeta)
        val body = model.body as ToolBody.Shell
        assertTrue(body.hasStderr)
        assertTrue(body.hasFailure)
    }

    @Test
    fun `a clean shell run shows its exit code too`() {
        val model = ToolCard.from(
            toolRow(
                "bash",
                """{"command":"ls","stdout":"a\n","stderr":"","exit_code":0,
                   "truncated":false,"timeout":false,"stdout_lines":1,
                   "stderr_lines":0}""",
            ),
        )

        assertEquals("0", model.rightMeta)
    }

    @Test
    fun `shell warning flags ride alongside the exit code`() {
        val model = ToolCard.from(
            toolRow(
                "bash",
                """{"command":"sleep 9","stdout":"","stderr":"","exit_code":null,
                   "truncated":true,"timeout":true,"stdout_lines":0,
                   "stderr_lines":0}""",
            ),
        )

        assertEquals("truncated · timeout", model.rightMeta)
    }

    /** The shell's stand-in for an empty stderr; showing it wastes a red block. */
    @Test
    fun `the shell's no-errors sentinel is not an error`() {
        val body = ToolBody.Shell(stderr = "No errors.")

        assertFalse(body.hasStderr)
    }

    @Test
    fun `a timeout is a warning, not a failure`() {
        val timedOut = ToolCard.from(
            toolRow(
                "bash",
                """{"command":"sleep 9","stdout":"","stderr":"","exit_code":null,
                   "truncated":false,"timeout":true,"stdout_lines":0,
                   "stderr_lines":0}""",
            ),
        )

        assertTrue((timedOut.body as ToolBody.Shell).hasWarning)
    }

    /** `run_command` is the legacy alias; the web renames it to `bash`. */
    @Test
    fun `every shell alias maps to one kind`() {
        listOf("bash", "pwsh", "run_command", "command").forEach { name ->
            assertEquals("wrong kind for $name", ToolKind.Shell, ToolCard.from(toolRow(name, "{}")).kind)
        }
        assertEquals("bash", ToolCard.from(toolRow("run_command", "{}")).label)
        assertEquals("command", ToolCard.from(toolRow("command", "{}")).label)
    }

    // ─── search / glob / list_directory ──────────────────────────────────────

    @Test
    fun `search parses its grouped file results`() {
        val model = ToolCard.from(
            toolRow(
                "search",
                """{"pattern":"foo","path":"src/","returned":1,"total":1,
                   "truncated":false,"output_truncated":false,"output_bytes":1234,
                   "truncated_hint":null,"grouped":true,
                   "files":[{"path":"src/a.zig","total":1,"count":1,
                   "matches":[{"line":10,"text":"foo bar"}]}],"warning":null}""",
            ),
        )

        val body = model.body as ToolBody.Search
        assertEquals("foo", body.pattern)
        assertEquals("1 match", model.rightMeta)
        assertEquals("src/a.zig", body.files[0].path)
        assertEquals(10, body.files[0].matches[0].line)
        assertEquals("foo bar", body.files[0].matches[0].text)
    }

    /** `glob` reports `truncated` as a *count* of dropped matches, not a bool. */
    @Test
    fun `glob parses a string file list and a numeric truncated count`() {
        val model = ToolCard.from(
            toolRow(
                "glob",
                """{"pattern":"*.zig","total":50,"returned":3,"offset":0,
                   "truncated":47,"truncated_by_size":false,
                   "files":["a.zig","b.zig","c.zig"],"warning":null}""",
            ),
        )

        val body = model.body as ToolBody.Glob
        assertEquals(47, body.truncated)
        assertEquals(listOf("a.zig", "b.zig", "c.zig"), body.files)
        assertEquals("3 files", model.rightMeta)
    }

    @Test
    fun `list_directory parses its entry records`() {
        val model = ToolCard.from(
            toolRow(
                "list_directory",
                """{"path":"/dir","count":2,"entries":[
                   {"name":"src","path":"/dir/src","is_directory":true,"is_symlink":false},
                   {"name":"link","path":"/dir/link","is_directory":false,"is_symlink":true}]}""",
            ),
        )

        val body = model.body as ToolBody.ListDirectory
        assertEquals("/dir", body.path)
        assertTrue(body.entries[0].isDirectory)
        assertTrue(body.entries[1].isSymlink)
    }

    // ─── diff ───────────────────────────────────────────────────────────────

    @Test
    fun `text_replace prefers the server's own unified diff`() {
        val model = ToolCard.from(
            toolRow(
                "text_replace",
                """{"path":"/x","unified":"@@ -1 +1 @@\n-a\n+b","before":"a",
                   "after":"b","lines_changed":1}""",
            ),
        )

        val body = model.body as ToolBody.Diff
        // Re-deriving the diff locally and disagreeing with the server is worse
        // than showing what the server said.
        assertEquals("@@ -1 +1 @@\n-a\n+b", body.unified)
        assertEquals("1 line", model.rightMeta)
    }

    @Test
    fun `an unknown tool falls back to its row diffview`() {
        val message = ChatMessage(
            id = "row_1",
            role = ChatMessage.ROLE_TOOL,
            content = """{"tool":"mystery","parameters":{},"success":true,
                         "data":{},"error":null,"v":1}""",
            createdAtEpochMillis = 0L,
            sortKeyNanos = 0L,
            toolName = "mystery",
            diffviewBefore = "a\nb\n",
            diffviewAfter = "a\nc\n",
        )

        val body = ToolCard.from(message).body as ToolBody.Diff
        assertEquals("a\nb\n", body.before)
        assertEquals("a\nc\n", body.after)
    }

    // ─── plan ───────────────────────────────────────────────────────────────

    @Test
    fun `update_plan renders its checklist`() {
        val model = ToolCard.from(
            toolRow(
                "update_plan",
                """{"session_id":"s1","updated_at":"2026-09-26T10:00:00Z",
                   "plan":"- [x] read the wire\n- [ ] write the card\nplain note"}""",
            ),
        )

        val body = model.body as ToolBody.Plan
        val lines = body.lines
        assertEquals(
            ToolBody.ChecklistLine.ChecklistKind.Checked,
            lines[0].kind,
        )
        assertEquals("read the wire", lines[0].text)
        assertEquals(ToolBody.ChecklistLine.ChecklistKind.Unchecked, lines[1].kind)
        assertEquals("write the card", lines[1].text)
        assertEquals(ToolBody.ChecklistLine.ChecklistKind.Text, lines[2].kind)
        assertTrue(model.defaultsExpanded)
    }

    /** `get_plan` with no plan emits `{"empty": true}` and no `plan` key. */
    @Test
    fun `get_plan with no plan says so`() {
        val body = ToolCard.from(toolRow("get_plan", """{"empty":true}""")).body as ToolBody.Plan

        assertTrue(body.empty)
        assertTrue(ToolCard.from(toolRow("get_plan", """{"empty":true}""")).defaultsExpanded)
    }

    // ─── ask_user ───────────────────────────────────────────────────────────

    @Test
    fun `a pending question is blocking and opens by default`() {
        val model = ToolCard.from(
            toolRow(
                "ask_user",
                """{"status":"pending","question_id":"q1","question":"Pick one",
                   "answer":null,"answers_count":0,"header":null,
                   "allow_free_text":true,"multi_select":false,
                   "recommended":"b","options":["a","b"],"instruction":null}""",
            ),
        )

        val body = model.body as ToolBody.Question
        assertTrue(body.isPending)
        assertTrue(model.isBlocking)
        assertTrue(model.defaultsExpanded)
        assertEquals("q1", body.questionId)
        assertEquals(listOf("a", "b"), body.options)
        // The answer endpoint falls back to the tool row's own id, so the card
        // has to carry it.
        assertEquals("call_1", model.toolCallId)
    }

    @Test
    fun `an answered question is not blocking`() {
        val model = ToolCard.from(
            toolRow(
                "ask_user",
                """{"status":"answered","question_id":"q1","question":"Pick one",
                   "answer":"a","answers_count":1,"header":null,
                   "allow_free_text":true,"multi_select":false,
                   "recommended":null,"options":["a","b"],"instruction":null}""",
            ),
        )

        val body = model.body as ToolBody.Question
        assertFalse(body.isPending)
        assertFalse(model.isBlocking)
        assertEquals("a", body.answer)
    }

    // ─── agents ─────────────────────────────────────────────────────────────

    /** The key is `agents` — the tool lists the configured agents. */
    @Test
    fun `list_agents reads agents`() {
        val body = ToolCard.from(
            toolRow(
                "list_agents",
                """{"count":1,"agents":[
                   {"name":"explorer","model":"gpt","url_style":"openai",
                   "thinking":"auto","temperature":"auto","system_prompt":"x"}]}""",
            ),
        ).body as ToolBody.AgentCatalog

        assertEquals(1, body.count)
        assertEquals("explorer", body.agents[0].name)
    }

    @Test
    fun `spawn_sub_agent counts come from the summary`() {
        val body = ToolCard.from(
            toolRow(
                "spawn_sub_agent",
                """{"results":[{"name":"a","success":true,"random_fallback":true,
                   "session_id":"s1","response":"done","error":null},
                   {"name":"b","success":false,"random_fallback":false,
                   "session_id":null,"response":null,"error":"boom"}],
                   "summary":{"succeeded":1,"failed":1}}""",
            ),
        ).body as ToolBody.SubAgentSpawn

        assertEquals(1, body.succeeded)
        assertEquals(1, body.failed)
        assertEquals("done", body.results[0].response)
        assertEquals("boom", body.results[1].error)
        assertTrue(body.results[0].success)
        assertFalse(body.results[1].success)
    }

    // ─── skills ─────────────────────────────────────────────────────────────

    @Test
    fun `search_skills reads each row's own scope`() {
        val model = ToolCard.from(
            toolRow(
                "search_skills",
                """{"query":"git","pattern_mode":"regex","pattern_warning":null,
                   "scope":null,"count":2,"total":2,"offset":0,"limit":20,
                   "skills":[{"name":"g","description":"d","scope":"global","path":"/g"},
                   {"name":"l","description":"d","scope":"local","path":"/l"}],
                   "truncated":false,"next_offset":null,"hint":""}""",
            ),
        )

        assertEquals(ToolKind.SkillList, model.kind)
        // The search may return the two scopes in either order, so scope is a
        // property of the row. Reading it as "which array was this in" cannot
        // survive the rename to one merged `skills` array.
        val body = model.body as ToolBody.SkillList
        assertEquals(listOf("g" to "global", "l" to "local"), body.skills.map { it.name to it.scope })
        assertEquals(listOf("/g", "/l"), body.skills.map { it.path })
        assertEquals("git", body.query)
        assertEquals("git", model.primary)
    }

    /**
     * `count` is this page, `total` is every match before paging. A card that
     * reads `count` as the total tells the reader that three skills is all the
     * query found, when there are nineteen and the agent has not seen them.
     */
    @Test
    fun `a truncated search_skills page reports count of total and admits the gap`() {
        val model = ToolCard.from(
            toolRow(
                "search_skills",
                """{"query":"git","pattern_mode":"literal","pattern_warning":null,
                   "scope":"global","count":2,"total":19,"offset":0,"limit":2,
                   "skills":[{"name":"a","description":"","scope":"global","path":"/a"},
                   {"name":"b","description":"","scope":"global","path":"/b"}],
                   "truncated":true,"next_offset":2,"hint":"narrow the query"}""",
            ),
        )

        val body = model.body as ToolBody.SkillList
        assertEquals(2, body.count)
        assertEquals(19, body.total)
        assertEquals(2, body.nextOffset)
        assertTrue(body.truncated)
        assertFalse(body.sawEverything)
        // Same header spelling as `search_tool`: this-page/total, and a partial
        // page is marked rather than passed off as the whole result.
        assertEquals("2/19 · truncated", model.rightMeta)
    }

    @Test
    fun `a complete search_skills page claims nothing is missing`() {
        val model = ToolCard.from(
            toolRow(
                "search_skills",
                """{"query":"git","pattern_mode":"literal","pattern_warning":null,
                   "scope":"global","count":2,"total":2,"offset":0,"limit":20,
                   "skills":[{"name":"a","description":"","scope":"global","path":"/a"},
                   {"name":"b","description":"","scope":"global","path":"/b"}],
                   "truncated":false,"next_offset":null,"hint":""}""",
            ),
        )

        val body = model.body as ToolBody.SkillList
        assertTrue(body.sawEverything)
        assertEquals("2/2", model.rightMeta)
    }

    /**
     * `count` is optional on an older row and `skills` is the ground truth.
     * Defaulting `total` to zero would put a bare `0/0` over two rendered rows,
     * which reads as "this tool found nothing".
     */
    @Test
    fun `a search_skills page without counts falls back to the rows it has`() {
        val body = ToolCard.from(
            toolRow(
                "search_skills",
                """{"query":"git","skills":[
                   {"name":"a","description":"","scope":"global","path":"/a"}]}""",
            ),
        ).body as ToolBody.SkillList

        assertEquals(1, body.count)
        assertEquals(1, body.total)
        assertTrue(body.sawEverything)
    }

    /**
     * A placeholder row carries no result, so the query has to come from the
     * arguments — otherwise a running card says nothing about what it asked.
     */
    @Test
    fun `a running search_skills shows the query from its arguments`() {
        val model = ToolCard.from(
            toolRow("search_skills", "null", parameters = """{"query":"git.*","limit":20}"""),
        )

        assertTrue(model.pending)
        assertEquals("git.*", model.primary)
        assertNull(model.rightMeta)
    }

    /**
     * `use_skill` is the one skill tool that never sets `success: false` —
     * `tools_exec_skills.zig` wraps it unconditionally — so a failure is only
     * visible at `data.error`, with the envelope still claiming success. A card
     * that trusts the envelope puts a green tick over "Failed to open file".
     */
    @Test
    fun `a use_skill failure inside a success envelope still reads as a failure`() {
        val model = ToolCard.from(
            toolRow(
                "use_skill",
                """{"skill_name":"nope","content":"","loaded":false,
                   "error":"Failed to open file","available_skills":null}""",
            ),
        )

        assertFalse(model.success)
        assertEquals("Failed to open file", model.errorText)
    }

    @Test
    fun `a successful use_skill is not a failure`() {
        val model = ToolCard.from(
            toolRow(
                "use_skill",
                """{"skill_name":"k","content":"body","loaded":true,"error":null}""",
            ),
        )

        assertTrue(model.success)
        assertNull(model.errorText)
    }

    // ─── memory ─────────────────────────────────────────────────────────────

    @Test
    fun `load_memory reads its counts and hits`() {
        val body = ToolCard.from(
            toolRow(
                "load_memory",
                """{"query":"jwt","id":null,"by_id":false,"limit":10,"offset":0,
                   "with_content":true,"count":1,"total_count":9,
                   "results":[{"id":"mem_1","tags":"auth|jwt",
                   "created_at":null,"updated_at":null,"snippet":"a snippet",
                   "content":null,"truncated":false}]}""",
            ),
        ).body as ToolBody.MemoryLoad

        assertEquals(1, body.count)
        assertEquals(9, body.totalCount)
        assertEquals("a snippet", body.results[0].snippet)
    }

    // ─── kanban / files / worktree / progressive ────────────────────────────

    @Test
    fun `kanban_move_task names the task and its column`() {
        val model = ToolCard.from(
            toolRow(
                "kanban_move_task",
                """{"success":true,"task_id":"task_1","task_name":"Fix the thing",
                   "column_id":"col_1","column_name":"in review","position":2}""",
            ),
        )

        val body = model.body as ToolBody.KanbanMove
        assertEquals("Fix the thing", body.taskName)
        assertEquals("in review", body.columnName)
    }

    @Test
    fun `present_files reports byte counts`() {
        val body = ToolCard.from(
            toolRow(
                "present_files",
                """{"status":"presented","count":1,
                   "files":[{"path":"/r.md","bytes":2048,"mime":"text/markdown",
                   "label":"r"}],"error":null}""",
            ),
        ).body as ToolBody.PresentFiles

        assertEquals(2048L, body.files[0].bytes)
        assertEquals("r", body.files[0].label)
    }

    /**
     * The mime used to be dropped here, which is why a screenshot and a zip
     * rendered identically: nothing downstream could tell them apart. It is
     * the only field that says whether a file can be previewed.
     */
    @Test
    fun `present_files keeps the mime so the card can classify the file`() {
        val body = ToolCard.from(
            toolRow(
                "present_files",
                """{"status":"presented","count":1,
                   "files":[{"path":"/shot.png","bytes":48211,
                   "mime":"image/png","label":"shot"}],"error":null}""",
            ),
        ).body as ToolBody.PresentFiles

        assertEquals("image/png", body.files[0].mime)
    }

    /** A row cached before the field existed still parses. */
    @Test
    fun `present_files tolerates a file with no mime`() {
        val body = ToolCard.from(
            toolRow(
                "present_files",
                """{"status":"presented","count":1,
                   "files":[{"path":"/old.txt","bytes":12,"label":"old"}],
                   "error":null}""",
            ),
        ).body as ToolBody.PresentFiles

        assertEquals("", body.files[0].mime)
        assertEquals("/old.txt", body.files[0].path)
    }

    @Test
    fun `set_git_worktree keeps the path and branch`() {
        val body = ToolCard.from(
            toolRow(
                "set_git_worktree",
                """{"session_id":"s1","created":true,"cleared":false,
                   "path":"/wt","branch":"wt/fix","base":"origin/main",
                   "note":null,"error":null}""",
            ),
        ).body as ToolBody.Worktree

        assertEquals("/wt", body.path)
        assertEquals("wt/fix", body.branch)
        assertEquals("origin/main", body.base)
    }

    @Test
    fun `search_tool reads the wrapped tools array`() {
        val body = ToolCard.from(
            toolRow(
                "search_tool",
                """{"query":"git","pattern_mode":"literal","pattern_warning":null,
                   "server":null,"count":1,"total":1,"offset":0,"limit":20,
                   "tools":[{"name":"view_tool","kind":"builtin","server":null,
                   "equipped":"session","summary":"s"}],
                   "truncated":false,"next_offset":null,"hint":""}""",
            ),
        ).body as ToolBody.ProgressiveTool

        assertEquals(1, body.count)
        assertEquals("view_tool", body.tools[0].name)
    }

    // ─── web search ─────────────────────────────────────────────────────────

    /**
     * `web_search` hands the provider's JSON through untyped (D13): TinyFish
     * says `{results:[…]}`, Brave `{web:{results:[…]}}`, Serper `{organic:[…]}`,
     * a self-hosted SearxNG a bare `[{…}]`. A typed body would have to name
     * one of them and silently discard the rest, so the payload is rendered
     * as the text it is — and the card is still a *known* row, not a
     * fall-through.
     */
    @Test
    fun `web_search renders the provider payload it was given`() {
        val model = ToolCard.from(
            toolRow(
                "web_search",
                """{"provider":"brave","status":200,
                   "response":{"web":{"results":[{"title":"a","url":"https://x","description":"d"}]}}}""",
                parameters = """{"provider":"brave","curl":"curl 'https://api.search.brave.com?q=x'"}""",
            ),
        )

        assertEquals(ToolKind.WebSearch, model.kind)
        assertEquals("brave", model.primary)
        val body = model.body as ToolBody.Raw
        assertTrue(body.text.contains("results"))
        assertTrue(body.text.contains("https://x"))
    }

    @Test
    fun `a running web_search names the provider from its arguments`() {
        val model = ToolCard.from(
            toolRow(
                "web_search",
                "null",
                parameters = """{"provider":"tinyfish","curl":"curl 'https://api/x?q=1'"}""",
            ),
        )

        assertEquals(ToolKind.WebSearch, model.kind)
        assertTrue(model.pending)
        assertEquals("tinyfish", model.primary)
    }

    /**
     * A failure envelope carries `data:null` and the reason in `error`, so
     * there is nothing to draw in the body — and the card must still say why.
     */
    @Test
    fun `a failed web_search reports the envelope error`() {
        val model = ToolCard.from(
            toolRow(
                "web_search",
                "null",
                success = false,
                error = "Search provider 'tinyfish' quota exhausted (HTTP 429).",
            ),
        )

        assertEquals(ToolKind.WebSearch, model.kind)
        assertFalse(model.success)
        assertEquals(ToolBody.Empty, model.body)
        assertEquals("Search provider 'tinyfish' quota exhausted (HTTP 429).", model.errorText)
    }

    @Test
    fun `list_web_search_providers shows the curl template with its {key} placeholder`() {
        val model = ToolCard.from(
            toolRow(
                "list_web_search_providers",
                """{"providers":[{"name":"tinyfish","url":"https://api.search.tinyfish.ai",
                   "description":"TinyFish",
                   "curl":"curl 'https://api.search.tinyfish.ai/search?q=x&key={key}'"}]}""",
            ),
        )

        assertEquals(ToolKind.ListSearchProviders, model.kind)
        // The listing is inert by construction (D14): the template carries the
        // literal `{key}`, so a card may show it — and must never show a key.
        val body = model.body as ToolBody.Raw
        assertTrue(body.text.contains("{key}"))
        assertTrue(body.text.contains("tinyfish"))
    }

    // ─── fallbacks ──────────────────────────────────────────────────────────

    /**
     * `remove_file` still emits XML, so its "JSON" payload is `{"_raw": …}`. A
     * client that only knows JSON renders an empty card for every real call.
     */
    @Test
    fun `a raw payload body renders as text`() {
        val model = ToolCard.from(
            toolRow(
                "remove_file",
                """{"_raw":"<path>/proj/x.txt</path>\n<deleted>true</deleted>"}""",
            ),
        )

        assertEquals(ToolKind.Raw, model.kind)
        assertEquals("<path>/proj/x.txt</path>\n<deleted>true</deleted>", (model.body as ToolBody.Raw).text)
    }

    @Test
    fun `an mcp success renders the server's raw text`() {
        val model = ToolCard.from(toolRow("mcp_graphify_stats", RAW))

        assertEquals(ToolKind.Mcp, model.kind)
        assertEquals("not an envelope", (model.body as ToolBody.Mcp).text)
    }

    @Test
    fun `an interrupted row is a failure but still renders its text`() {
        val message = ChatMessage(
            id = "row_1",
            role = ChatMessage.ROLE_TOOL,
            content = "<interrupted>Tool execution was interrupted by server restart.</interrupted>",
            createdAtEpochMillis = 0L,
            sortKeyNanos = 0L,
            toolName = "bash",
        )

        val model = ToolCard.from(message)
        // The tool is still a shell as far as dispatch goes; what changed is
        // that there is no payload to render, so the body is the text itself
        // rather than an empty card.
        assertEquals(ToolKind.Shell, model.kind)
        assertFalse(model.success)
        assertTrue((model.body as ToolBody.Raw).text.contains("interrupted"))
    }

    @Test
    fun `a tool with no result and no arguments is empty but not failed`() {
        val model = ToolCard.from(toolRow("stop_run", "null"))

        assertTrue(model.pending)
        assertEquals(ToolBody.Empty, model.body)
        assertNull(model.primary)
    }

    @Test
    fun `an unknown tool keeps a readable body`() {
        val body = ToolCard.from(
            toolRow("mystery", """{"alpha":1,"beta":"two"}"""),
        ).body as ToolBody.Raw

        assertTrue(body.text.contains("alpha"))
        assertTrue(body.text.contains("two"))
    }

    @Test
    fun `the dispatch is total - no tool name falls through`() {
        val names = listOf(
            "read_file", "write_file", "bash", "pwsh", "run_command", "command",
            "search", "glob", "list_directory", "text_replace", "update_plan",
            "get_plan", "ask_user", "spawn_sub_agent", "list_agents",
            "save_memory", "load_memory", "list_memory", "search_skills",
            "use_skill", "add_skill", "edit_skill", "remove_skill",
            "kanban_move_task", "kanban_list", "present_files", "generate_image",
            "web_search", "list_web_search_providers",
            "set_git_worktree", "read_workspace_session", "search_tool",
            "view_tool", "use_tool", "mcp_anything", "list_memory",
        )

        // `brand_new` and `remove_file` are deliberately absent: the first is
        // the unknown-tool control, and the second's payload is raw XML by
        // design — ToolKind.Raw is their *correct* dispatch, not a fall-through.
        // Both are asserted above.
        names.forEach { name ->
            val model = ToolCard.from(toolRow(name, "{}"))
            // Not merely "some body": an empty `{}` payload satisfies almost any
            // assertion, including a silent fall-through to the raw renderer.
            assertNotEquals(
                "a known tool fell through to the generic renderer: $name",
                ToolKind.Raw,
                model.kind,
            )
        }
    }

    private fun runningGlyph(model: ToolCardModel) =
        if (model.pending) "·" else "?"

    private companion object {
        /** A sentinel: "this row's content is not JSON at all". */
        const val RAW = "__raw__"
    }
}
