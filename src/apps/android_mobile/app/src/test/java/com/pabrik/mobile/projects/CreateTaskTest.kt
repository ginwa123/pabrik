package com.pabrik.mobile.projects

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.recents.HomeViewModel
import com.pabrik.mobile.recents.RecentsApi
import com.pabrik.mobile.recents.RecentsClient
import com.pabrik.mobile.recents.RecentsResult
import com.pabrik.mobile.testing.InMemoryLastPositionStore
import com.pabrik.mobile.testing.InMemoryProjectsCache
import com.pabrik.mobile.testing.InMemoryRecentsCache
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// ─── The wire shapes ───────────────────────────────────────────────────────────

/** The request and response the create endpoint is read by. */
class CreateTaskWireTest {

    @Test
    fun theCreatePathIsTheSameRouteTheListReads() {
        // Creating does not get its own endpoint on the server — main.zig:815 registers one POST handler on the same path the drawer GETs.
        assertEquals(
            "/api/workspaces/ws_1/items/item_1/tasks",
            ProjectsApi.createTaskPath("ws_1", "item_1"),
        )
    }

    @Test
    fun thePathEncodesBothIds() {
        // An id containing `/` would split into two path segments and land on a different route — a 404 that reads as "not found" rather than as a client bug.
        assertEquals(
            "/api/workspaces/w%20s/items/a%2Fb/tasks",
            ProjectsApi.createTaskPath("w s", "a/b"),
        )
    }

    @Test
    fun aStandardChatSendsTheNameAndItsType() {
        val body = JSONObject(ProjectsApi.createTaskBody(CreateTaskRequest.StandardChat("New Chat")))

        assertEquals("New Chat", body.getString("name"))
        assertEquals(TaskTypes.STANDARD, body.getString("task_type"))
        // A standard chat carries nothing else.
        assertFalse(body.has("memory_name"))
        assertFalse(body.has("memory_content"))
        assertFalse(body.has("is_auto_retry_until_stop"))
        assertFalse(body.has("tags"))
    }

    @Test
    fun theDefaultChatNameIsTheOnesTheDesktopUses() {
        // Sidebar.vue:82.
        assertEquals("New Chat", TaskTypes.DEFAULT_NEW_CHAT_NAME)
    }

    @Test
    fun aMemorySendsItsFilenameTwice() {
        // `name` is the display name and `memory_name` is the file, and the handler reads them separately (task_create.zig:257).
        val body = JSONObject(
            ProjectsApi.createTaskBody(CreateTaskRequest.Memory("notes.md", "# hi")),
        )

        assertEquals("notes.md", body.getString("name"))
        assertEquals("notes.md", body.getString("memory_name"))
        assertEquals("# hi", body.getString("memory_content"))
        assertEquals(TaskTypes.MEMORY, body.getString("task_type"))
    }

    @Test
    fun theFilenameIsTrimmed() {
        // The desktop does not trim.
        val body = JSONObject(
            ProjectsApi.createTaskBody(CreateTaskRequest.Memory("  notes.md  ", "x")),
        )
        assertEquals("notes.md", body.getString("memory_name"))
    }

    @Test
    fun theCreatedTaskBecomesAProjectChatKeyedByItsOwnId() {
        val created = ProjectsApi.parseCreatedTask(
            body = """{"id":"task_9","name":"New Chat","workspace_item_id":"item_1",""" +
                """"task_type":"standard","session_id":null,""" +
                """"created_at":"2026-09-26 05:12:37","updated_at":"2026-09-26 05:12:40"}""",
            projectId = "item_1",
        )

        // The task id IS the session id (http_response.zig says so in its own comment), which is the only reason a created chat is navigable with no second lookup.
        assertEquals("task_9", created?.id)
        assertEquals("item_1", created?.projectId)
        assertEquals("New Chat", created?.displayName)
        assertEquals(TaskTypes.STANDARD, created?.taskType)
        assertTrue(created!!.hasTimestamp)
        assertTrue(created.isOpenable)
    }

    @Test
    fun aCreatedMemoryIsNotOpenable() {
        // A memory task has no session.
        val created = ProjectsApi.parseCreatedTask(
            body = """{"id":"task_3","name":"notes.md","task_type":"memory",""" +
                """"session_id":null,"created_at":"2026-09-26 05:12:37"}""",
            projectId = "item_1",
        )

        assertEquals(TaskTypes.MEMORY, created?.taskType)
        assertFalse(created!!.isOpenable)
    }

    @Test
    fun aRowWithoutAnIdIsRefusedRatherThanInvented() {
        // There would be nothing to open and nothing to select, and a blank row in the drawer reads as a create that half-worked.
        assertNull(
            ProjectsApi.parseCreatedTask("""{"name":"New Chat"}""", projectId = "item_1"),
        )
    }

    @Test
    fun anUnreadableBodyIsRefusedRatherThanThrown() {
        assertNull(ProjectsApi.parseCreatedTask("<html>502</html>", projectId = "item_1"))
    }

    @Test
    fun aTaskListRowIsStillTreatedAsOpenable() {
        // The list endpoint reports no `task_type`, so it stays null — and null has to mean "openable", or every existing chat becomes untappable.
        val parsed = ProjectsApi.parseProjectChatsPage(
            body = """{"tasks":[{"id":"t1","name":"chat","updated_at":"2026-09-26 05:12:37"}],""" +
                """"count":1,"has_more":false,"next_cursor":null}""",
            projectId = "item_1",
        )
        assertTrue(parsed.chats.single().isOpenable)
    }
}

// ─── The board card's wire shape ───────────────────────────────────────────────

/** The kanban route, its body, and the envelope it answers in. */
class CreateKanbanTaskWireTest {

    @Test
    fun aCardPostsToTheKanbanRouteNotTheTasksRoute() {
        // Not a `task_type` on the ordinary route.
        assertEquals(
            "/api/workspaces/ws_1/items/item_1/kanban/tasks",
            ProjectsApi.createKanbanTaskPath("ws_1", "item_1"),
        )
        // And it is a genuinely different string from the chat path, so the two cannot be one function with a flag somebody flips twice.
        assertTrue(
            ProjectsApi.createKanbanTaskPath("ws_1", "item_1") !=
                ProjectsApi.createTaskPath("ws_1", "item_1"),
        )
    }

