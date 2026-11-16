package com.pabrik.mobile.server

import com.pabrik.mobile.BuildConfig
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The two cleartext lists have to be the same list. */
class ServerUrlContractTest {

    @Test
    fun `the store's cleartext hosts are exactly the ones the debug config grants`() {
        val xml = readOrFail(
            "src/debug/res/xml/network_security_config.xml",
            "app/src/debug/res/xml/network_security_config.xml",
        )
        val domains = Regex("<domain[^>]*>([^<]+)</domain>")
            .findAll(xml)
            .map { it.groupValues[1] }
            .toList()

        assertEquals(
            "ServerUrl.kt's LOOPBACK_HOSTS has drifted from the debug config's <domain> list",
            domains.toSet(),
            LOOPBACK_HOSTS,
        )
    }

    @Test
    fun `this variant's permitted cleartext hosts follow the build flag`() {
        // The two states the list can be in, and which one this variant is in.
        val expected = if (BuildConfig.ALLOW_INSECURE_HTTP) LOOPBACK_HOSTS else emptySet()

        assertEquals(expected, CLEAR_TEXT_HOSTS)
    }

    @Test
    fun `release keeps the cleartext allowance off and reads no user-set host`() {
        val release = block(buildScript(), "release")

        assertTrue(
            "the release build type must declare ALLOW_INSECURE_HTTP = false:\n$release",
            release.contains("ALLOW_INSECURE_HTTP\", \"false\""),
        )
        // The *interpolation*, not the identifier: the release block's own comment names the debug value in prose to explain why it is absent, and a check on the bare …
        assertTrue("release must wire the production url", release.contains("\$productionBaseUrl"))
        assertTrue("release must not wire the debug base url", !release.contains("\$debugBaseUrl"))
    }

    @Test
    fun `only the debug build type turns the allowance on`() {
        val script = buildScript()
        val occurrences = Regex(Regex.escape("ALLOW_INSECURE_HTTP\", \"true\""))
            .findAll(script)
            .count()

        assertEquals(
            "exactly one build type may enable plain HTTP; found $occurrences",
            1,
            occurrences,
        )
        assertTrue(
            "the allowance is enabled outside the debug block",
            block(script, "debug").contains("ALLOW_INSECURE_HTTP\", \"true\""),
        )
    }

    @Test
    fun `no release source set ships a cleartext allowance`() {
        // A network security config in `src/release` would lift the manifest's cleartext refusal in the one build that must never have it lifted, and the store's own set …
        for (relative in RELEASE_SOURCES) {
            assertTrue(
                "$relative must not exist — release stays HTTPS-only",
                File(relative).takeIf(File::isFile) == null,
            )
        }
    }

