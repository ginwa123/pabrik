package com.pabrik.mobile.testing

import com.pabrik.mobile.chat.ChatEventStream
import com.pabrik.mobile.chat.ChatStreamEvent
import com.pabrik.mobile.chat.ChatStreamState

/** A transport-shaped double: the *socket*, not the bus. */
class FakeChatEventStream : ChatEventStream {
    var onEvent: ((ChatStreamEvent) -> Unit)? = null
    var onState: ((ChatStreamState) -> Unit)? = null
    var startCount = 0
        private set
    var stopCount = 0
        private set

    override fun start(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ) {
        startCount++
        this.onEvent = onEvent
        this.onState = onState
    }

    override fun stop() {
        stopCount++
    }

    /** What the real pump would do with a decoded frame. */
    fun emit(event: ChatStreamEvent) = onEvent?.invoke(event) ?: Unit

    /** What the real pump would do on a connection transition. */
    fun state(next: ChatStreamState) = onState?.invoke(next) ?: Unit
}
