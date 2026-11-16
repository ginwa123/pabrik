package com.pabrik.mobile.worker

import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.chat.ChatClient
import com.pabrik.mobile.chat.ChatStreamEvent
import com.pabrik.mobile.chat.ChatStreamState
import com.pabrik.mobile.testing.FakeSseBus
import java.io.IOException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.MutableSharedFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The two sources the spinner is built on, and the only repair for the gap between them: a `Live` transition means the server may have started or finished runs … */
@OptIn(ExperimentalCoroutinesApi::class)
class WorkerActivityViewModelTest {

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

    private class MemorySessionStore : SessionStore {
        private var value: String? = "session-cookie"
        override fun read(): String? = value
        override fun save(cookieValue: String) {
            value = cookieValue
        }

        override fun clear() {
            value = null
        }
    }

    private class FakeTransport(
        private val respond: () -> AuthHttpResponse,
    ) : AuthTransport {
        var workerRequests = 0
        var lastWorkerPath: String? = null

        override fun post(path: String, body: String, headers: Map<String, String>) =
            AuthHttpResponse(200, "{}")

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (path.startsWith("/api/workers")) {
                workerRequests++
                lastWorkerPath = path
            }
            return respond()
        }
    }

    private fun workerBody(vararg sessionIds: String): String {
        val rows = sessionIds.joinToString(",") { """{"id":"$it","session_id":"$it"}""" }
        return """{"workers":[$rows],"count":${sessionIds.size}}"""
    }

    private fun modelTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
        val schedulers = Schedulers()
        Dispatchers.setMain(schedulers.mainDispatcher)
        try {
            body(schedulers)
        } finally {
            Dispatchers.resetMain()
        }
    }

    /** `resyncTicks` defaults to `emptyFlow()` here on purpose. */
    private fun model(
        ioDispatcher: CoroutineDispatcher,
        store: RunningSessionsStore = RunningSessionsStore(),
        bus: FakeSseBus = FakeSseBus(),
        transport: AuthTransport = FakeTransport { AuthHttpResponse(200, workerBody()) },
        nowMillis: () -> Long = { 1_789_451_234_000L },
        resyncTicks: Flow<Unit> = emptyFlow(),
    ) = WorkerActivityViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        store = store,
        bus = bus,
        ioDispatcher = ioDispatcher,
        nowMillis = nowMillis,
        resyncTicks = resyncTicks,
    )

    @Test
    fun `the bus is listened to, but nothing is acted on, before sign-in`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1")) }
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, store, bus, transport)

        // The subscription is process-wide, so it exists from the first frame.
        assertEquals(1, bus.subscriberCount)

        bus.emit(
            ChatStreamEvent.WorkerChanged("task_ghost", ChatStreamEvent.WorkerChanged.ACTION_CREATED),
        )
        bus.state(ChatStreamState.Live)
        schedulers.drain()

        assertTrue(store.runningSessionIds.value.isEmpty())
        assertEquals(0, transport.workerRequests)
        assertTrue(model.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `the subscription is made once, whatever the account does`() = modelTest { schedulers ->
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, bus = bus)

        model.onUserChanged("user_1")
        model.onUserChanged("user_1")
        model.onUserChanged(null)
        model.onUserChanged("user_1")

        // The subscription lives in `init` and is a fact about the process, not about the account — so re-announcing the account must not stack a second one behind the …
        assertEquals(1, bus.subscriberCount)
    }

    @Test
    fun `going Live replaces the set with the server's list`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1", "task_2")) }
        val model = model(schedulers.ioDispatcher, store, bus, transport)
        model.onUserChanged("user_1")

        bus.state(ChatStreamState.Live)
        schedulers.drain()

        assertEquals(setOf("task_1", "task_2"), store.runningSessionIds.value)
        assertEquals(1, transport.workerRequests)
        assertEquals("/api/workers?limit=50", transport.lastWorkerPath)
    }

    @Test
    fun `a session that stopped while the socket was down stops spinning`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        var served = workerBody("task_1", "task_2")
        val transport = FakeTransport { AuthHttpResponse(200, served) }
        val model = model(schedulers.ioDispatcher, store, bus, transport)
        model.onUserChanged("user_1")

        bus.state(ChatStreamState.Live)
        schedulers.drain()
        assertEquals(setOf("task_1", "task_2"), store.runningSessionIds.value)

        // task_2 finishes while the socket is down, so no `worker_deleted` is
        // ever delivered. Only the resync can correct it.
        served = workerBody("task_1")
        var now = 1_789_451_234_000L
        val later = FakeSseBus()
        val second = model(
            ioDispatcher = schedulers.ioDispatcher,
            store = store,
            bus = later,
            transport = transport,
            nowMillis = { now },
        )
        second.onUserChanged("user_1")
        later.state(ChatStreamState.Live)
        schedulers.drain()

        assertEquals(setOf("task_1"), store.runningSessionIds.value)
    }

    @Test
    fun `a rapid reconnect does not re-fetch`() = modelTest { schedulers ->
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1")) }
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, bus = bus, transport = transport)
        model.onUserChanged("user_1")

        bus.state(ChatStreamState.Live)
        schedulers.drain()
        bus.state(ChatStreamState.Live)
        schedulers.drain()

        // The pump reaches Live on a two-second backoff, so a flapping
        // connection would otherwise turn every retry into a list request.
        assertEquals(1, transport.workerRequests)
    }

    @Test
    fun `a reconnect after the throttle window does re-fetch`() = modelTest { schedulers ->
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1")) }
        var now = 1_789_451_234_000L
        val bus = FakeSseBus()
        val model = model(
            ioDispatcher = schedulers.ioDispatcher,
            bus = bus,
            transport = transport,
            nowMillis = { now },
        )
        model.onUserChanged("user_1")

        bus.state(ChatStreamState.Live)
        schedulers.drain()
        now += WorkerActivityViewModel.RESYNC_THROTTLE_MILLIS
        bus.state(ChatStreamState.Live)
        schedulers.drain()

        assertEquals(2, transport.workerRequests)
    }

    @Test
    fun `a failed resync leaves the set alone`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        var fail = false
        val transport = FakeTransport {
            if (fail) AuthHttpResponse(503, "") else AuthHttpResponse(200, workerBody("task_1"))
        }
        val first = FakeSseBus()
        val model = model(schedulers.ioDispatcher, store, first, transport)
        model.onUserChanged("user_1")
        first.state(ChatStreamState.Live)
        schedulers.drain()
        assertEquals(setOf("task_1"), store.runningSessionIds.value)

        fail = true
        val second = FakeSseBus()
        val reopened = model(
            ioDispatcher = schedulers.ioDispatcher,
            store = store,
            bus = second,
            transport = transport,
            nowMillis = { 1L },
        )
        reopened.onUserChanged("user_1")
        second.state(ChatStreamState.Live)
        schedulers.drain()

        // Emptying the set would be the tempting repair and the wrong one: a
        // spinner that clears because the network blipped is the same lie as
        // one that never lights up.
        assertEquals(setOf("task_1"), store.runningSessionIds.value)
    }

    @Test
    fun `a worker_created event lights a session with no fetch`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        // Never goes Live, so no list request happens at all.
        val transport = FakeTransport { AuthHttpResponse(200, workerBody()) }
        val model = model(schedulers.ioDispatcher, store, bus, transport)
        model.onUserChanged("user_1")

        bus.emit(
            ChatStreamEvent.WorkerChanged("task_1", ChatStreamEvent.WorkerChanged.ACTION_CREATED),
        )
        schedulers.drain()

        assertTrue(store.isRunning("task_1"))
        assertEquals(0, transport.workerRequests)
    }

    @Test
    fun `a worker_deleted event clears a session`() = modelTest { schedulers ->
        val store = RunningSessionsStore().apply { replace(setOf("task_1")) }
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, store, bus)
        model.onUserChanged("user_1")

        bus.emit(
            ChatStreamEvent.WorkerChanged("task_1", ChatStreamEvent.WorkerChanged.ACTION_DELETED),
        )
        schedulers.drain()

        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `a non-worker bus event changes nothing`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, store, bus)
        model.onUserChanged("user_1")

        bus.emit(ChatStreamEvent.Connected)
        bus.emit(ChatStreamEvent.Chunk(sessionId = "task_1", index = 0, content = "hi"))
        schedulers.drain()

        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `a Reconnecting transition does not fetch`() = modelTest { schedulers ->
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1")) }
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, bus = bus, transport = transport)
        model.onUserChanged("user_1")

        bus.state(ChatStreamState.Connecting)
        bus.state(ChatStreamState.Reconnecting)
        bus.state(ChatStreamState.Failed("nope"))
        schedulers.drain()

        assertEquals(0, transport.workerRequests)
    }

    @Test
    fun `signing out drops the ids without touching the socket`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, store, bus)
        model.onUserChanged("user_1")
        store.replace(setOf("task_1"))

        model.onSignedOut()

        // Ids are not account-scoped and the cookie is gone, so nothing here is
        // any longer knowable, and nothing may show against the next account.
        assertTrue(store.runningSessionIds.value.isEmpty())
        // The socket is the ROOT's to close, not this ViewModel's. A stop here
        // would be the two-socket architecture coming back.
        assertEquals(0, bus.closeCount)
        assertEquals(0, bus.openCount)
    }

    @Test
    fun `signing out through the account hook does the same thing`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, store, bus)
        model.onUserChanged("user_1")
        store.replace(setOf("task_1"))

        model.onUserChanged(null)

        assertTrue(store.runningSessionIds.value.isEmpty())
        assertEquals(0, bus.closeCount)
    }

    @Test
    fun `worker events are inert between sign-out and the next sign-in`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, store, bus)

        model.onUserChanged("user_1")
        model.onSignedOut()

        bus.emit(
            ChatStreamEvent.WorkerChanged("task_ghost", ChatStreamEvent.WorkerChanged.ACTION_CREATED),
        )
        schedulers.drain()
        assertTrue(store.runningSessionIds.value.isEmpty())

        // Signing back in must light it up again, not just leave the gate shut.
        model.onUserChanged("user_1")
        bus.emit(
            ChatStreamEvent.WorkerChanged("task_1", ChatStreamEvent.WorkerChanged.ACTION_CREATED),
        )
        schedulers.drain()
        assertTrue(store.isRunning("task_1"))
    }

    @Test
    fun `an unreachable server is not a crash`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        val offline = object : AuthTransport {
            override fun post(path: String, body: String, headers: Map<String, String>) =
                throw IOException("offline")

            override fun get(path: String, headers: Map<String, String>) =
                throw IOException("offline")
        }
        val model = model(schedulers.ioDispatcher, store, bus, offline)
        model.onUserChanged("user_1")

        bus.state(ChatStreamState.Live)
        schedulers.drain()

        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `the periodic beat re-reads the list on a socket that never dropped`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        var served = workerBody("task_1")
        val transport = FakeTransport { AuthHttpResponse(200, served) }
        val ticks = MutableSharedFlow<Unit>(extraBufferCapacity = 4)
        var now = 1_789_451_234_000L
        // The socket never leaves Live, so nothing else in this class would
        // ever prompt a second fetch.
        val model = model(
            ioDispatcher = schedulers.ioDispatcher,
            store = store,
            bus = bus,
            transport = transport,
            nowMillis = { now },
            resyncTicks = ticks,
        )
        model.onUserChanged("user_1")

        bus.state(ChatStreamState.Live)
        schedulers.drain()
        assertEquals(setOf("task_1"), store.runningSessionIds.value)
        assertEquals(1, transport.workerRequests)

        // The run ends while the app is in the background: the server emits a
        // `worker_deleted` this process never dispatches, and the socket stays
        // up, so no reconnect ever comes to correct it.
        served = workerBody()
        now += WorkerActivityViewModel.RESYNC_INTERVAL_MILLIS
        ticks.emit(Unit)
        schedulers.drain()

        assertEquals(2, transport.workerRequests)
        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    @Test
    fun `no periodic beat means no extra requests`() = modelTest { schedulers ->
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1")) }
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, bus = bus, transport = transport)
        model.onUserChanged("user_1")

        bus.state(ChatStreamState.Live)
        schedulers.drain()
        // A slow user must not cost the server a request per second.
        repeat(10) { schedulers.drain() }

        assertEquals(1, transport.workerRequests)
    }

    @Test
    fun `coming back to the app re-reads the list without waiting out the throttle`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        var served = workerBody("task_1", "task_2")
        val transport = FakeTransport { AuthHttpResponse(200, served) }
        val model = model(schedulers.ioDispatcher, store, bus, transport)
        model.onUserChanged("user_1")

        bus.state(ChatStreamState.Live)
        schedulers.drain()
        assertEquals(1, transport.workerRequests)

        served = workerBody("task_1")
        // Inside the throttle window, which is exactly the situation: the socket
        // was open the whole time the app was away.
        model.onForeground()
        schedulers.drain()

        assertEquals(2, transport.workerRequests)
        assertEquals(setOf("task_1"), store.runningSessionIds.value)
    }

    @Test
    fun `coming back before sign-in does nothing`() = modelTest { schedulers ->
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1")) }
        val model = model(schedulers.ioDispatcher, transport = transport)

        model.onForeground()
        schedulers.drain()

        // The transport is a cookie, and the subscription is not open yet.
        assertEquals(0, transport.workerRequests)
    }

    @Test
    fun `a cleared ViewModel drops the ids the process-wide store was holding`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, store, bus)
        model.onUserChanged("user_1")
        // Cleared the way an Activity teardown clears it, without the route
        // change that would also have stopped the reconciliation beat.
        model.onSignedOut()
        store.replace(setOf("task_1"))
        clearViewModel(model)

        // `stopTracking()` short-circuits when nothing is tracked, and the store is a
        // singleton — so without the clear in `onCleared` the next Activity
        // republishes a set from one that no longer exists.
        assertTrue(store.runningSessionIds.value.isEmpty())
    }

    /**
     * `onCleared` is a `ViewModel` lifecycle hook and therefore protected, and
     * it is not worth widening to public purely so a test can reach it.
     */
    private fun clearViewModel(model: WorkerActivityViewModel) {
        WorkerActivityViewModel::class.java
            .getDeclaredMethod("onCleared")
            .apply { isAccessible = true }
            .invoke(model)
    }

    @Test
    fun `switching accounts drops the previous account's ids`() = modelTest { schedulers ->
        val store = RunningSessionsStore()
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, store, bus)
        model.onUserChanged("user_a")
        store.replace(setOf("task_a"))

        // No null in between: the auth state went straight from one account to the other.
        model.onUserChanged("user_b")

        assertTrue(store.runningSessionIds.value.isEmpty())
        // The socket survives the switch — the root re-opens it — so what must hold is that the SET is empty, not that a socket went away.
        assertEquals(0, bus.closeCount)
    }

    @Test
    fun `re-announcing an account does not cost a second resync`() = modelTest { schedulers ->
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1")) }
        val bus = FakeSseBus()
        val model = model(schedulers.ioDispatcher, bus = bus, transport = transport)

        model.onUserChanged("user_a")
        model.onUserChanged("user_a")
        bus.state(ChatStreamState.Live)
        schedulers.drain()

        // A duplicated beat would fetch twice per tick. There is one.
        assertEquals(1, bus.subscriberCount)
        assertEquals(1, transport.workerRequests)
    }

    @Test
    fun `signing out stops the periodic beat`() = modelTest { schedulers ->
        val transport = FakeTransport { AuthHttpResponse(200, workerBody("task_1")) }
        val bus = FakeSseBus()
        val ticks = MutableSharedFlow<Unit>(extraBufferCapacity = 4)
        var now = 1_789_451_234_000L
        val model = model(
            ioDispatcher = schedulers.ioDispatcher,
            bus = bus,
            transport = transport,
            nowMillis = { now },
            resyncTicks = ticks,
        )
        model.onUserChanged("user_1")
        bus.state(ChatStreamState.Live)
        schedulers.drain()
        assertEquals(1, transport.workerRequests)

        model.onSignedOut()
        schedulers.drain()

        now += WorkerActivityViewModel.RESYNC_INTERVAL_MILLIS
        ticks.emit(Unit)
        schedulers.drain()

        // A beat that outlived the cookie would keep hitting an endpoint the user no longer has a right to be asking about.
        assertEquals(1, transport.workerRequests)
        assertTrue(model.runningSessionIds.value.isEmpty())
    }
}
