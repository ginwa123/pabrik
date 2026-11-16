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
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Images on a turn, at the ViewModel level. */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelAttachmentTest {

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
    }

    private fun attachmentTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
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

    private class FakeTransport(
        var sendStatus: Int = 201,
        var offline: Boolean = false,
    ) : AuthTransport {
        val sentBodies = mutableListOf<String>()

        override fun post(path: String, body: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            sentBodies += body
            return AuthHttpResponse(statusCode = sendStatus, body = """{"status":"send"}""")
        }

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse =
            AuthHttpResponse(
                statusCode = 200,
                body = """{"messages":[],"has_more":false,"next_cursor":null,"total":0}""",
            )
    }


    /** A reader that answers from a table, so a test can name the exact attachment a pick produces — including one that is too big, and one that cannot be read at all. */
    private class TableImageReader(
        private val bySource: Map<String, ChatAttachment?>,
    ) : PickedImageReader {
        val read = mutableListOf<String>()
        override suspend fun read(source: String): ChatAttachment? {
            read += source
            return bySource[source]
        }
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        transport: FakeTransport = FakeTransport(),
        reader: PickedImageReader = TableImageReader(emptyMap()),
    ) = ChatViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        cache = InMemoryChatCache(),
        bus = FakeSseBus(),
        imageReader = reader,
        ioDispatcher = ioDispatcher,
    ).also { it.onUserChanged("user_a") }

    private fun attachment(id: String, byteCount: Int = 1_000) = ChatAttachment(
        id = id,
        mimeType = ChatAttachments.STORED_MIME,
        byteCount = byteCount,
        dataUrl = ChatAttachments.dataUrl(ChatAttachments.STORED_MIME, ByteArray(byteCount) { 1 }),
    )

    private fun readerOf(vararg pairs: Pair<String, ChatAttachment?>) =
        TableImageReader(pairs.toMap())

    private fun opened(
        s: Schedulers,
        transport: FakeTransport = FakeTransport(),
        reader: PickedImageReader = readerOf(),
    ): Pair<ChatViewModel, FakeTransport> {
        val model = model(s.ioDispatcher, transport, reader)
        model.openSession("sess_1")
        s.drain()
        assertEquals("sess_1", model.uiState.value.sessionId)
        return model to transport
    }

    // --- Attaching ---------------------------------------------------------

    @Test
    fun `a picked image joins the turn being composed`() = attachmentTest { s ->
        val image = attachment("a1")
        val (model, _) = opened(s, reader = readerOf("content://one" to image))

        model.attachImage("content://one")
        s.drain()

        assertEquals(listOf(image), model.uiState.value.pendingAttachments)
        assertFalse("the spinner must clear", model.uiState.value.isAttaching)
        assertEquals(null, model.uiState.value.errorMessage)
    }

    @Test
    fun thePaperclipGoesQuietTheMomentAPickIsTapped() = attachmentTest { s ->
        // Synchronously, before anything is drained.
        val (model, _) = opened(s, reader = readerOf("content://one" to attachment("a1")))

        model.attachImage("content://one")

        assertTrue(
            "isAttaching must be true before the decode starts",
            model.uiState.value.isAttaching,
        )
        s.drain()
        assertFalse(model.uiState.value.isAttaching)
        assertEquals(1, model.uiState.value.pendingAttachments.size)
    }

    @Test
    fun aSecondPickIsIgnoredWhileTheFirstIsStillDecoding() = attachmentTest { s ->
        // The guard, from the reader's side.
        val reader = readerOf("content://a" to attachment("a"), "content://b" to attachment("b"))
        val (model, _) = opened(s, reader = reader)

        model.attachImage("content://a")
        model.attachImage("content://b")
        s.drain()

        assertEquals(listOf("content://a"), reader.read)
        assertEquals(listOf("a"), model.uiState.value.pendingAttachments.map { it.id })
    }

    @Test
    fun `an image that cannot be read says so instead of vanishing`() = attachmentTest { s ->
        val (model, _) = opened(s, reader = readerOf("content://gone" to null))

        model.attachImage("content://gone")
        s.drain()

        assertTrue(model.uiState.value.pendingAttachments.isEmpty())
        assertNotNull("a silent drop is the worst outcome", model.uiState.value.errorMessage)
        assertFalse(model.uiState.value.isAttaching)
    }

    @Test
    fun `an image over the turn's budget is refused and the turn is untouched`() = attachmentTest { s ->
        val big = attachment("big", ChatAttachments.MAX_TOTAL_BYTES)
        val small = attachment("small", 500)
        val (model, transport) = opened(
            s,
            reader = readerOf("content://small" to small, "content://big" to big),
        )

        model.attachImage("content://small")
        s.drain()
        model.attachImage("content://big")
        s.drain()

        // The first image survives: a refusal is about the *new* one, and
        // dropping the whole turn would make the reader re-pick both.
        assertEquals(listOf("small"), model.uiState.value.pendingAttachments.map { it.id })
        assertNotNull(model.uiState.value.errorMessage)
        // And nothing was sent — the cap is a client-side check, not a round
        // trip that discovers it the hard way.
        assertTrue(transport.sentBodies.isEmpty())
    }

    @Test
    fun `the same photo twice is one attachment`() = attachmentTest { s ->
        val image = attachment("a1")
        val (model, _) = opened(s, reader = readerOf("content://one" to image))

        model.attachImage("content://one")
        s.drain()
        model.attachImage("content://one")
        s.drain()

        assertEquals(1, model.uiState.value.pendingAttachments.size)
    }

    @Test
    fun `removing one image leaves the rest of the turn alone`() = attachmentTest { s ->
        val (model, _) = opened(
            s,
            reader = readerOf(
                "content://a" to attachment("a"),
                "content://b" to attachment("b"),
            ),
        )
        model.onDraftChanged("look at this")
        model.attachImage("content://a")
        s.drain()
        model.attachImage("content://b")
        s.drain()

        model.removeAttachment("a")

        assertEquals(listOf("b"), model.uiState.value.pendingAttachments.map { it.id })
        assertEquals("look at this", model.uiState.value.draft)
    }

    // --- Sending them ------------------------------------------------------

    @Test
    fun `a send carries the images as image_urls`() = attachmentTest { s ->
        val first = attachment("a1", 12)
        val second = attachment("a2", 34)
        val (model, transport) = opened(
            s,
            reader = readerOf("content://a" to first, "content://b" to second),
        )
        model.attachImage("content://a")
        s.drain()
        model.attachImage("content://b")
        s.drain()

        model.onDraftChanged("what is wrong here")
        model.sendMessage()
        s.drain()

        val body = JSONObject(transport.sentBodies.single())
        assertEquals("what is wrong here", body.getString("queue_message"))
        // Pipe-delimited, and the separator is the backend's — a JSON array
        // here is stored verbatim and split into one image with a `|` in it.
        assertEquals(
            "${first.dataUrl}|${second.dataUrl}",
            body.getString("image_urls"),
        )
    }

    @Test
    fun `an image with no text is still a turn`() = attachmentTest { s ->
        // The reader who attached a screenshot and wrote nothing is asking a question the picture answers.
        val (model, transport) = opened(s, reader = readerOf("content://a" to attachment("a")))

        model.attachImage("content://a")
        s.drain()
        model.sendMessage()
        s.drain()

        assertEquals(1, transport.sentBodies.size)
        assertEquals("", JSONObject(transport.sentBodies.single()).getString("queue_message"))
    }

    @Test
    fun `an empty turn with nothing attached still does nothing`() = attachmentTest { s ->
        val (model, transport) = opened(s)

        model.sendMessage()
        s.drain()

        assertTrue(transport.sentBodies.isEmpty())
    }

    @Test
    fun `a send with no images leaves image_urls empty`() = attachmentTest { s ->
        // A trailing or lone `|` would make the transcript render an attachment that is not there.
        val (model, transport) = opened(s)

        model.onDraftChanged("plain text")
        model.sendMessage()
        s.drain()

        assertEquals("", JSONObject(transport.sentBodies.single()).getString("image_urls"))
    }

    @Test
    fun `a successful send clears the draft and the images together`() = attachmentTest { s ->
        val (model, transport) = opened(s, reader = readerOf("content://a" to attachment("a")))
        model.attachImage("content://a")
        s.drain()
        model.onDraftChanged("see this")
        model.sendMessage()
        s.drain()

        val state = model.uiState.value
        assertEquals("", state.draft)
        assertTrue(state.pendingAttachments.isEmpty())
        assertFalse(state.isSending)
        assertEquals(null, state.errorMessage)
    }

    @Test
    fun `a failed send keeps the images, so a retry is one tap`() = attachmentTest { s ->
        // The images are megabytes the reader spent a minute choosing.
        val image = attachment("a")
        val (model, transport) = opened(
            s,
            transport = FakeTransport(offline = true),
            reader = readerOf("content://a" to image),
        )
        model.attachImage("content://a")
        s.drain()
        model.onDraftChanged("see this")

        model.sendMessage()
        s.drain()

        val state = model.uiState.value
        assertEquals("see this", state.draft)
        assertEquals(listOf(image), state.pendingAttachments)
        assertNotNull(state.errorMessage)
    }

    @Test
    fun `a send rejected by the server keeps the images`() = attachmentTest { s ->
        val (model, _) = opened(
            s,
            transport = FakeTransport(sendStatus = 400),
            reader = readerOf("content://a" to attachment("a")),
        )
        model.attachImage("content://a")
        s.drain()
        model.sendMessage()
        s.drain()

        assertEquals(1, model.uiState.value.pendingAttachments.size)
    }
}