    @Test
    fun theKanbanPathEncodesBothIds() {
        assertEquals(
            "/api/workspaces/w%20s/items/a%2Fb/kanban/tasks",
            ProjectsApi.createKanbanTaskPath("w s", "a/b"),
        )
    }

    @Test
    fun theCardBodyCarriesTheModeAndTheCreateMode() {
        // `mode` is not optional and has no default server-side: without it the handler answers 400 ("mode is required", kanban_tasks_create.zig:110).
        val body = JSONObject(
            ProjectsApi.createTaskBody(CreateTaskRequest.KanbanTask("Card", "body")),
        )
        assertEquals("create", body.getString("mode"))
        assertEquals("Card", body.getString("name"))
        assertEquals("body", body.getString("description"))
    }

    @Test
    fun theCardBodySendsNoTaskType() {
        // The handler forces `task_type='standard'` for every kanban mode (kanban_tasks_create.zig:169).
        assertFalse(
            JSONObject(
                ProjectsApi.createTaskBody(CreateTaskRequest.KanbanTask("Card", "")),
            ).has("task_type"),
        )
    }

    @Test
    fun theCardTitleIsTrimmedLikeEveryOtherName() {
        assertEquals(
            "Ship it",
            JSONObject(
                ProjectsApi.createTaskBody(CreateTaskRequest.KanbanTask("  Ship it  ", "")),
            ).getString("name"),
        )
    }

    @Test
    fun anEmptyDescriptionIsSentRatherThanOmitted() {
        // The desktop sends the same three fields for the same card (workspaces.ts:3357-3365).
        assertEquals(
            "",
            JSONObject(
                ProjectsApi.createTaskBody(CreateTaskRequest.KanbanTask("Card", "")),
            ).getString("description"),
        )
    }

    @Test
    fun theCreatedCardIsReadOutOfTheEnvelope() {
        // The plain route answers with a bare row; this one wraps it in `{task, session}`.
        val created = ProjectsApi.parseCreatedKanbanTask(
            body = """{"task":{"id":"task_9","name":"Card","description":"body",""" +
                """"completed":false,"is_have_image":false,"is_have_video":false},""" +
                """"session":null}""",
            projectId = "item_1",
        )

        assertEquals("task_9", created?.id)
        assertEquals("Card", created?.name)
        assertEquals("item_1", created?.projectId)
        // No `task_type` on this route, and null means openable — which is right, because `task_create.useCase` does insert the bare `sessions` row behind a …
        assertNull(created?.taskType)
        assertTrue(created!!.isOpenable)
    }

    @Test
    fun aCardWithNoTimestampSaysSoRatherThanGuessing() {
        // `TaskCreateResponse` carries neither `updated_at` nor `created_at` (kanban_tasks_create.zig:404-411).
        val created = ProjectsApi.parseCreatedKanbanTask(
            body = """{"task":{"id":"task_9","name":"Card"},"session":null}""",
            projectId = "item_1",
        )
        assertEquals(RecentsApi.UNKNOWN_TIMESTAMP, created?.updatedAtEpochMillis)
        assertFalse(created!!.hasTimestamp)
    }

    @Test
    fun anEnvelopeWithNoTaskIsRefusedRatherThanInvented() {
        // `{ok:true}` and a body whose `task` has no id are both "the server said 201 and there is no card".
        assertNull(
            ProjectsApi.parseCreatedKanbanTask("""{"ok":true}""", projectId = "item_1"),
        )
        assertNull(
            ProjectsApi.parseCreatedKanbanTask(
                """{"task":{"name":"Card"},"session":null}""",
                projectId = "item_1",
            ),
        )
    }

    @Test
    fun anUnreadableCardBodyIsRefusedRatherThanThrown() {
        assertNull(
            ProjectsApi.parseCreatedKanbanTask("<html>502</html>", projectId = "item_1"),
        )
    }

    @Test
    fun aSessionInTheEnvelopeIsIgnoredRatherThanTreatedAsTheCard() {
        // `mode='create'` never populates `session`, so this shape does not arise today.
        val created = ProjectsApi.parseCreatedKanbanTask(
            body = """{"task":{"id":"task_9","name":"Card"},""" +
                """"session":{"id":"task_9","name":"Card","status":"idle"}}""",
            projectId = "item_1",
        )
        assertEquals("task_9", created?.id)
        assertEquals("Card", created?.name)
    }
}

// ─── The memory name rules ─────────────────────────────────────────────────────

/** Mirrors of the server's `isValidMemoryName`, asserted branch by branch. */
class MemoryNameRulesTest {

    @Test
    fun aPlainMarkdownFilenameIsValid() {
        assertTrue(isValidMemoryName("notes.md"))
    }

    @Test
    fun theNameIsTrimmedFirst() {
        // The server trims before every check, so `" a.md "` is valid there.
        assertTrue(isValidMemoryName("   spaced.md \n"))
    }

    @Test
    fun anythingNotEndingInMdIsRefused() {
        assertFalse(isValidMemoryName("notes.txt"))
        assertFalse(isValidMemoryName("md"))
        assertFalse(isValidMemoryName("notes.MD"))
    }

    @Test
    fun pathSeparatorsAreRefused() {
        // The name is one path component under `.pabrik/memories/`.
        assertFalse(isValidMemoryName("docs/notes.md"))
        assertFalse(isValidMemoryName("docs\\notes.md"))
    }

    @Test
    fun parentReferencesAreRefused() {
        assertFalse(isValidMemoryName("../secrets.md"))
        assertFalse(isValidMemoryName("a..b.md"))
    }

    @Test
    fun blankIsRefused() {
        assertFalse(isValidMemoryName(""))
        assertFalse(isValidMemoryName("    "))
    }

    @Test
    fun theFormNeedsBothAValidNameAndSomeContent() {
        assertTrue(canSubmitMemory("notes.md", "something"))
        assertFalse(canSubmitMemory("notes.md", "   "))
        assertFalse(canSubmitMemory("notes.txt", "something"))
    }
}

