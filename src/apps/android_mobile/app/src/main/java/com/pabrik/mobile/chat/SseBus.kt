package com.pabrik.mobile.chat

import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.SessionStore
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The ONE channel string the whole app listens on. */
object SseChannels {
    fun eventsPath(): String = "/api/events?channels=llm,queue,sessions,workers"
}

/** The app's single server-sent-events connection. */
interface SseBus {
    /** The connection's state, as a flow. */
    val state: StateFlow<ChatStreamState>

    /** Registers a listener and returns its unsubscribe. */
    fun subscribe(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ): () -> Unit

    /** Opens the socket. Idempotent, and gated on there being an account. */
    fun open()

    /** Closes the socket. Idempotent. Subscribers stay registered. */
    fun close()
}

/** The production bus: one [ChatEventStream], fanned out to every subscriber. */
class RootSseBus(
    private val stream: ChatEventStream,
) : SseBus {

    constructor(sessionStore: SessionStore) : this(
        HttpChatEventStream(sessionStore = sessionStore, path = SseChannels.eventsPath()),
    )

    private val subscribers = CopyOnWriteArrayList<Subscriber>()
    private val _state = MutableStateFlow<ChatStreamState>(ChatStreamState.Connecting)

    @Volatile
    private var open = false

    override val state: StateFlow<ChatStreamState> = _state.asStateFlow()

    override fun subscribe(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ): () -> Unit {
        val subscriber = Subscriber(onEvent, onState)
        subscribers.add(subscriber)
        // Seeded outside the lock, and best-effort: a listener that throws on the seed must still be registered, or the subscriber is invisible.
        runCatching { onState(_state.value) }
        return { subscribers.remove(subscriber) }
    }

    override fun open() {
        // The handshake is a cookie the server answers once and never retries, and the pump treats a non-2xx as terminal.
        if (open) return
        open = true
        stream.start(
            onEvent = { event -> dispatchEvent(event) },
            // Both halves are load-bearing.
            onState = { next -> dispatchState(next) },
        )
    }

    override fun close() {
        if (!open) return
        open = false
        stream.stop()
        // Not `Live` and not `Reconnecting`: the honest value for "there is no socket", so a header showing a green dot is never left behind by a sign-out.
        dispatchState(ChatStreamState.Connecting)
    }

    /** Whether the socket is up. Exposed for the bus's own tests, not for callers. */
    internal val isOpen: Boolean get() = open

    private fun dispatchEvent(event: ChatStreamEvent) {
        // A CopyOnWriteArrayList is safe to iterate while a listener detaches itself below, so no snapshot copy is needed.
        for (subscriber in subscribers) {
            runCatching { subscriber.onEvent(event) }
        }
    }

    private fun dispatchState(next: ChatStreamState) {
        _state.value = next
        for (subscriber in subscribers) {
            runCatching { subscriber.onState(next) }
        }
    }

    private class Subscriber(
        val onEvent: (ChatStreamEvent) -> Unit,
        val onState: (ChatStreamState) -> Unit,
    )
}

/** The production bus, built once for the process. */
object SseBusHolder {
    private var instance: SseBus? = null

    fun get(sessionStore: SessionStore): SseBus =
        instance ?: RootSseBus(sessionStore).also { instance = it }

    /** Drops the singleton so a JVM test can install its own. */
    internal fun reset() {
        instance = null
    }
}
