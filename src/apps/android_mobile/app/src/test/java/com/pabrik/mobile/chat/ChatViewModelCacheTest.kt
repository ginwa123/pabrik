package com.pabrik.mobile.chat

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.testing.FakeSseBus
import com.pabrik.mobile.testing.InMemoryChatCache
import java.io.IOException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The cache-then-revalidate contract at the ViewModel level. */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelCacheTest {

    private class Schedulers {
        val main = TestCoroutineScheduler()
        val io = TestCoroutineScheduler()
        val mainDispatcher = StandardTestDispatcher(main)
        val ioDispatcher = StandardTestDispatcher(io)

        fun drain() {
            repeat(30) {
                main.advanceUntilIdle()
                io.advanceUntilIdle()
            }
        }

        /** Everything queued *right now*, and nothing they queue in turn. */
        fun step() {
            io.runCurrent()
            main.runCurrent()
        }
    }

    private fun cacheTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
        val schedulers = Schedulers()
        Dispatchers.setMain(schedulers.mainDispatcher)
        try {
            body(schedulers)
        } finally {
            Dispatchers.resetMain()
        }
    }

    private class MemorySessionStore(var value: String? = "tok") : SessionStore {
        override fun read(): String? = value
        override fun save(cookieValue: String) { value = cookieValue }
        override fun clear() { value = null }
    }

    private fun List<String>.messagesRequest() =
        firstOrNull { it.contains("/messages") } ?: error("no messages request was made")

    private class FakeTransport(
        var messages: String = """{"messages":[],"has_more":false,"next_cursor":null,"total":0}""",
        var streamSnapshot: String = "",
        var sendStatus: Int = 201,
        var offline: Boolean = false,
    ) : AuthTransport {
        val requestedPaths = mutableListOf<String>()
        val sentBodies = mutableListOf<String>()

        override fun post(path: String, body: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            requestedPaths += "$POST $path"
            sentBodies += body
            return AuthHttpResponse(statusCode = sendStatus, body = """{"status":"send"}""")
        }

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            requestedPaths += "$GET $path"
            return AuthHttpResponse(
                statusCode = 200,
                body = if (path.endsWith("/stream")) {
                    streamSnapshot
                } else {
                    messages
                },
            )
        }

        companion object {
            const val POST = "POST"
            const val GET = "GET"
        }
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        cache: ChatCache = InMemoryChatCache(),
        transport: AuthTransport = FakeTransport(),
        bus: FakeSseBus = FakeSseBus(),
    ) = ChatViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        cache = cache,
        bus = bus,
        ioDispatcher = ioDispatcher,
        nowMillis = { 1_789_451_234_000L },
    ).also { it.onUserChanged("user_a") }

    /** A realistic nanosecond stamp. */
    private val nanoBase = 1_789_451_234_567_000_000L

    private fun wire(
        id: String,
        offsetNanos: Long,
        role: String = ChatMessage.ROLE_USER,
        content: String = "hello",
    ) = """{"id":"$id","session_id":"sess_1","role":"$role","content":"$content","created_at":"${nanoBase + offsetNanos}"}"""

    private fun page(vararg messages: String, hasMore: Boolean = false, nextCursor: String? = null) =
        """{"messages":[${messages.joinToString(",")}],"has_more":$hasMore,"next_cursor":${nextCursor?.let { "\"$it\"" } ?: "null"},"total":${messages.size}}"""

    private fun cachedRow(
        id: String,
        offsetNanos: Long,
        role: String = ChatMessage.ROLE_USER,
        content: String = "cached hello",
    ): CachedChatMessage {
        val nanos = nanoBase + offsetNanos
        val raw = """{"id":"$id","session_id":"sess_1","role":"$role","content":"$content","created_at":"$nanos"}"""
        return CachedChatMessage(
            id = id,
            sortKeyNanos = nanos,
            sessionId = "sess_1",
            role = role,
            content = content,
            raw = raw,
        )
    }

    // --- Paint, then revalidate -------------------------------------------

    @Test
    fun `a cached transcript paints before the network returns`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "from disk")))
        }
        val model = model(s.ioDispatcher, cache)

        model.openSession("sess_1")

        // Main alone: the prime is background work, so driving the UI scheduler must not paint it.
        s.main.advanceUntilIdle()
        assertTrue(
            "the cache prime must not run on the caller's thread",
            model.uiState.value.messages.isEmpty(),
        )

        // One step: the cache read has returned and been published, and the fetch is still in flight.
        s.step()
        val state = model.uiState.value
        assertEquals(listOf("from disk"), state.messages.map { it.content })
        assertTrue("still loading behind the painted rows", state.isLoading)
    }

    @Test
    fun `a live frame that lands before the cache prime is not rolled back`() = cacheTest { s ->
        // The prime is background work now, so it can finish after something newer is already on screen.
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "stale")))
        }
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, cache, bus = bus)

        model.openSession("sess_1")
        // The cache read is in flight. A turn completes while it is there.
        s.main.advanceUntilIdle()
        bus.emit(
            ChatStreamEvent.Full(
                "sess_1",
                ChatMessage(
                    id = "m9",
                    role = ChatMessage.ROLE_ASSISTANT,
                    content = "the live answer",
                    createdAtEpochMillis = nanoBase / 1_000_000L + 300L,
                    sortKeyNanos = nanoBase + 300L,
                ),
            ),
        )
        s.drain()

        assertEquals(
            listOf("the live answer"),
            model.uiState.value.messages.map { it.content },
        )
    }

    @Test
    fun `opening a second session drops the first session's prime`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "first chat")))
            writeMessages(
                "user_a",
                "sess_2",
                listOf(cachedRow("m9", 100L, content = "second chat")),
            )
        }
        val model = model(s.ioDispatcher, cache)

        model.openSession("sess_1")
        model.openSession("sess_2")
        s.drain()

        assertEquals("sess_2", model.uiState.value.sessionId)
        assertEquals(
            listOf("second chat"),
            model.uiState.value.messages.map { it.content },
        )
    }

    @Test
    fun `a fresh fetch replaces the cached rows and is written through`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "stale")))
        }
        val model = model(
            s.ioDispatcher,
            cache,
            FakeTransport(messages = page(wire("m1", 100L, content = "fresh"), wire("m2", 200L, content = "newer"))),
        )

        model.openSession("sess_1")
        s.drain()

        assertEquals(listOf("fresh", "newer"), model.uiState.value.messages.map { it.content })
        assertFalse(model.uiState.value.isLoading)
        // Write-through: the next cold start reads the fetched rows, not the
        // stale ones.
        assertEquals(
            listOf("fresh", "newer"),
            cache.readMessages("user_a", "sess_1", 10)!!
                .sortedBy { it.sortKeyNanos }
                .map { it.raw.substringAfter("\"content\":\"").substringBefore("\"") },
        )
    }

    @Test
    fun `a cold start asks for the newest page, a warm one for the tail only`() = cacheTest { s ->
        val transport = FakeTransport(messages = page())

        model(s.ioDispatcher, InMemoryChatCache(), transport).openSession("sess_1")
        s.drain()
        assertTrue(
            transport.requestedPaths.messagesRequest(),
            transport.requestedPaths.messagesRequest().contains("direction=desc"),
        )

        // Second open with a stored cursor: only what is new since it.
        val warm = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L)))
            writeCursor("user_a", "sess_1", "${nanoBase + 100L}")
        }
        val warmTransport = FakeTransport(messages = page())
        model(s.ioDispatcher, warm, warmTransport).openSession("sess_1")
        s.drain()
        assertTrue(
            warmTransport.requestedPaths.messagesRequest(),
            warmTransport.requestedPaths.messagesRequest().contains("direction=asc"),
        )
        assertTrue(
            warmTransport.requestedPaths.messagesRequest().contains("cursor=${nanoBase + 100L}"),
        )
    }

    @Test
    fun `a failed revalidation keeps the cached rows and flags them stale`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "from disk")))
        }
        val model = model(s.ioDispatcher, cache, FakeTransport(offline = true))

        model.openSession("sess_1")
        s.drain()

        val state = model.uiState.value
        // A working chat must not blank because the network blipped.
        assertEquals(listOf("from disk"), state.messages.map { it.content })
        assertTrue("the error must be surfaced", state.errorMessage != null)
        assertTrue(state.isShowingStaleData)
    }

    @Test
    fun `a first launch with no cache and no network is an honest error`() = cacheTest { s ->
        val model = model(s.ioDispatcher, InMemoryChatCache(), FakeTransport(offline = true))

        model.openSession("sess_1")
        s.drain()

        val state = model.uiState.value
        // No cache AND no network is an error, not "this chat is empty" — those
        // are different truths and only one of them is worth a retry.
        assertTrue(state.messages.isEmpty())
        assertTrue(state.errorMessage != null)
        assertFalse(state.isEmptyConversation)
    }

    @Test
    fun `a genuinely empty chat is an empty state, not an error`() = cacheTest { s ->
        val model = model(s.ioDispatcher, InMemoryChatCache(), FakeTransport(messages = page()))

        model.openSession("sess_1")
        s.drain()

        assertNull(model.uiState.value.errorMessage)
        assertTrue(model.uiState.value.isEmptyConversation)
    }

    // --- User isolation ----------------------------------------------------

    @Test
    fun `a blank identity never reads a cache at all`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "A's secret")))
        }
        val model = model(s.ioDispatcher, cache, bus = FakeSseBus())
        model.onUserChanged(null)

        model.openSession("sess_1")

        assertTrue(
            "an unresolved identity must not surface another account's rows",
            model.uiState.value.messages.isEmpty(),
        )
    }

    @Test
    fun `changing account clears the previous transcript before any fetch`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L, content = "A's secret")))
        }
        val model = model(s.ioDispatcher, cache)
        model.openSession("sess_1")
        s.drain()
        assertEquals(1, model.uiState.value.messages.size)

        // B signs in on the same device. B must never see A's turns, not even
        // for the frames before B's own fetch lands.
        model.onUserChanged("user_b")

        assertTrue(model.uiState.value.messages.isEmpty())
    }

    @Test
    fun `signing out purges every namespace so the next account inherits nothing`() = cacheTest { s ->
        val cache = InMemoryChatCache().apply {
            writeMessages("user_a", "sess_1", listOf(cachedRow("m1", 100L)))
        }
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, cache, bus = bus)
        model.openSession("sess_1")
        s.drain()

        model.onSignedOut()
        s.drain()

        assertTrue("sign-out must purge", cache.cleared)
        assertNull(cache.readMessages("user_a", "sess_1", 10))
        // The socket is the root's to close. A stop from here would be the
        // two-socket architecture coming back, and would take the sidebar's
        // worker subscription down with the chat's.
        assertEquals("the chat must not close the shared bus", 0, bus.closeCount)
        assertTrue(model.uiState.value.messages.isEmpty())
    }

    // --- Streaming ---------------------------------------------------------

    @Test
    fun `the bus is already attached before the first fetch so no turn is missed`() = cacheTest { s ->
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, bus = bus)

        model.openSession("sess_1")

        // A tool can finish while the initial load is in flight; a listener
        // attached afterwards can never see that event, and the backend has no
        // replay to ask again. The subscription is made in `init`, so it is
        // attached before any session exists - and there is nothing to re-attach
        // when one is opened, which is the whole point of the shared bus.
        assertEquals(1, bus.subscriberCount)
        assertTrue(model.uiState.value.isLoading)

        // Proved by delivery rather than by a counter: an event arriving during
        // the load reaches the transcript of the chat that is open.
        bus.emit(
            ChatStreamEvent.Chunk(sessionId = "sess_1", index = 0, content = "mid-load"),
        )
        s.drain()
        assertTrue(model.uiState.value.isStreaming)
    }

    @Test
    fun `opening a second chat re-filters the bus instead of resubscribing`() = cacheTest { s ->
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, bus = bus)

        model.openSession("sess_1")
        s.drain()
        assertEquals(1, bus.subscriberCount)

        // A handler still filtered to chat A would drop every event for B, so B
        // would sit there showing "connected" and never receive a turn. The fix
        // used to be a stop-then-start; it is now reading the open session out
        // of the state on every event, which is what the next two assertions
        // prove.
        model.openSession("sess_2")
        s.drain()

        assertEquals("switching chats must not churn the socket", 1, bus.subscriberCount)
        assertEquals(0, bus.openCount)
        assertEquals(0, bus.closeCount)

        // A's event, after the switch, must not reach B.
        bus.emit(ChatStreamEvent.Chunk(sessionId = "sess_1", index = 0, content = "for A"))
        s.drain()
        assertFalse("chat B must not take chat A's turn", model.uiState.value.isStreaming)

        // B's must.
        bus.emit(ChatStreamEvent.Chunk(sessionId = "sess_2", index = 0, content = "for B"))
        s.drain()
        assertTrue(model.uiState.value.isStreaming)
    }

    @Test
    fun `a warm tail refresh does not destroy the ability to page backwards`() = cacheTest { s ->
        val transport = FakeTransport(
            messages = page(wire("m1", 100L), wire("m2", 200L), hasMore = true, nextCursor = "100"),
        )
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport, bus)
        model.openSession("sess_1")
        s.drain()
        assertTrue("the first load is a full one", model.uiState.value.hasMoreOlder)

        // Any warm revalidate — a session rename, a reconnect — is short by definition, so the server answers has_more=false for it.
        transport.messages = page(wire("m3", 300L))
        bus.state(ChatStreamState.Live)
        bus.state(ChatStreamState.Reconnecting)
        bus.state(ChatStreamState.Live)
        s.drain()

        assertTrue(
            "a short tail page must not switch off scroll-back for good",
            model.uiState.value.hasMoreOlder,
        )
    }

    @Test
    fun `chunks append rather than replace`() = cacheTest { s ->
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, bus = bus)
        model.openSession("sess_1")
        s.drain()

        bus.emit(ChatStreamEvent.Chunk("sess_1", 0, content = "Hel"))
        bus.emit(ChatStreamEvent.Chunk("sess_1", 0, content = "lo "))
        bus.emit(ChatStreamEvent.Chunk("sess_1", 0, reasoningContent = "hmm"))
        bus.emit(ChatStreamEvent.Chunk("sess_1", 0, content = "world"))

        val streaming = model.uiState.value.messages.single()
        // The backend sends raw provider deltas.
        assertEquals("Hello world", streaming.content)
        assertEquals("hmm", streaming.reasoningContent)
        assertTrue(streaming.isStreaming)
        assertTrue(streaming.id.startsWith(ChatMessage.STREAMING_ID_PREFIX))
    }

    @Test
    fun `a full frame replaces the streaming placeholder and lands in the cache`() = cacheTest { s ->
        val cache = InMemoryChatCache()
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, cache, bus = bus)
        model.openSession("sess_1")
        s.drain()

        bus.emit(ChatStreamEvent.Chunk("sess_1", 0, content = "partia"))
        bus.emit(ChatStreamEvent.ChunkFinished("sess_1", 42))
        val canonical = ChatMessage(
            id = "m9",
            role = ChatMessage.ROLE_ASSISTANT,
            content = "the complete answer",
            createdAtEpochMillis = nanoBase / 1_000_000L + 300L,
            sortKeyNanos = nanoBase + 300L,
        )
        bus.emit(ChatStreamEvent.Full("sess_1", canonical))
        s.drain()

        val messages = model.uiState.value.messages
        assertEquals(1, messages.size)
        assertEquals("the complete answer", messages.single().content)
        assertFalse("the placeholder must be gone", messages.single().isStreaming)
        // Write-through, so a cold start reads the completed turn rather than a stub or nothing at all.
        assertEquals("m9", cache.readMessages("user_a", "sess_1", 10)!!.single().id)
    }

    @Test
    fun `a reconnect refetches because the server has no replay`() = cacheTest { s ->
        val transport = FakeTransport(messages = page(wire("m1", 100L)))
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport, bus)
        model.openSession("sess_1")
        s.drain()
        val afterFirstLoad = transport.requestedPaths.size

        bus.state(ChatStreamState.Live)
        bus.state(ChatStreamState.Reconnecting)
        transport.messages = page(wire("m1", 100L), wire("m2", 200L, content = "while away"))
        bus.state(ChatStreamState.Live)
        s.drain()

        assertTrue(
            "a reconnect must repair the gap with a refetch",
            transport.requestedPaths.size > afterFirstLoad,
        )
        assertEquals(
            listOf("hello", "while away"),
            model.uiState.value.messages.map { it.content },
        )
    }

    @Test
    fun `a live row is not rolled back by a rest response that started earlier`() = cacheTest { s ->
        val transport = FakeTransport(messages = page())
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport, bus)
        model.openSession("sess_1")

        // The tool's completed row arrives live while the fetch is in flight, and the in-flight response still carries its placeholder content.
        val live = ChatMessage(
            id = "tool_1",
            role = ChatMessage.ROLE_TOOL,
            content = "the real result",
            createdAtEpochMillis = nanoBase / 1_000_000L + 400L,
            sortKeyNanos = nanoBase + 400L,
        )
        bus.emit(ChatStreamEvent.Full("sess_1", live))
        transport.messages = page(
            """{"id":"tool_1","session_id":"sess_1","role":"tool","content":"running…","created_at":"${nanoBase + 400L}"}""",
        )
        s.drain()

        // Writing the stale REST row back would turn a finished tool result into a spinner.
        assertEquals("the real result", model.uiState.value.messages.single().content)
    }

    @Test
    fun `an event for another chat is ignored`() = cacheTest { s ->
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, bus = bus)
        model.openSession("sess_1")
        s.drain()

        bus.emit(
            ChatStreamEvent.Chunk("sess_other", 0, content = "not for you"),
        )
        bus.emit(
            ChatStreamEvent.Full(
                "sess_other",
                ChatMessage("x", ChatMessage.ROLE_ASSISTANT, "not for you", 0L, nanoBase),
            ),
        )

        assertTrue(model.uiState.value.messages.isEmpty())
    }

    // --- Sending -----------------------------------------------------------

    @Test
    fun `sending does not insert an optimistic bubble`() = cacheTest { s ->
        val transport = FakeTransport(messages = page())
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport, bus)
        model.openSession("sess_1")
        s.drain()

        model.onDraftChanged("do the thing")
        model.sendMessage()
        s.drain()

        // The web removed its optimistic push deliberately: it lands at the wrong end of the array and re-keys the grouped list.
        assertTrue(model.uiState.value.messages.isEmpty())
        assertTrue(
            "the turn was queued",
            transport.requestedPaths.any { it.startsWith("POST /api/llm/session") },
        )
        assertEquals("", model.uiState.value.draft)
        assertFalse(model.uiState.value.isSending)
    }

    @Test
    fun `a failed send keeps the draft so a retry is one tap`() = cacheTest { s ->
        val model = model(s.ioDispatcher, InMemoryChatCache(), FakeTransport(sendStatus = 400))
        model.openSession("sess_1")
        s.drain()

        model.onDraftChanged("do the thing")
        model.sendMessage()
        s.drain()

        assertEquals("do the thing", model.uiState.value.draft)
        assertTrue(model.uiState.value.errorMessage != null)
        assertFalse(model.uiState.value.isSending)
    }

    @Test
    fun `a send to a chat that is not open does nothing`() = cacheTest { s ->
        val transport = FakeTransport()
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport)
        model.onDraftChanged("stray")

        model.sendMessage()
        s.drain()

        assertTrue(transport.requestedPaths.none { it.startsWith("POST") })
    }

    @Test
    fun `a run already in progress when the chat is opened is re attached`() = cacheTest { s ->
        // The backend writes `llm_history` only when a turn completes, so a cold open mid-run otherwise stops one message short of the live answer.
        val model = model(
            s.ioDispatcher,
            InMemoryChatCache(),
            FakeTransport(
                messages = page(wire("m1", 100L)),
                streamSnapshot = """{"active":true,"content":"half an ans"}""",
            ),
        )

        model.openSession("sess_1")
        s.drain()

        val streaming = model.uiState.value.messages.last()
        assertEquals("half an ans", streaming.content)
        assertTrue(streaming.isStreaming)
        assertTrue(model.uiState.value.isStreaming)
    }

    @Test
    fun `an idle server contributes no placeholder`() = cacheTest { s ->
        val model = model(
            s.ioDispatcher,
            InMemoryChatCache(),
            FakeTransport(
                messages = page(wire("m1", 100L)),
                streamSnapshot = """{"active":false,"content":""}""",
            ),
        )

        model.openSession("sess_1")
        s.drain()

        assertEquals(1, model.uiState.value.messages.size)
        assertTrue(model.uiState.value.messages.none { it.isStreaming })
    }

    @Test
    fun `the re attached text never overwrites a stream that is already live`() = cacheTest { s ->
        val bus = FakeSseBus()
        val model = model(
            s.ioDispatcher,
            InMemoryChatCache(),
            FakeTransport(
                messages = page(wire("m1", 100L)),
                streamSnapshot = """{"active":true,"content":"stale snapshot"}""",
            ),
            bus,
        )
        model.openSession("sess_1")
        // The live stream wins the race, as it should.
        bus.emit(ChatStreamEvent.Chunk("sess_1", 0, content = "the live one"))
        s.drain()

        assertEquals("the live one", model.uiState.value.messages.last().content)
    }

    // --- Paging backwards --------------------------------------------------

    @Test
    fun `scrolling to the top prepends the previous page without duplicates`() = cacheTest { s ->
        val transport = FakeTransport(
            messages = page(
                wire("m5", 500L),
                wire("m6", 600L),
                hasMore = true,
                nextCursor = "500",
            ),
        )
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport)
        model.openSession("sess_1")
        s.drain()
        assertTrue(model.uiState.value.hasMoreOlder)

        transport.messages = page(
            wire("m5", 500L),
            wire("m4", 400L, content = "older"),
            wire("m3", 300L, content = "oldest"),
        )
        model.loadOlderMessages()
        s.drain()

        // Ascending transcript order, and the overlap row is not duplicated.
        assertEquals(
            listOf("oldest", "older", "hello", "hello"),
            model.uiState.value.messages.map { it.content },
        )
        assertEquals(4, model.uiState.value.messages.map { it.id }.toSet().size)
    }

    @Test
    fun `paging is not retried once the server says there is no more`() = cacheTest { s ->
        val transport = FakeTransport(messages = page(wire("m1", 100L)))
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport)
        model.openSession("sess_1")
        s.drain()

        assertFalse("no has_more means no scroll-to-top arming", model.uiState.value.hasMoreOlder)

        val before = transport.requestedPaths.size
        model.loadOlderMessages()
        s.drain()

        assertEquals(before, transport.requestedPaths.size)
    }

    @Test
    fun `stopping a run clears the header's claim that it is still working`() = cacheTest { s ->
        val bus = FakeSseBus()
        val model = model(s.ioDispatcher, InMemoryChatCache(), FakeTransport(), bus)
        model.openSession("sess_1")
        s.drain()

        bus.emit(ChatStreamEvent.Chunk("sess_1", 0, content = "half an answer"))
        s.drain()
        assertTrue("the header reads Working... mid-run", model.uiState.value.isStreaming)

        // A stop interrupts the turn, so the turn never finishes and the frames
        // that would normally clear the flag never come.
        model.stopRun()
        s.drain()

        assertFalse(
            "the app bar must not keep saying Working... after the reader stopped it",
            model.uiState.value.isStreaming,
        )
        assertTrue(
            "the placeholder must stop spinning too",
            model.uiState.value.messages.none { it.isStreaming },
        )
    }

    @Test
    fun `reopening a cached chat still pages backwards`() = cacheTest { s ->
        val transport = FakeTransport(
            messages = page(
                wire("m5", 500L),
                wire("m6", 600L),
                hasMore = true,
                nextCursor = (nanoBase + 500L).toString(),
            ),
        )
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport)

        model.openSession("sess_1")
        s.drain()
        assertTrue("a cold open arms scroll-back", model.uiState.value.hasMoreOlder)

        // Leave the chat and come back. The cache now holds a tail cursor, which
        // is what makes the second open a *warm* one -- and the case every
        // returning user hits, because the cursor is written on the very first
        // open.
        model.openSession("sess_2")
        s.drain()
        transport.messages = page(wire("m5", 500L), wire("m6", 600L))
        model.openSession("sess_1")
        s.drain()

        assertTrue(
            "a warm open must not switch scroll-back off for good",
            model.uiState.value.hasMoreOlder,
        )
    }

    @Test
    fun `a warm open pages from the boundary the cache remembers`() = cacheTest { s ->
        val transport = FakeTransport(
            messages = page(
                wire("m5", 500L),
                wire("m6", 600L),
                hasMore = true,
                nextCursor = (nanoBase + 500L).toString(),
            ),
        )
        val model = model(s.ioDispatcher, InMemoryChatCache(), transport)
        model.openSession("sess_1")
        s.drain()

        // One page back, so the boundary the app has to ask with is not just
        // the first page's: a stale cursor from an earlier open would skip or
        // repeat rows.
        transport.messages = page(
            wire("m5", 500L),
            wire("m4", 400L, content = "older"),
            hasMore = true,
            nextCursor = (nanoBase + 400L).toString(),
        )
        model.loadOlderMessages()
        s.drain()

        model.openSession("sess_2")
        s.drain()
        transport.messages = page(wire("m5", 500L), wire("m6", 600L))
        model.openSession("sess_1")
        s.drain()
        transport.requestedPaths.clear()

        transport.messages = page(
            wire("m3", 300L, content = "oldest"),
            wire("m4", 400L, content = "older"),
        )
        model.loadOlderMessages()
        s.drain()

        assertTrue(
            "the page must be requested descending from the remembered boundary",
            transport.requestedPaths.messagesRequest()
                .contains("direction=desc&cursor=${nanoBase + 400L}"),
        )
        assertEquals(
            listOf("oldest", "older", "hello", "hello"),
            model.uiState.value.messages.map { it.content },
        )
    }
}