// ─── Which projects get a picker ───────────────────────────────────────────────

/** The rule that decides what `+` does, per `item_type`. */
class CreateTaskStartDecisionTest {

    @Test
    fun anAgentProjectSkipsThePickerAndMakesAChat() {
        // Sidebar.vue:895-906.
        val decision = createTaskStartDecision(ProjectTypes.AGENT)

        assertEquals(
            CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME),
            (decision as CreateTaskStartDecision.Create).request,
        )
    }

    @Test
    fun aRoutineProjectTakesNothing() {
        // A scheduler-owned item has no task list.
        assertEquals(
            CreateTaskStartDecision.NotAllowed,
            createTaskStartDecision(ProjectTypes.ROUTINE),
        )
    }

    @Test
    fun aKanbanProjectOpensTheCardFormWithNothingInBetween() {
        // The reader asked for a card by pressing `+` on a board, so `+` opens the card form.
        assertEquals(
            CreateTaskStartDecision.NameTask,
            createTaskStartDecision(ProjectTypes.KANBAN),
        )
    }

    @Test
    fun aKanbanProjectNeverOpensTheTypePicker() {
        // The other half of the assertion above, and the one that would catch a regression: a kanban that fell through to `Pick` would still be "a picker" and would …
        assertFalse(
            createTaskStartDecision(ProjectTypes.KANBAN) is CreateTaskStartDecision.Pick,
        )
    }

    @Test
    fun onlyAKanbanBoardGetsTheCardForm() {
        // `NameTask` is its own case rather than a flag on `Pick` precisely so this is assertable: no other project type may open a board's form, and no board may reach …
        for (type in listOf(
            ProjectTypes.AGENT,
            ProjectTypes.ROUTINE,
            ProjectTypes.DESIGN,
            ProjectTypes.FOLDER,
            "something_new",
        )) {
            assertEquals(
                "item_type=$type must not open the card form",
                false,
                createTaskStartDecision(type) is CreateTaskStartDecision.NameTask,
            )
        }
    }

    @Test
    fun anUnknownTypeGetsThePickerRatherThanAGuess() {
        // Offering both options is the recoverable mistake; picking one on the reader's behalf and being wrong creates something they did not ask for, which they then …
        assertEquals(CreateTaskStartDecision.Pick, createTaskStartDecision("something_new"))
    }

    @Test
    fun onlyAChatIsADestination() {
        assertTrue(CreateTaskRequest.StandardChat("x").opensChat)
        // A memory is a file on disk.
        assertFalse(CreateTaskRequest.Memory("x.md", "y").opensChat)
        // A board card is the third non-destination, and for a different reason: a session *does* exist behind it, so tapping the row opens it fine.
        assertFalse(CreateTaskRequest.KanbanTask("Card", "body").opensChat)
    }
}

// ─── The controller's state machine ────────────────────────────────────────────

/** The two steps, and every way out of them. */
class CreateTaskControllerTest {

    private val created = mutableListOf<Triple<String, String, CreateTaskRequest>>()

    private fun controller() = CreateTaskController { w, i, r -> created += Triple(w, i, r) }

    /** A non-kanban parent, i.e. one that opens the two-card chat/memory picker. */
    private fun item(type: String = ProjectTypes.FOLDER) = ProjectSummary(
        id = "item_1",
        workspaceId = "ws_1",
        itemType = type,
        name = "Shared project",
    )

    /** The same fixture as a kanban board, so the board steps are readable. */
    private fun board(path: String = "") = ProjectSummary(
        id = "item_1",
        workspaceId = "ws_1",
        itemType = ProjectTypes.KANBAN,
        name = "Sprint board",
        path = path,
    )

