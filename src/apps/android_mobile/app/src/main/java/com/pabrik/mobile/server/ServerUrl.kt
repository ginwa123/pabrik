package com.pabrik.mobile.server

import com.pabrik.mobile.BuildConfig
import java.net.URI
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The result of being told which server to talk to. */
sealed interface ServerChange {
    /** [baseUrl] is normalized, and is what the app will use from now on. */
    data class Applied(val baseUrl: String) : ServerChange

    /** [reason] is a sentence to show a person, not a code to log. */
    data class Rejected(val reason: String) : ServerChange
}

/** The hosts a build may open a **plain HTTP** socket to, and the only ones. */
internal val LOOPBACK_HOSTS: Set<String> = setOf("10.0.2.2", "localhost", "127.0.0.1")

/** "Does this already say what it is talking to?" — RFC 3986's scheme grammar. */
private val SCHEME_PATTERN = Regex("^[a-zA-Z][a-zA-Z0-9+.\\-]*://")

internal val CLEAR_TEXT_HOSTS: Set<String> =
    if (BuildConfig.ALLOW_INSECURE_HTTP) LOOPBACK_HOSTS else emptySet()

// `10.0.2.2` is the emulator's own alias for the host's loopback interface, which is the address a `127.0.0.1`-bound server is reachable on from inside the …
internal fun normalizeBaseUrl(raw: String): ServerChange {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) {
        return ServerChange.Rejected("Enter your server address.")
    }

    // A bare `example.com` is the common case; only reach for a parser once there is a scheme to parse.
    val candidate = if (SCHEME_PATTERN.containsMatchIn(trimmed)) trimmed else "https://$trimmed"

    val uri = try {
        URI(candidate)
    } catch (_: Exception) {
        return ServerChange.Rejected("That is not a server address.")
    }

    val scheme = uri.scheme?.lowercase()
    if (scheme != "http" && scheme != "https") {
        // These two strings are the transport's own rule, quoted here so the sentence under the field and the exception out of `HttpsAuthTransport` are the same one.
        return ServerChange.Rejected(
            if (BuildConfig.ALLOW_INSECURE_HTTP) {
                "Pabrik API must use HTTP or HTTPS."
            } else {
                "Pabrik API must use HTTPS."
            },
        )
    }

    // `java.net.URI` refuses a host it cannot parse (an underscore, a stray space) by reporting a null host rather than by failing, so this reads as the generic "no …
    val host = uri.host?.lowercase()
        ?: return ServerChange.Rejected("Include the domain, for example pabrik.example.com.")

    // Credentials in a URL are a phishing shape: the reader sees the host and not the `user:pass@` in front of it, and a server the app is pointed at by a string …
    if (!uri.userInfo.isNullOrEmpty()) {
        return ServerChange.Rejected("Remove the username and password from the address.")
    }
    if (!uri.query.isNullOrEmpty() || !uri.fragment.isNullOrEmpty()) {
        return ServerChange.Rejected("A server address cannot have a ?query or #fragment.")
    }

    if (scheme == "http" && host !in CLEAR_TEXT_HOSTS) {
        return ServerChange.Rejected(
            if (CLEAR_TEXT_HOSTS.isEmpty()) {
                "This build connects over HTTPS only."
            } else {
                "Plain HTTP is only allowed for a server on this device's host (${CLEAR_TEXT_HOSTS.joinToString()})."
            },
        )
    }

    val port = if (uri.port != -1) ":${uri.port}" else ""
    val path = (uri.rawPath ?: "").trimEnd('/')
    return ServerChange.Applied("$scheme://$host$port$path")
}

/** The transport's half of the rule: a host, or an exception naming why not. */
internal fun requireUsableBaseUrl(baseUrl: String): String = when (
    val parsed = normalizeBaseUrl(baseUrl)
) {
    is ServerChange.Applied -> parsed.baseUrl
    is ServerChange.Rejected -> throw IllegalArgumentException(parsed.reason)
}

/** The server this process talks to. */
object ServerUrl {
    private val _current = MutableStateFlow(BuildConfig.API_BASE_URL)

    /** The base URL as a flow, for UI that has to redraw when it changes. */
    val current: StateFlow<String> = _current.asStateFlow()

    /** The base URL every transport reads right now. */
    val value: String get() = _current.value

    private var store: BaseUrlStore? = null

    /** Binds this holder to storage, adopting anything already saved. */
    fun install(store: BaseUrlStore) {
        this.store = store
        val stored = store.read() ?: return run {
            _current.value = BuildConfig.API_BASE_URL
        }
        when (val parsed = normalizeBaseUrl(stored)) {
            is ServerChange.Applied -> _current.value = parsed.baseUrl
            is ServerChange.Rejected -> {
                store.clear()
                _current.value = BuildConfig.API_BASE_URL
            }
        }
    }

    /** Adopts [raw] and persists it. */
    fun update(raw: String): ServerChange {
        val parsed = normalizeBaseUrl(raw)
        if (parsed is ServerChange.Rejected) return parsed

        val baseUrl = (parsed as ServerChange.Applied).baseUrl
        if (store?.write(baseUrl) == false) {
            return ServerChange.Rejected("This device could not save the server address.")
        }
        _current.value = baseUrl
        return parsed
    }

    /** Back to the host this build shipped with, and forgets the saved one. */
    fun resetToBuildDefault(): ServerChange {
        store?.clear()
        _current.value = BuildConfig.API_BASE_URL
        return ServerChange.Applied(_current.value)
    }

    /** Unbinds storage and returns to the build default. Tests only. */
    internal fun reset() {
        store = null
        _current.value = BuildConfig.API_BASE_URL
    }
}
