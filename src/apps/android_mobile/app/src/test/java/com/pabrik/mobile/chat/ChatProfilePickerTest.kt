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

/** The composer's model picker, from the wire up. */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatProfilePickerTest {

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

    private fun profileTest(body: suspend TestScope.(Schedulers) -> Unit) = runTest {
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


    /** Answers `GET /api/config/pabrik` and `PUT /api/llm/session/{id}`, and refuses to guess at anything else. */
    private class ProfileTransport(
        private val configBody: String = CONFIGS,
        private val configStatus: Int = 200,
        private val putStatus: Int = 200,
        private val offline: Boolean = false,
    ) : AuthTransport {
        val puts = mutableListOf<Pair<String, String>>()
        val gets = mutableListOf<String>()

        override fun get(path: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            gets += path
            if (path == ChatApi.profilesPath()) {
                return AuthHttpResponse(configStatus, configBody)
            }
            return AuthHttpResponse(
                200,
                """{"messages":[],"has_more":false,"next_cursor":null,"total":0}""",
            )
        }

        override fun post(path: String, body: String, headers: Map<String, String>) =
            AuthHttpResponse(201, """{"status":"send"}""")

        override fun put(path: String, body: String, headers: Map<String, String>): AuthHttpResponse {
            if (offline) throw IOException("offline")
            puts += path to body
            if (putStatus !in 200..299) {
                return AuthHttpResponse(putStatus, """{"error":"nope"}""")
            }
            val stored = org.json.JSONObject(body).optString("selected_profile_model")
            return AuthHttpResponse(200, """{"selected_profile_model":"$stored"}""")
        }
    }

    private fun model(
        ioDispatcher: CoroutineDispatcher,
        transport: AuthTransport,
    ) = ChatViewModel(
        client = ChatClient(MemorySessionStore(), httpTransport = transport),
        cache = InMemoryChatCache(),
        bus = FakeSseBus(),
        ioDispatcher = ioDispatcher,
    ).also { it.onUserChanged("user_a") }

    // --- The cascade -------------------------------------------------------

    @Test
    fun anEmptyPerSessionValueFallsThroughToTheActiveProfile() {
        // The regression this whole file exists for.
        assertEquals("free tier", effectiveProfileName("", "free tier"))
    }

    @Test
    fun aPerSessionChoiceOutranksTheActiveProfile() {
        assertEquals("space bunny", effectiveProfileName("space bunny", "free tier"))
    }

    @Test
    fun withNeitherThereIsNoEffectiveProfile() {
        // Null, not "Default": the caller decides how to word an absent profile, and two callers word it differently.
        assertNull(effectiveProfileName("", null))
    }

    @Test
    fun theUiStateAnswersTheSameQuestionAsTheFunction() {
        val state = ChatUiState(selectedProfileModel = "", activeProfile = "free tier")
        assertEquals("free tier", state.effectiveProfile)
    }

    // --- The wire ----------------------------------------------------------

    @Test
    fun profilesAreAnObjectKeyedByName() {
        val page = ChatApi.parseProfiles(CONFIGS)

        assertEquals(
            listOf("space bunny free", "work key"),
            page.profiles.map { it.name },
        )
        assertEquals("gpt-5", page.profiles.first().model)
        assertEquals("https://api.example/v1", page.profiles.first().baseUrl)
    }

    @Test
    fun anUnsetActiveProfileArrivesAsNullNotEmptyString() {
        // `""` here would make the cascade read as "there is an active profile called nothing" rather than "there is none".
        assertNull(ChatApi.parseProfiles("""{"profiles":{},"active_profile":""}""").activeProfile)
    }

    @Test
    fun aProfileWithNoUrlStillSaysSomething() {
        // Joining blindly would leave a dangling separator, which reads as a rendering bug rather than as a missing value.
        val page = ChatApi.parseProfiles("""{"profiles":{"bare":{"model":"gpt-5"}}}""")
        assertEquals("gpt-5", page.profiles.single().detail)
    }

    @Test
    fun aConfigWithNoProfilesKeyIsAnEmptyList() {
        val page = ChatApi.parseProfiles("""{"retry_delay_ms":0}""")
        assertTrue(page.profiles.isEmpty())
        assertNull(page.activeProfile)
    }

    @Test
    fun theUpdateCarriesAllThreeFields() {
        val body = org.json.JSONObject(
            ChatApi.updateSessionBody(selectedProfileModel = "space bunny free"),
        )
        assertEquals("space bunny free", body.optString("selected_profile_model"))
        // Both present and empty, which the backend reads as "leave alone".
        assertTrue(body.has("name"))
        assertEquals("", body.optString("name"))
        assertTrue(body.has("is_auto_retry_until_stop"))
    }

    @Test
    fun clearingTheProfileIsAnEmptyValueNotAnAbsentField() {
        // `session_update.zig:84` writes the column unconditionally precisely so this can be expressed.
        val body = org.json.JSONObject(ChatApi.updateSessionBody(selectedProfileModel = ""))
        assertTrue(body.has("selected_profile_model"))
        assertEquals("", body.optString("selected_profile_model"))
    }

    // --- The client --------------------------------------------------------

    @Test
    fun savingAProfilePutsToTheSessionPathWithTheCookie() {
        val transport = ProfileTransport()
        val client = ChatClient(MemorySessionStore("tok"), httpTransport = transport)

        val result = client.updateSelectedProfile("sess_1", "space bunny free")

        assertTrue(result is ChatResult.Loaded)
        val (path, body) = transport.puts.single()
        assertEquals("/api/llm/session/sess_1", path)
        assertEquals(
            "space bunny free",
            org.json.JSONObject(body).optString("selected_profile_model"),
        )
    }

    @Test
    fun theProfilesCallReadsTheConfigEndpoint() {
        val transport = ProfileTransport()
        val client = ChatClient(MemorySessionStore(), httpTransport = transport)

        val result = client.loadProfiles()

        assertTrue(result is ChatResult.Loaded)
        assertEquals(listOf("/api/config/pabrik"), transport.gets)
    }

    @Test
    fun aRejectedSaveSaysSoRatherThanFailing() {
        // 4xx means the request itself was wrong, so the message is about the choice, not the network — the reader can fix this one by picking something else.
        val client = ChatClient(
            MemorySessionStore(),
            httpTransport = ProfileTransport(putStatus = 400),
        )

        val result = client.updateSelectedProfile("sess_1", "nope")

        assertTrue(result is ChatResult.Rejected)
    }

    // --- The ViewModel -----------------------------------------------------

    @Test
    fun openingAChatLoadsTheProfiles() = profileTest { s ->
        val model = model(s.ioDispatcher, ProfileTransport())
        model.openSession("sess_1")
        s.drain()

        val state = model.uiState.value
        assertEquals(listOf("space bunny free", "work key"), state.availableProfiles.map { it.name })
        assertEquals("space bunny free", state.activeProfile)
        assertFalse(state.isLoadingProfiles)
    }

    @Test
    fun aFailedProfileFetchLeavesTheChatAlone() = profileTest { s ->
        // A dropdown that cannot load must not blank a transcript that loaded perfectly well.
        val model = model(s.ioDispatcher, ProfileTransport(configStatus = 500))
        model.openSession("sess_1")
        s.drain()

        val state = model.uiState.value
        assertNull("a dropdown failure is not a chat failure", state.errorMessage)
        assertTrue(state.availableProfiles.isEmpty())
        assertFalse(state.isLoading)
    }

    @Test
    fun pickingAProfileIsPersistedAndThenReflected() = profileTest { s ->
        val transport = ProfileTransport()
        val model = model(s.ioDispatcher, transport)
        model.openSession("sess_1")
        s.drain()

        model.selectProfile("work key")
        s.drain()

        assertEquals(1, transport.puts.size)
        assertEquals("work key", model.uiState.value.selectedProfileModel)
        // The chip now shows the chat's choice, not the account default.
        assertEquals("work key", model.uiState.value.effectiveProfile)
        assertFalse(model.uiState.value.isUpdatingProfile)
    }

    @Test
    fun aFailedPickLeavesTheChipWhereItWas() = profileTest { s ->
        // The whole reason this is not optimistic: a chip that names a profile the next turn does not use is the one thing the reader cannot check.
        val model = model(s.ioDispatcher, ProfileTransport(putStatus = 500))
        model.openSession("sess_1")
        s.drain()

        model.selectProfile("work key")
        s.drain()

        assertEquals("", model.uiState.value.selectedProfileModel)
        assertEquals("space bunny free", model.uiState.value.effectiveProfile)
        assertFalse(model.uiState.value.isUpdatingProfile)
        assertTrue(model.uiState.value.errorMessage != null)
    }

    @Test
    fun aSecondPickIsRefusedWhileTheFirstIsSaving() = profileTest { s ->
        // Two in-flight PUTs make the last *response* the winner rather than the last tap, which is a different and much more confusing order.
        val transport = ProfileTransport()
        val model = model(s.ioDispatcher, transport)
        model.openSession("sess_1")
        s.drain()

        model.selectProfile("work key")
        model.selectProfile("space bunny free")
        s.drain()

        assertEquals(1, transport.puts.size)
    }

    // --- Whether the chip is a control at all ------------------------------

    @Test
    fun aChipWithNothingToPickIsNotAControl() {
        // A menu that opens onto an empty list teaches the reader the footer is decoration, which is worse than the label this used to be.
        val state = ChatUiState(selectedProfileModel = "", availableProfiles = emptyList())
        assertFalse(state.canPickProfile)
    }

    @Test
    fun aPerSessionChoiceAloneIsEnoughToKeepTheControl() {
        // The reader needs a way to *undo* it, and "Default" is that row.
        val state = ChatUiState(selectedProfileModel = "space bunny free")
        assertTrue(state.canPickProfile)
    }

    @Test
    fun anyConfiguredProfileIsEnoughToMakeItAControl() {
        val state = ChatUiState(
            selectedProfileModel = "",
            availableProfiles = listOf(ModelProfile("a", "m", "u")),
        )
        assertTrue(state.canPickProfile)
    }

    private companion object {
        /** Shaped like the real `GET /api/config/pabrik`: `profiles` is an object keyed by name, and `active_profile` is a bare name. */
        val CONFIGS = """
            {
              "profiles": {
                "space bunny free": {
                  "model": "gpt-5",
                  "base_url": "https://api.example/v1"
                },
                "work key": {
                  "model": "claude",
                  "base_url": "https://api.anthropic.com"
                }
              },
              "active_profile": "space bunny free"
            }
        """.trimIndent()
    }
}