    @Test
    fun pickingStandardCreatesAChatAndCloses() {
        val c = controller()
        c.start(item())
        assertEquals(
            CreateTaskStep.Picking("ws_1", "item_1", "Shared project"),
            c.step,
        )

        c.pickStandardChat()

        assertEquals(CreateTaskStep.Idle, c.step)
        assertEquals(1, created.size)
        assertEquals(
            CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME),
            created.single().third,
        )
    }

    @Test
    fun pickingMemoryAsksForANameRatherThanCreating() {
        val c = controller()
        c.start(item())
        c.pickMemory()

        // Nothing sent yet — the form has to be filled in first.
        assertEquals(0, created.size)
        assertEquals(
            CreateTaskStep.NamingMemory("ws_1", "item_1", "Shared project"),
            c.step,
        )
    }

    @Test
    fun submittingTheFormSendsTheTrimmedNameAndTheContent() {
        val c = controller()
        c.start(item())
        c.pickMemory()
        c.submitMemory("  notes.md  ", "# hello")

        assertEquals(CreateTaskStep.Idle, c.step)
        assertEquals(CreateTaskRequest.Memory("notes.md", "# hello"), created.single().third)
    }

    @Test
    fun anInvalidMemoryIsNotSent() {
        // The button is disabled for this, so this is the invariant behind the affordance.
        val c = controller()
        c.start(item())
        c.pickMemory()
        c.submitMemory("notes.txt", "# hello")

        assertEquals(0, created.size)
        // Still open, so the reader can fix the name rather than start over.
        assertEquals(CreateTaskStep.NamingMemory("ws_1", "item_1", "Shared project"), c.step)
    }

    @Test
    fun backFromTheFormReturnsToThePickerForTheSameProject() {
        val c = controller()
        c.start(item())
        c.pickMemory()
        c.backToPicker()

        assertEquals(CreateTaskStep.Picking("ws_1", "item_1", "Shared project"), c.step)
    }

    @Test
    fun anAgentCreatesWithoutAnythingOpening() {
        val c = controller()
        c.start(item(ProjectTypes.AGENT))

        assertEquals(1, created.size)
        assertEquals(CreateTaskStep.Idle, c.step)
    }

    @Test
    fun aRoutineDoesNothingAtAll() {
        val c = controller()
        c.start(item(ProjectTypes.ROUTINE))

        assertEquals(0, created.size)
        assertEquals(CreateTaskStep.Idle, c.step)
    }

    @Test
    fun dismissingClosesWhateverIsOpen() {
        val c = controller()
        c.start(item())
        c.pickMemory()
        c.dismiss()

        assertEquals(CreateTaskStep.Idle, c.step)
    }

    @Test
    fun aPickingStepRefusesAMemorySubmission() {
        // Two steps, one controller.
        val c = controller()
        c.start(item())
        c.submitMemory("notes.md", "x")

        assertEquals(0, created.size)
        assertEquals(CreateTaskStep.Picking("ws_1", "item_1", "Shared project"), c.step)
    }

    // ── The board pair ──────────────────────────────────────────────────────

    @Test
    fun aBoardOpensTheCardFormAndNotTheChatOne() {
        val c = controller()
        c.start(board())

        assertEquals(
            CreateTaskStep.NamingTask("ws_1", "item_1", "Sprint board", ""),
            c.step,
        )
        // Nothing is sent on the way in: the press opens a form, and a form that created on open would make `Cancel` a lie.
        assertEquals(0, created.size)
    }

    @Test
    fun theBoardFormIsOpenedWithTheBoardsOwnPathAsTheProjectRoot() {
        // The web prefills "Project root" from the parent kanban's path, so the field arrives already right instead of empty-and-wrong.
        val c = controller()
        c.start(board(path = "/home/ginwa/ginwaaitoolbox"))

        assertEquals(
            CreateTaskStep.NamingTask(
                "ws_1",
                "item_1",
                "Sprint board",
                "/home/ginwa/ginwaaitoolbox",
            ),
            c.step,
        )
    }

    @Test
    fun submittingTheBoardFormSendsATrimmedTitleAndTheDescriptionUntouched() {
        val c = controller()
        c.start(board())
        c.submitTask("  Ship the picker  ", "  keep\nthe spacing  ")

        assertEquals(CreateTaskStep.Idle, c.step)
        assertEquals(1, created.size)
        // Title trimmed, body not: the description is the card's face, printed verbatim on the board, so trimming it would edit what was written.
        assertEquals(
            CreateTaskRequest.KanbanTask("Ship the picker", "  keep\nthe spacing  "),
            created.single().third,
        )
        assertEquals("ws_1", created.single().first)
        assertEquals("item_1", created.single().second)
    }

    @Test
    fun anUntitledBoardCardIsNotSent() {
        // The button is disabled for a blank title, so this is the invariant behind the affordance — and the only guard there is, because the server's name rule for a …
        for (blank in listOf("", "   ", "\n\t ")) {
            val c = controller()
            c.start(board())
            c.submitTask(blank, "a body that does not save the card")

            assertEquals(0, created.size)
            // Still open, so the reader can type a title rather than start over.
            assertEquals(
                CreateTaskStep.NamingTask("ws_1", "item_1", "Sprint board", ""),
                c.step,
            )
        }
    }

    @Test
    fun aCardNeedsNoDescriptionToBeWorthCreating() {
        // The reverse of the memory rule, and deliberately so: a card with no body is an idea the board is *for*.
        assertTrue(canSubmitTask("Just a title"))
        assertFalse(canSubmitTask("   "))
        assertFalse(canSubmitMemory("notes.md", "   "))
    }

    @Test
    fun theTwoFlowsCannotReachEachOthersSteps() {
        // A single shared step carrying a flag would make this a one-word change with no test failing, which is why the steps are separate.
        val onBoard = controller()
        onBoard.start(board())
        onBoard.submitMemory("notes.md", "x")
        assertEquals(0, created.size)

        val onAProject = controller()
        onAProject.start(item())
        onAProject.submitTask("Card", "body")
        assertEquals(0, created.size)
        assertEquals(CreateTaskStep.Picking("ws_1", "item_1", "Shared project"), onAProject.step)
    }

    @Test
    fun aBoardCanBeDismissedFromItsForm() {
        val c = controller()
        c.start(board())
        c.dismiss()

        assertEquals(CreateTaskStep.Idle, c.step)
        assertEquals(0, created.size)
    }
}

// ─── The form the board's dialog collects ────────────────────────────────────

/** The nine things the web's create dialog asks for, on the way to the wire. */
class KanbanTaskFormTest {
    @Test
    fun aBareFormPostsExactlyWhatTheWebPostsForACardNobodyTouched() {
        val body = JSONObject(ProjectsApi.createTaskBody(KanbanTaskForm(name = "Card").toRequest()))

        assertEquals(ProjectsApi.KANBAN_MODE_CREATE, body.getString("mode"))
        assertEquals("Card", body.getString("name"))
        assertEquals("", body.getString("description"))
        // Sent, not omitted: "" is the server's "no override" and NULL is not.
        assertEquals("", body.getString("cwd"))
        // Never a boolean and never absent — the column is TEXT.
        assertEquals("0", body.getString("is_auto_retry_until_stop"))
        // Nothing the reader did not ask for.
        assertFalse(body.has("tags"))
        assertFalse(body.has("image_urls"))
        assertFalse(body.has("queue_message"))
        assertFalse(body.has("selected_profile_model"))
    }

    @Test
    fun runAgentSelectsTheOtherModeAndCarriesTheQueueMessage() {
        val body = JSONObject(
            ProjectsApi.createTaskBody(
                KanbanTaskForm(
                    name = "Card",
                    description = "Do the thing",
                    runAgent = true,
                    profile = "fast",
                ).toRequest(),
            ),
        )

        assertEquals(ProjectsApi.KANBAN_MODE_CREATE_AND_RUN, body.getString("mode"))
        // The web's own format, verbatim — this string is what the agent reads.
        assertEquals("Task : Card\nDescription: Do the thing", body.getString("queue_message"))
        assertEquals("fast", body.getString("selected_profile_model"))
    }

