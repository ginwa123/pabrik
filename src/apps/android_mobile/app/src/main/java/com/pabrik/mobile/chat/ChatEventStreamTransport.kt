package com.pabrik.mobile.chat

import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.server.requireUsableBaseUrl
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/** The chat's live connection to `GET /api/events`. */
interface ChatEventStream {
    fun start(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    )

    fun stop()
}

/** SSE over [HttpsURLConnection]. */
class HttpChatEventStream(
    private val sessionStore: SessionStore,
    private val baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    private val reconnectDelayMillis: Long = DEFAULT_RECONNECT_DELAY_MILLIS,
    /** Which `channels=` set to subscribe to. */
    private val path: String = SseChannels.eventsPath(),
) : ChatEventStream {
    private val lock = Any()

    private var worker: Thread? = null
    private var running = false
    private var token = 0
    private var openConnection: HttpURLConnection? = null

    override fun start(
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ) {
        val myToken: Int
        val thread: Thread
        synchronized(lock) {
            // Starting while one is already up is a caller bug, but silently keeping the old callbacks would be worse: the new chat would look connected while receiving …
            if (running) return
            running = true
            // Claimed here, not in the thread body.
            myToken = ++token
            thread = Thread({ pump(myToken, onEvent, onState) }, "pabrik-chat-sse")
            worker = thread
        }
        thread.isDaemon = true
        thread.start()
    }

    /** Tears the stream down, and returns without waiting for the socket. */
    override fun stop() {
        val toClose = synchronized(lock) {
            if (!running) return
            running = false
            // Invalidate the current pump before releasing the socket, so a thread that wakes from its read exits instead of reconnecting.
            token++
            worker = null
            openConnection.also { openConnection = null }
        }
        toClose?.let { connection ->
            Thread({ runCatching { connection.disconnect() } }, "pabrik-chat-sse-close")
                .apply { isDaemon = true }
                .start()
        }
    }

    private fun pump(
        myToken: Int,
        onEvent: (ChatStreamEvent) -> Unit,
        onState: (ChatStreamState) -> Unit,
    ) {
        val parser = SseFrameParser()
        var hasConnectedOnce = false

        try {
            while (isCurrent(myToken)) {
                onState(
                    if (hasConnectedOnce) ChatStreamState.Reconnecting else ChatStreamState.Connecting,
                )

                val connection = try {
                    open()
                } catch (_: Exception) {
                    sleepBackoff(myToken)
                    continue
                }

                var handshakeFailed = false
                try {
                    synchronized(lock) { if (token == myToken) openConnection = connection }

                    val statusCode = connection.responseCode
                    if (statusCode !in 200..299) {
                        // Do NOT loop: a rejected handshake retries forever and burns the radio.
                        onState(
                            ChatStreamState.Failed("The event stream is unavailable ($statusCode)."),
                        )
                        handshakeFailed = true
                        return
                    }

                    hasConnectedOnce = true
                    onState(ChatStreamState.Live)

                    BufferedReader(connection.inputStream.reader()).use { reader ->
                        var line = reader.readLine()
                        while (isCurrent(myToken) && line != null) {
                            parser.accept(line)?.let { frame -> dispatch(frame, onEvent) }
                            line = reader.readLine()
                        }
                    }
                } catch (_: Exception) {
                    // Offline, rotated, killed by the system.
                } finally {
                    // Only this pump's own connection, and only while it is still the current one.
                    val stillOurs = synchronized(lock) { openConnection === connection }
                    if (stillOurs) {
                        synchronized(lock) { openConnection = null }
                        runCatching { connection.disconnect() }
                    }
                    // A socket that died mid-frame would otherwise swallow a complete-looking payload.
                    parser.flush()?.let { frame -> dispatch(frame, onEvent) }
                }

                if (handshakeFailed || !isCurrent(myToken)) return
                sleepBackoff(myToken)
            }
        } finally {
            // Any exit path releases the slot, so a later start() is not silently refused for the rest of the process.
            synchronized(lock) {
                if (token == myToken) {
                    running = false
                    worker = null
                }
            }
        }
    }

    private fun dispatch(frame: SseFrame, onEvent: (ChatStreamEvent) -> Unit) {
        decodeChatFrame(frame)?.let(onEvent)
    }

    private fun isCurrent(myToken: Int): Boolean = synchronized(lock) {
        running && token == myToken
    }

    private fun sleepBackoff(myToken: Int) {
        if (!isCurrent(myToken)) return
        try {
            Thread.sleep(reconnectDelayMillis)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    /** Opens the request without reading a byte of the body. */
    private fun open(): HttpURLConnection {
        // Resolved here, at connect time, not captured at construction.
        val baseUrl = requireUsableBaseUrl(baseUrlProvider())
        val connection = URL(baseUrl + path).openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.connectTimeout = CONNECT_TIMEOUT_MILLIS
        // The stream is idle between turns, so a short read timeout would reconnect all evening.
        connection.readTimeout = READ_TIMEOUT_MILLIS
        connection.useCaches = false
        connection.setRequestProperty("Accept", "text/event-stream")
        connection.setRequestProperty("Cache-Control", "no-cache")
        // The session is the `pabrik_session` cookie and nothing else.
        sessionStore.read()?.let { cookie ->
            connection.setRequestProperty(
                "Cookie",
                "${AuthConfig.SESSION_COOKIE_NAME}=$cookie",
            )
        }
        return connection
    }

    private companion object {
        const val CONNECT_TIMEOUT_MILLIS = 15_000
        const val READ_TIMEOUT_MILLIS = 120_000
        const val DEFAULT_RECONNECT_DELAY_MILLIS = 2_000L
    }
}
