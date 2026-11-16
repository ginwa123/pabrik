package com.pabrik.mobile.testing

import com.pabrik.mobile.chat.ChatStreamEvent
import com.pabrik.mobile.chat.ChatStreamState
import com.pabrik.mobile.chat.SseBus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A bus-shaped stand-in for the app's one real socket. */
class FakeSseBus : SseBus {

    private class Subscriber(
        val onEvent: (ChatStreamEvent) -> Unit,
        val onState: (ChatStreamState) -> Unit,
    )

    private val subscribers = mutableListOf<Subscriber>()
    private val _state = MutableStateFlow<ChatStreamState>(ChatStreamState.Connecting)

    override val state: StateFlow<ChatStreamState> = _state.asStateFlow()

    var openCount = 0
        private set
    var closeCount = 0
        private set
    var isOpen = false
        private set

    val subscriberCount: Int get() = subscribers.size

    override fun subscribe(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ): () -> Unit {
        val subscriber = Subscriber(onEvent, onState)
        subscribers.add(subscriber)
        onState(_state.value)
        return { subscribers.remove(subscriber) }
    }

    override fun open() {
        openCount++
        isOpen = true
    }

    override fun close() {
        closeCount++
        isOpen = false
        state(ChatStreamState.Connecting)
    }

    /** Delivers one event to every listener, as the real fan-out does. */
    fun emit(event: ChatStreamEvent) {
        for (subscriber in subscribers.toList()) subscriber.onEvent(event)
    }

    /** Publishes a connection state to every listener. */
    fun state(next: ChatStreamState) {
        _state.value = next
        for (subscriber in subscribers.toList()) subscriber.onState(next)
    }
}