    @Test
    fun plainCreateDoesNotPersistAProfile() {
        // "Path A": a plain create has no sessions row to stamp, so sending a profile would be a choice the reader made and the server dropped.
        val body = JSONObject(
            ProjectsApi.createTaskBody(
                KanbanTaskForm(name = "Card", profile = "fast").toRequest(),
            ),
        )

        assertEquals(ProjectsApi.KANBAN_MODE_CREATE, body.getString("mode"))
        assertFalse(body.has("selected_profile_model"))
    }

    @Test
    fun tagsGoOnTheWireAsAJsonEncodedArrayString() {
        // `tags_validation.zig` parses `body.tags` as a JSON *value* and refuses anything that is not an array — a nested array would not be what the server's body …
        val body = JSONObject(
            ProjectsApi.createTaskBody(
                KanbanTaskForm(name = "Card", tags = listOf("bug", "ui")).toRequest(),
            ),
        )

        assertEquals("""["bug","ui"]""", body.getString("tags"))
    }

    @Test
    fun aTagTheServerWouldRefuseNeverReachesTheWire() {
        val body = JSONObject(
            ProjectsApi.createTaskBody(
                KanbanTaskForm(name = "Card", tags = listOf("ok", "has space", "")).toRequest(),
            ),
        )

        assertEquals("""["ok"]""", body.getString("tags"))
    }

    @Test
    fun unattendedIsTheStringsTheColumnStores() {
        val body = JSONObject(
            ProjectsApi.createTaskBody(
                KanbanTaskForm(name = "Card", unattended = true).toRequest(),
            ),
        )

        assertEquals("1", body.getString("is_auto_retry_until_stop"))
    }

    @Test
    fun imagesAreJoinedWithTheWebsDelimiter() {
        val body = JSONObject(
            ProjectsApi.createTaskBody(
                KanbanTaskForm(
                    name = "Card",
                    imageUrls = listOf("data:image/png;base64,AAA", "data:image/png;base64,BBB"),
                ).toRequest(),
            ),
        )

        assertEquals(
            "data:image/png;base64,AAA||data:image/png;base64,BBB",
            body.getString("image_urls"),
        )
    }

    @Test
    fun theWorktreeBlockAppearsOnlyWhenTheToggleIsOn() {
        val form = KanbanTaskForm(
            name = "Card",
            useGitWorktree = true,
            worktreePath = "/home/ginwa/.config/pabrik/.worktrees/card-1",
            worktreeBaseBranch = "origin/main",
        )

        assertEquals(
            "Task : Card\n\n#Notes UseGitWorktree\n" +
                "Path: /home/ginwa/.config/pabrik/.worktrees/card-1\nBase: origin/main",
            buildKanbanTaskCreateMessage(form),
        )
        // Same form, toggle off: the notes must not travel.
        assertEquals(
            "Task : Card",
            buildKanbanTaskCreateMessage(form.copy(useGitWorktree = false)),
        )
    }

    @Test
    fun anEmptyDescriptionIsOmittedFromTheQueueMessage() {
        // A blank line where the description would be reads as a formatting bug to whoever is reading the transcript.
        assertEquals(
            "Task : Card",
            buildKanbanTaskCreateMessage(KanbanTaskForm(name = "Card", description = "   ")),
        )
    }

    @Test
    fun aCardNeedsOnlyATitle() {
        assertTrue(canSubmitKanbanTask(KanbanTaskForm(name = "Just a title")))
        assertFalse(canSubmitKanbanTask(KanbanTaskForm(name = "   ")))
    }

    @Test
    fun aTagMustBeAsciiBecauseTheServerSaysSo() {
        // `Char::isLetterOrDigit` would accept `é`; `tags_validation.zig`'s `[a-zA-Z0-9_-]` does not, and a phone that accepts what the server refuses produces a create …
        assertNull(KanbanTags.sanitize("café"))
        assertNull(KanbanTags.sanitize("a".repeat(51)))
        assertEquals("a_b-1", KanbanTags.sanitize("  a_b-1  "))
        assertNull(KanbanTags.sanitize("   "))
    }

    @Test
    fun tagsDedupeCaseInsensitivelyAndKeepTheFirstSpelling() {
        assertEquals(listOf("Bug"), KanbanTags.add(listOf("Bug"), "bug"))
        // First spelling wins, so the chip the reader saw is the chip that goes.
        assertEquals(listOf("bug"), KanbanTags.normalize(listOf("bug", "Bug", "  bug  ")))
    }

    @Test
    fun aCommaSeparatedDraftBecomesSeveralTags() {
        assertEquals(
            listOf("a", "b", "c"),
            KanbanTags.commitDraft(emptyList(), "a, b,c"),
        )
    }

    @Test
    fun theWorktreePrefillSlugsTheTaskNameOntoTheServersHome() {
        assertEquals(
            "/home/ginwa/.config/pabrik/.worktrees/ship-the-drawer-1757792000000",
            KanbanWorktree.defaultPath("/home/ginwa", "Ship the drawer!", 1757792000000),
        )
        // A name that is all punctuation still has to name a directory.
        assertEquals("task", KanbanWorktree.slugify("!!! ???"))
        // Trailing slash on the home must not double the separator.
        assertEquals(
            "/home/ginwa/.config/pabrik/.worktrees/card-1",
            KanbanWorktree.defaultPath("/home/ginwa/", "Card", 1),
        )
    }
}

// ─── The client ────────────────────────────────────────────────────────────────

/** The POST itself, and what each status becomes. */
class ProjectsClientCreateTaskTest {

    private class MemorySessionStore(var value: String? = "tok-123") : SessionStore {
        override fun read(): String? = value
        override fun save(cookieValue: String) { value = cookieValue }
        override fun clear() { value = null }
    }

    private class FakeTransport(
        var response: AuthHttpResponse = AuthHttpResponse(200, "{}"),
        var failure: Exception? = null,
    ) : AuthTransport {
        var lastPath: String? = null
        var lastBody: String? = null
        var lastHeaders: Map<String, String> = emptyMap()

        override fun post(
            path: String,
            body: String,
            headers: Map<String, String>,
        ): AuthHttpResponse {
            lastPath = path
            lastBody = body
            lastHeaders = headers
            failure?.let { throw it }
            return response
        }

        override fun get(path: String, headers: Map<String, String>) = response
    }

