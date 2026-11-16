package com.pabrik.mobile.chat

import com.pabrik.mobile.testing.FakeChatEventStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The root bus: one socket, many subscribers, and the lifecycle rules that keep it to one. */
class SseBusTest {

    /** Records what one subscriber saw, so a test can compare two of them. */
    private class Recorder {
        val events = mutableListOf<ChatStreamEvent>()
        val states = mutableListOf<ChatStreamState>()

        fun onEvent(event: ChatStreamEvent) {
            events += event
        }

        fun onState(state: ChatStreamState) {
            states += state
        }
    }

    @Test
    fun `the channel set is the whole app and carries no per-session key`() {
        // Bare `llm` / `queue` are what make one socket enough: the server fans out every session's traffic and each subscriber filters by `event.session_id`.
        assertEquals(
            "/api/events?channels=llm,queue,sessions,workers",
            SseChannels.eventsPath(),
        )
    }

    @Test
    fun `one event reaches every subscriber`() {
        val stream = FakeChatEventStream()
        val bus = RootSseBus(stream)
        val chat = Recorder()
        val sidebar = Recorder()

        bus.subscribe(chat::onEvent, chat::onState)
        bus.subscribe(sidebar::onEvent, sidebar::onState)
        bus.open()

        stream.emit(ChatStreamEvent.Chunk(sessionId = "sess_1", index = 0, content = "hi"))

        // The chat takes it; the sidebar sees it too and discards it, which is exactly the bargain — one socket, two independent readings.
        assertEquals(1, chat.events.size)
        assertEquals(1, sidebar.events.size)
    }

    @Test
    fun `an unsubscribed listener stops receiving`() {
        val stream = FakeChatEventStream()
        val bus = RootSseBus(stream)
        val chat = Recorder()
        val sidebar = Recorder()

        val off = bus.subscribe(chat::onEvent, chat::onState)
        bus.subscribe(sidebar::onEvent, sidebar::onState)
        bus.open()
        off()

        stream.emit(ChatStreamEvent.Chunk(sessionId = "sess_1", index = 0, content = "hi"))

        assertTrue(chat.events.isEmpty())
        assertEquals(1, sidebar.events.size)
    }

    @Test
    fun `a listener that throws does not cost the others the event`() {
        val stream = FakeChatEventStream()
        val bus = RootSseBus(stream)
        val survivor = Recorder()
        var threw = 0

        bus.subscribe({ _ -> threw++ }, { })
        bus.subscribe(survivor::onEvent, survivor::onState)
        bus.open()

        stream.emit(ChatStreamEvent.Chunk(sessionId = "sess_1", index = 0, content = "hi"))

        // A crash in one ViewModel's handler must not silently stop the other's spinner from turning off.
        assertEquals(1, threw)
        assertEquals(1, survivor.events.size)
    }

    @Test
    fun `a listener that detaches itself mid-fan-out does not break the loop`() {
        val stream = FakeChatEventStream()
        val bus = RootSseBus(stream)
        val later = Recorder()

        lateinit var off: () -> Unit
        off = bus.subscribe(
            onEvent = { off(); throw IllegalStateException("boom") },
            onState = { },
        )
        bus.subscribe(later::onEvent, later::onState)
        bus.open()

        // The subscriber list is live while it is being walked, which is the one place a naive implementation drops the rest of the fan-out.
        stream.emit(ChatStreamEvent.Chunk(sessionId = "sess_1", index = 0, content = "hi"))

        assertEquals(1, later.events.size)
    }

    @Test
    fun `a new subscriber is handed the current state immediately`() {
        val stream = FakeChatEventStream()
        val bus = RootSseBus(stream)
        bus.open()
        stream.state(ChatStreamState.Live)

        val late = Recorder()
        bus.subscribe(late::onEvent, late::onState)

        // A chat opened onto an already-live socket must know it is connected.
        assertEquals(listOf(ChatStreamState.Live), late.states)
        assertEquals(ChatStreamState.Live, bus.state.value)
    }

    @Test
    fun `subscribing does not open the socket`() {
        val stream = FakeChatEventStream()
        val bus = RootSseBus(stream)
        val chat = Recorder()
        bus.subscribe(chat::onEvent, chat::onState)

        // Registering is free; connecting is not.
        assertEquals(0, stream.startCount)

        bus.open()
        assertEquals(1, stream.startCount)
    }

    @Test
    fun `state transitions reach every subscriber`() {
        val stream = FakeChatEventStream()
        val bus = RootSseBus(stream)
        val chat = Recorder()
        val sidebar = Recorder()
        bus.subscribe(chat::onEvent, chat::onState)
        bus.subscribe(sidebar::onEvent, sidebar::onState)

        bus.open()
        stream.state(ChatStreamState.Reconnecting)
        stream.state(ChatStreamState.Live)

        assertEquals(
            listOf(
                ChatStreamState.Connecting,
                ChatStreamState.Reconnecting,
                ChatStreamState.Live,
            ),
            chat.states,
        )
        assertEquals(chat.states, sidebar.states)
    }

    @Test
    fun `close leaves no green dot behind`() {
        val stream = FakeChatEventStream()
        val bus = RootSseBus(stream)
        val chat = Recorder()
        bus.subscribe(chat::onEvent, chat::onState)
        bus.open()
        stream.state(ChatStreamState.Live)

        bus.close()

        // Not `Live` and not `Reconnecting`: the honest value for "there is no socket", so a chat header cannot keep a live status through a sign-out.
        assertEquals(ChatStreamState.Connecting, bus.state.value)
    }

    @Test
    fun `closing keeps the subscribers for the next sign-in`() {
        val stream = FakeChatEventStream()
        val bus = RootSseBus(stream)
        val chat = Recorder()
        bus.subscribe(chat::onEvent, chat::onState)
        bus.open()

        bus.close()
        bus.open()
        stream.emit(ChatStreamEvent.Chunk(sessionId = "sess_1", index = 0, content = "hi"))

        // A ViewModel outlives a sign-out, so tearing the socket down must not tear the registration down with it.
        assertEquals(1, chat.events.size)
    }

    @Test
    fun `open and close are idempotent`() {
        val stream = FakeChatEventStream()
        val bus = RootSseBus(stream)

        bus.open()
        bus.open()
        bus.open()
        bus.close()
        bus.close()

        assertEquals(1, stream.startCount)
        assertEquals(1, stream.stopCount)
    }
}