    @Test
    fun `the debug config still refuses cleartext by default`() {
        // The domain-config half of the pin.
        val xml = readOrFail(
            "src/debug/res/xml/network_security_config.xml",
            "app/src/debug/res/xml/network_security_config.xml",
        )

        assertTrue(
            "cleartext must stay refused by default:\n$xml",
            xml.contains("""<base-config cleartextTrafficPermitted="false""""),
        )
        assertTrue(
            "a domain-config must be the only thing that permits cleartext:\n$xml",
            xml.contains("""<domain-config cleartextTrafficPermitted="true">"""),
        )
    }

    @Test
    fun `no transport may take the host as a String`() {
        // A `String` base url — as a parameter or as a captured property — is a
        // host frozen at construction. The five production call sites all build
        // their transport during `MainActivity`'s first composition, so a frozen
        // one means "change the server" silently does nothing on whichever
        // client happened to freeze. Both spellings are the same mistake, and
        // `HttpsAuthTransport` has no `String` overload precisely so the
        // parameter form is a compile error rather than a silent regression.
        for (file in TRANSPORT_SOURCES) {
            // Comments stripped first, and that is not tidiness: these files'
            // own doc comments name the call site this check exists to forbid, so
            // a regex over raw source would report the warning as a violation
            // of the rule the warning is about.
            val source = withoutComments(
                readOrFail("src/main/java/com/pabrik/mobile/$file", file),
            )
            assertTrue(
                "$file must not take a bare String base url:\n${source.take(400)}",
                !Regex("""\bbaseUrl\s*:\s*String\b""").containsMatchIn(source),
            )
        }
    }

    @Test
    fun `no call site may hand a transport a host value`() {
        // The other spelling of the same freeze, and the one that would survive
        // the check above: `HttpsAuthTransport { AuthConfig.BASE_URL }` is right,
        // and `HttpsAuthTransport(AuthConfig.BASE_URL)` is a snapshot that
        // compiles identically from a distance. Every construction of every
        // host-taking type in the main source set has to go through a lambda.
        val construction = Regex(
            """(HttpsAuthTransport|RecordingAuthTransport|HttpChatEventStream|""" +
                """FileClient|ChatClient|RecentsClient|ProjectsClient)\s*\(\s*AuthConfig\.BASE_URL""",
        )

        for (file in ALL_MAIN_SOURCES) {
            val source = withoutComments(
                readOrFail("src/main/java/com/pabrik/mobile/$file", file),
            )
            assertTrue(
                "$file passes a host value to a transport; it must pass a provider:\n" +
                    source.lines()
                        .filter { construction.containsMatchIn(it) }
                        .joinToString("\n"),
                !construction.containsMatchIn(source),
            )
        }
    }

    // ─── source access ─────────────────────────────────────────────────────

    private fun buildScript(): String = readOrFail("build.gradle.kts", "app/build.gradle.kts")

    /**
     * The same source with its line comments gone.
     *
     * Only `//` — not a block-comment pass — because these files have none, and
     * a half-correct comment stripper is a worse failure than none: it would
     * report a code line as prose and silently stop protecting the thing.
     */
    private fun withoutComments(source: String): String =
        source.lineSequence()
            .map { it.substringBefore("//") }
            .joinToString("\n")

    private fun readOrFail(vararg relativePaths: String): String =
        relativePaths.map(::File).firstOrNull(File::isFile)?.readText()
            ?: error("none of ${relativePaths.toList()} reachable from ${File(".").absolutePath}")

    /**
     * The text inside `name { ... }`, by brace depth.
     *
     * A regex cannot do this — the blocks nest — and the build script is small
     * and brace-balanced, so counting depth from the opening brace is both
     * simpler and exact.
     */
    private fun block(source: String, name: String): String {
        val needle = "$name {"
        assertEquals(
            "`$needle` should appear exactly once in the build script",
            1,
            Regex(Regex.escape(needle)).findAll(source).count(),
        )
        val open = source.indexOf(needle) + needle.length - 1
        var depth = 0
        for (i in open until source.length) {
            when (source[i]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return source.substring(open + 1, i)
                }
            }
        }
        error("unbalanced braces after `$needle`")
    }

    private companion object {
        val RELEASE_SOURCES = listOf(
            "src/release/AndroidManifest.xml",
            "src/release/res/xml/network_security_config.xml",
        )

        /**
         * Every Kotlin file in the main source set, relative to the package root.
         *
         * Recursed rather than listed: a fifth call site in a file nobody
         * remembered to add here would freeze silently, and this check is the
         * only thing that would have noticed.
         */
        val ALL_MAIN_SOURCES: List<String> =
            File("src/main/java/com/pabrik/mobile")
                .takeIf(File::isDirectory)
                ?.walkTopDown()
                ?.filter { it.isFile && it.extension == "kt" }
                ?.map { it.relativeTo(File("src/main/java/com/pabrik/mobile")).path }
                ?.toList()
                .orEmpty()

        /**
         * Every file that turns a path into a URL, relative to the package root.
         *
         * `auth/ServerUrl.kt` is deliberately absent even though it has
         * `baseUrl: String` in it twice: it is the module that *defines* the
         * rule, and both of those are per-call — a returned value and a function
         * argument — rather than a host held across requests. Forbidding them
         * would forbid the one file that has to be allowed to name a host as a
         * plain value.
         *
         * `ModelProfile.baseUrl` and `PresentFiles.downloadUrl` are the same
         * story and are not in this list: the first is the *LLM provider's* URL
         * as read from `config.profiles_models`, and the second is a pure URL
         * builder called with a host that `FileClient` has already resolved.
         */
        val TRANSPORT_SOURCES = listOf(
            "auth/AuthClient.kt",
            "chat/ChatClient.kt",
            "chat/ChatEventStreamTransport.kt",
            "chat/FileClient.kt",
            "network/RecordingAuthTransport.kt",
            "projects/ProjectsClient.kt",
            "recents/RecentsClient.kt",
        )
    }
}