    private fun client(transport: FakeTransport) =
        ProjectsClient(MemorySessionStore(), httpTransport = transport)

    private val createdBody =
        """{"id":"task_9","name":"New Chat","task_type":"standard","updated_at":"2026-09-26 05:12:40"}"""

    @Test
    fun itPostsToTheTasksRouteWithTheSessionAndTheContentType() {
        val transport = FakeTransport(AuthHttpResponse(200, createdBody))

        client(transport).createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertEquals("/api/workspaces/ws_1/items/item_1/tasks", transport.lastPath)
        // The backend reads the session from this cookie and from nowhere else, and takes no Authorization header and no CSRF token.
        assertEquals("pabrik_session=tok-123", transport.lastHeaders["Cookie"])
        assertEquals("application/json", transport.lastHeaders["Content-Type"])
    }

    @Test
    fun aCardIsPostedToTheKanbanRouteAndReadFromItsEnvelope() {
        // The one client method, two routes, two response shapes.
        val transport = FakeTransport(
            AuthHttpResponse(
                200,
                """{"task":{"id":"task_9","name":"Card"},"session":null}""",
            ),
        )

        val result = client(transport).createTask(
            "ws_1",
            "item_1",
            CreateTaskRequest.KanbanTask("Card", "body"),
        )

        assertEquals("/api/workspaces/ws_1/items/item_1/kanban/tasks", transport.lastPath)
        assertEquals("pabrik_session=tok-123", transport.lastHeaders["Cookie"])
        assertTrue(result is RecentsResult.Loaded)
        assertEquals("task_9", (result as RecentsResult.Loaded).value.id)
    }

    @Test
    fun aChatStillPostsToTheTasksRouteAfterTheCardRouteWasAdded() {
        // The new branch in `createTask` sits between the two existing ones.
        val transport = FakeTransport(AuthHttpResponse(200, createdBody))

        client(transport).createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertEquals("/api/workspaces/ws_1/items/item_1/tasks", transport.lastPath)
    }

    @Test
    fun aMemoryStillPostsToTheTasksRouteAfterTheCardRouteWasAdded() {
        val transport = FakeTransport(AuthHttpResponse(200, createdBody))

        client(transport).createTask(
            "ws_1",
            "item_1",
            CreateTaskRequest.Memory("notes.md", "body"),
        )

        assertEquals("/api/workspaces/ws_1/items/item_1/tasks", transport.lastPath)
    }

    @Test
    fun aCardOnANonKanbanParentReportsTheServersFourOhFour() {
        // The handler checks `item_type = 'kanban'` itself and 404s otherwise (kanban_tasks_create.zig:138-152).
        val result = client(FakeTransport(AuthHttpResponse(404, "")))
            .createTask("ws_1", "item_1", CreateTaskRequest.KanbanTask("Card", ""))

        assertTrue(result is RecentsResult.Unavailable)
    }

    @Test
    fun aCardThatServerAnswersForWithNoRowIsAFailureNotAnEmptyCard() {
        // 201 with `{"ok":true}`: the same rule as the chat route, and it matters more here — a blank row on a board is a card the reader cannot open and cannot explain.
        val result = client(FakeTransport(AuthHttpResponse(201, """{"ok":true}""")))
            .createTask("ws_1", "item_1", CreateTaskRequest.KanbanTask("Card", ""))

        assertTrue(result is RecentsResult.Unavailable)
    }

    @Test
    fun theCreatedRowIsReturnedRatherThanRefetched() {
        val result = client(FakeTransport(AuthHttpResponse(200, createdBody)))
            .createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertTrue(result is RecentsResult.Loaded)
        assertEquals("task_9", (result as RecentsResult.Loaded).value.id)
    }

    @Test
    fun anUnauthorizedCreateSignsOut() {
        // A 401 on a write is the same dead cookie as a 401 on a read.
        val result = client(FakeTransport(AuthHttpResponse(401, "")))
            .createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertEquals(RecentsResult.SignedOut, result)
    }

    @Test
    fun aServerErrorSaysCreateRatherThanLoad() {
        // "Could not load your projects" on a failed create reads as though the create may have worked — which is the ambiguity that sends people looking for a chat that …
        val result = client(FakeTransport(AuthHttpResponse(500, "")))
            .createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        val message = (result as RecentsResult.Unavailable).message
        assertTrue(message, message.contains("create"))
        assertFalse(message, message.contains("load your projects"))
    }

    @Test
    fun aTwoHundredWithNoUsableRowIsAFailureNotAnEmptyChat() {
        // There is nothing here to open or select.
        val result = client(FakeTransport(AuthHttpResponse(200, """{"ok":true}""")))
            .createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertTrue(result is RecentsResult.Unavailable)
    }

    @Test
    fun anUnreachableServerIsNotAValidationProblem() {
        val transport = FakeTransport(failure = java.io.IOException("no route"))
        val result = client(transport)
            .createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertTrue(result is RecentsResult.Unavailable)
        assertNotNull(transport.lastPath)
    }

    @Test
    fun anUnreadableSessionDoesNotReachTheNetwork() {
        val result = ProjectsClient(
            sessionStore = object : SessionStore {
                override fun read(): String? = throw IllegalStateException("locked")
                override fun save(cookieValue: String) = Unit
                override fun clear() = Unit
            },
            httpTransport = FakeTransport(AuthHttpResponse(200, createdBody)),
        ).createTask("ws_1", "item_1", CreateTaskRequest.StandardChat("New Chat"))

        assertTrue(result is RecentsResult.Unavailable)
    }
}

// ─── The ViewModel ─────────────────────────────────────────────────────────────

@OptIn(ExperimentalCoroutinesApi::class)
private class CreateSchedulers {
    val main = TestCoroutineScheduler()
    val io = TestCoroutineScheduler()
    val mainDispatcher = StandardTestDispatcher(main)
    val ioDispatcher = StandardTestDispatcher(io)

    fun drain() {
        repeat(20) {
            main.advanceUntilIdle()
            io.advanceUntilIdle()
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
private fun createTest(body: suspend TestScope.(CreateSchedulers) -> Unit) = runTest {
    val s = CreateSchedulers()
    Dispatchers.setMain(s.mainDispatcher)
    try {
        body(s)
    } finally {
        Dispatchers.resetMain()
    }
}

/** Answers the reads the ViewModel makes on launch, and scripts the POST. */
private class CreateTransport(
    private val createStatus: Int = 200,
    private val existingChatIds: List<String> = listOf("t1", "t2"),
) : AuthTransport {
    val posts = mutableListOf<String>()
    var postBody: String? = null

    override fun post(path: String, body: String, headers: Map<String, String>): AuthHttpResponse {
        posts += path
        postBody = body
        val isMemory = runCatching { JSONObject(body).optString("task_type") }.getOrNull() ==
            TaskTypes.MEMORY
        val name = runCatching { JSONObject(body).optString("name") }.getOrNull().orEmpty()
        // The kanban handler wraps its row and stamps no timestamp (kanban_tasks_create.zig:388-411); the plain one does neither of those.
        if (path.endsWith("/kanban/tasks")) {
            return AuthHttpResponse(
                createStatus,
                """{"task":{"id":"task_9","name":"$name"},"session":null}""",
            )
        }
        return AuthHttpResponse(
            createStatus,
            """{"id":"task_9","name":"$name","task_type":"${if (isMemory) "memory" else "standard"}",""" +
                """"updated_at":"2026-09-26 05:12:40"}""",
        )
    }

    override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
        return when {
            path.startsWith("/api/workspaces/") && path.endsWith("/items") ->
                AuthHttpResponse(
                    200,
                    """{"items":[{"id":"item_1","workspace_id":"ws_1",""" +
                        """"item_type":"kanban","name":"sprint board"}],"count":1}""",
                )

            path.contains("/items/") && path.contains("/tasks") -> {
                val tasks = existingChatIds.joinToString(",") {
                    "{\"id\":\"$it\",\"name\":\"chat $it\",\"updated_at\":\"2026-09-26 05:12:37\"}"
                }
                AuthHttpResponse(
                    200,
                    """{"tasks":[$tasks],"count":${existingChatIds.size},""" +
                        """"has_more":false,"next_cursor":null}""",
                )
            }

            path.startsWith("/api/session") ->
                AuthHttpResponse(200, """{"sessions":[],"has_more":false,"next_cursor":null,"total":0}""")

            else -> AuthHttpResponse(200, """{"workspaces":[{"id":"ws_1","name":"Kabelweb"}]}""")
        }
    }
}

private fun createViewModel(
    ioDispatcher: kotlinx.coroutines.CoroutineDispatcher,
    transport: AuthTransport,
    cache: InMemoryProjectsCache = InMemoryProjectsCache(),
) = HomeViewModel(
    client = RecentsClient(EmptySessionStore(), httpTransport = transport),
    cache = InMemoryRecentsCache(),
    projectsClient = ProjectsClient(EmptySessionStore(), httpTransport = transport),
    projectsCache = cache,
    // The same transport as every other client in this test, so a test that drives the board's form data or the card move sees the same fake.
    kanbanClient = KanbanClient(EmptySessionStore(), httpTransport = transport),
    positionStore = InMemoryLastPositionStore(),
    ioDispatcher = ioDispatcher,
)

private class EmptySessionStore : SessionStore {
    override fun read(): String? = "tok"
    override fun save(cookieValue: String) = Unit
    override fun clear() = Unit
}

/** The ViewModel half: what a successful create does to the list, and the three ways it can decide to do nothing. */
class HomeViewModelCreateTaskTest {

    private suspend fun TestScope.launchedWith(
        s: CreateSchedulers,
        transport: AuthTransport,
    ): Pair<HomeViewModel, InMemoryProjectsCache> {
        val cache = InMemoryProjectsCache()
        val model = createViewModel(s.ioDispatcher, transport, cache)
        model.onUserChanged("user_a")
        s.drain()
        // Unfold the project so there is a page for the create to land in.
        model.toggleProjectExpanded("item_1")
        s.drain()
        return model to cache
    }

    @Test
    fun aCreatedChatGoesToTheFrontOfItsProject() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()

        val chats = model.uiState.value.projectChats["item_1"]?.chats.orEmpty()
        // The list is `updated_at desc`, and this row is the newest thing in it.
        assertEquals("task_9", chats.firstOrNull()?.id)
        assertEquals(3, chats.size)
        assertEquals(1, transport.posts.size)
    }

    @Test
    fun theProjectIsOpenedSoTheNewRowIsVisible() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()

        // Creating and then having to unfold a project to find the result is the one outcome that reads as "it didn't work".
        assertTrue(model.uiState.value.isProjectExpanded("item_1"))
    }

    @Test
    fun aCreatedChatIsAnnouncedSoTheGraphCanOpenIt() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport())
        val opened = mutableListOf<String>()
        val collector = CoroutineScope(s.mainDispatcher).launch {
            model.createdChat.collect { opened += it }
        }

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()
        collector.cancel()

        assertEquals(listOf("task_9"), opened)
    }

    @Test
    fun aMemoryIsCreatedButNotAnnouncedAndNotOpenable() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport())
        val opened = mutableListOf<String>()
        val collector = CoroutineScope(s.mainDispatcher).launch {
            model.createdChat.collect { opened += it }
        }

        model.createTask("item_1", CreateTaskRequest.Memory("notes.md", "# hi"))
        s.drain()
        collector.cancel()

        // A memory is a file.
        assertTrue(opened.isEmpty())
        val row = model.uiState.value.projectChats["item_1"]?.chats?.first()
        assertFalse(row!!.isOpenable)
    }

    @Test
    fun aMemoryWithABadNameIsRefusedBeforeTheRequest() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        model.createTask("item_1", CreateTaskRequest.Memory("notes.txt", "# hi"))
        s.drain()

        // No round trip to be told what the label already said.
        assertTrue(transport.posts.isEmpty())
        assertEquals(2, model.uiState.value.projectChats["item_1"]?.chats?.size)
        assertTrue(model.uiState.value.taskCreateError!!.contains(".md"))
    }

    @Test
    fun aMemoryWithNoContentIsRefusedBeforeTheRequest() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        model.createTask("item_1", CreateTaskRequest.Memory("notes.md", "   "))
        s.drain()

        assertTrue(transport.posts.isEmpty())
        assertTrue(model.uiState.value.taskCreateError!!.contains("content"))
    }

    @Test
    fun aSecondCreateWhileOneIsInFlightIsRefused() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        // The first call leaves the busy flag set; a double-tap on `+` is this.
        model.createTask("item_1", CreateTaskRequest.StandardChat("first"))
        model.createTask("item_1", CreateTaskRequest.StandardChat("second"))
        s.drain()

        // Two "New Chat" rows from one tap is the bug this guard exists for.
        assertEquals(1, transport.posts.size)
    }

    @Test
    fun aFailedCreateKeepsEveryRowAndSaysSo() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport(createStatus = 500))

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()

        val state = model.uiState.value
        // Nothing changed: a failed write is not a reason to blank a list.
        assertEquals(2, state.projectChats["item_1"]?.chats?.size)
        assertNotNull(state.taskCreateError)
        assertNull(state.creatingTaskInProjectId)
    }

    @Test
    fun anUnauthorizedCreateSignsOutRatherThanShowingARetryThatCannotWork() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport(createStatus = 401))
        var expired = false
        val collector = CoroutineScope(s.mainDispatcher).launch {
            model.sessionExpired.collect { expired = true }
        }

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()
        collector.cancel()

        assertTrue(expired)
    }

    @Test
    fun theMergeIsWrittenThroughToTheCache() = createTest { s ->
        // The cache is what a cold boot paints, so writing only the new row would replace everything above it on the next launch.
        val (model, cache) = launchedWith(s, CreateTransport())

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()

        val cached = cache.readProjectChats("user_a", "ws_1", "item_1").orEmpty()
        assertEquals(3, cached.size)
        assertEquals("task_9", cached.first().id)
    }

    @Test
    fun dismissingTheErrorClearsOnlyThat() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport(createStatus = 500))
        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()
        assertNotNull(model.uiState.value.taskCreateError)

        model.dismissTaskCreateError()

        // No refetch: a reader who mistyped a filename should not have to reload their projects to un-stick the screen.
        assertNull(model.uiState.value.taskCreateError)
        assertEquals(2, model.uiState.value.projectChats["item_1"]?.chats?.size)
    }

    // ── The board card ──────────────────────────────────────────────────────

    @Test
    fun aCreatedCardLandsInTheProjectAndDoesNotNavigate() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)
        val opened = mutableListOf<String>()
        val collector = CoroutineScope(s.mainDispatcher).launch {
            model.createdChat.collect { opened += it }
        }

        model.createTask("item_1", CreateTaskRequest.KanbanTask("Card", "body"))
        s.drain()
        collector.cancel()

        assertEquals("/api/workspaces/ws_1/items/item_1/kanban/tasks", transport.posts.single())
        // The row is in the board's list, at the front…
        val row = model.uiState.value.projectChats["item_1"]?.chats?.first()
        assertEquals("task_9", row?.id)
        assertEquals("Card", row?.name)
        // …and the reader has NOT been moved into it.
        assertTrue(opened.isEmpty())
        assertNull(model.uiState.value.creatingTaskInProjectId)
        assertNull(model.uiState.value.taskCreateError)
    }

    @Test
    fun aCreatedCardIsOpenableBecauseASessionExistsBehindIt() = createTest { s ->
        // The other half of "does not navigate": not navigating is only right because tapping the row later works.
        val (model, _) = launchedWith(s, CreateTransport())

        model.createTask("item_1", CreateTaskRequest.KanbanTask("Card", "body"))
        s.drain()

        assertTrue(model.uiState.value.projectChats["item_1"]?.chats?.first()!!.isOpenable)
    }

    @Test
    fun aCardWithNoTitleIsRefusedBeforeTheRequest() = createTest { s ->
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        model.createTask("item_1", CreateTaskRequest.KanbanTask("   ", "a body that changes nothing"))
        s.drain()

        // The server's only name rule for a card is "there is one", and the form's button is already disabled — this is the invariant behind it.
        assertTrue(transport.posts.isEmpty())
        assertEquals(2, model.uiState.value.projectChats["item_1"]?.chats?.size)
        assertTrue(model.uiState.value.taskCreateError!!.contains("title"))
        assertNull(model.uiState.value.creatingTaskInProjectId)
    }

    @Test
    fun aCardWithNoBodyIsNotRefused() = createTest { s ->
        // The mirror of the memory rules, and deliberately not the same rule: a titled card with nothing in it is a normal thing to put on a board.
        val transport = CreateTransport()
        val (model, _) = launchedWith(s, transport)

        model.createTask("item_1", CreateTaskRequest.KanbanTask("Just a title", ""))
        s.drain()

        assertEquals(1, transport.posts.size)
        assertNull(model.uiState.value.taskCreateError)
        assertEquals("Just a title", model.uiState.value.projectChats["item_1"]?.chats?.first()?.name)
    }

    @Test
    fun aFailedCardCreateKeepsEveryRowAndSaysSo() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport(createStatus = 500))

        model.createTask("item_1", CreateTaskRequest.KanbanTask("Card", "body"))
        s.drain()

        val state = model.uiState.value
        assertEquals(2, state.projectChats["item_1"]?.chats?.size)
        assertNotNull(state.taskCreateError)
        assertNull(state.creatingTaskInProjectId)
    }

    @Test
    fun aCreateOnACollapsedProjectStillProducesAVisibleRow() = createTest { s ->
        val (model, _) = launchedWith(s, CreateTransport())
        // Fold it back up, and drop the page, so the create has nothing to merge into.
        model.toggleProjectExpanded("item_1")
        s.drain()

        model.createTask("item_1", CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME))
        s.drain()

        val state = model.uiState.value
        assertTrue(state.isProjectExpanded("item_1"))
        assertEquals("task_9", state.projectChats["item_1"]?.chats?.firstOrNull()?.id)
    }
}
