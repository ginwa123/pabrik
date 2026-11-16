package com.pabrik.mobile.recents

import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The destination behind the drawer's `See all chats ›` row, on the JVM. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class RecentsChatsScreenTest {

    @get:Rule
    val composeTestRule = createComposeRule()

    private val now = 1_800_000_000_000L

    private fun chats(count: Int) = (1..count).map { index ->
        ChatSummary(
            id = "chat-$index",
            workspaceId = "workspace-a",
            title = "Chat $index",
            updatedAtEpochMillis = now - index * 60_000L,
        )
    }

    private fun showScreen(
        chats: List<ChatSummary> = chats(5),
        hasMore: Boolean = false,
        isLoadingMore: Boolean = false,
        isLoading: Boolean = false,
        loadMoreError: String? = null,
        onOpenChat: (String) -> Unit = {},
        onLoadMore: () -> Unit = {},
        onBack: () -> Unit = {},
    ) {
        composeTestRule.setContent {
            PabrikTheme {
                RecentsChatsScreen(
                    workspaceName = "agentic coding",
                    chats = chats,
                    selectedChatId = null,
                    runningSessionIds = emptySet(),
                    hasMore = hasMore,
                    isLoadingMore = isLoadingMore,
                    isLoading = isLoading,
                    onChatSelected = {},
                    onOpenChat = onOpenChat,
                    onLoadMore = onLoadMore,
                    loadMoreError = loadMoreError,
                    onBack = onBack,
                )
            }
        }
    }

    @Test
    fun itNamesTheWorkspaceItIsListing() {
        showScreen()

        // The title is the reader's answer to "whose chats am I in?", and a route that names its own workspace is the only thing that can be certain of it.
        composeTestRule.onNodeWithText("agentic coding").assertIsDisplayed()
    }

    @Test
    fun itListsEveryChatItIsGivenAndNoOthers() {
        // The whole point of the page: the drawer holds five, and this holds all thirty.
        showScreen(chats = chats(30))

        composeTestRule.onNodeWithTag("recents_chats_list").performScrollToIndex(29)
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithTag("chat_row_chat-30").assertIsDisplayed()
    }

    @Test
    fun tappingARowOpensThatChatAndNotTheSelection() {
        var opened: String? = null
        showScreen(chats = chats(5), onOpenChat = { opened = it })

        composeTestRule.onNodeWithTag("chat_row_chat-3").performClick()
        composeTestRule.waitForIdle()

        // Takes the id rather than being zero-argument, so a caller cannot navigate to "a chat" instead of the one that was tapped.
        assertEquals("chat-3", opened)
    }

    @Test
    fun theBackArrowReachesTheCaller() {
        var backs = 0
        showScreen(onBack = { backs++ })

        composeTestRule.onNodeWithTag("recents_chats_back").performClick()
        composeTestRule.waitForIdle()

        assertEquals(1, backs)
    }

    @Test
    fun itSaysThereIsMoreWhileTheServerSaysSo() {
        showScreen(chats = chats(5), hasMore = true)

        // Claiming the end while more may exist is a lie the reader reads first, then watches get retracted.
        composeTestRule.onNodeWithText("Scroll for older chats").assertIsDisplayed()
        composeTestRule.onNodeWithText("No older chats").assertDoesNotExist()
    }

    @Test
    fun itSaysNoOlderChatsOnceTheServerIsDone() {
        showScreen(chats = chats(5), hasMore = false)

        composeTestRule.onNodeWithText("No older chats").assertIsDisplayed()
        composeTestRule.onNodeWithText("Scroll for older chats").assertDoesNotExist()
    }

    @Test
    fun aPageInFlightShowsASpinnerRatherThanEitherClaim() {
        showScreen(chats = chats(5), hasMore = true, isLoadingMore = true)

        // The rows already on screen are real; the footer has to say "working" rather than "done" or "nothing here".
        composeTestRule.onNodeWithTag("chats_load_more_spinner").assertIsDisplayed()
        composeTestRule.onNodeWithText("No older chats").assertDoesNotExist()
        composeTestRule.onNodeWithText("Scroll for older chats").assertDoesNotExist()
    }

    @Test
    fun anEmptyWorkspaceIsAStateAndNotAFooter() {
        showScreen(chats = emptyList(), isLoading = false)

        // A workspace with no history is a fact, not a failure — and there is no end-of-list to report when there is no list.
        composeTestRule.onNodeWithTag("recents_chats_empty").assertIsDisplayed()
        composeTestRule.onNodeWithTag("chats_list_footer").assertDoesNotExist()
    }

    @Test
    fun aColdOpenShowsASpinnerRatherThanAnEmptyWorkspace() {
        // The failure this guards: a reader who taps the button on a cold process sees "No chats in this workspace yet" for the second it takes to answer, which is a …
        showScreen(chats = emptyList(), isLoading = true)

        composeTestRule.onNodeWithTag("recents_chats_loading").assertIsDisplayed()
        composeTestRule.onNodeWithTag("recents_chats_empty").assertDoesNotExist()
    }

    @Test
    fun itHasNoCreateAction() {
        // The project screen's `+` opens a flow scoped to one project.
        showScreen()

        composeTestRule.onNodeWithTag("project_chats_create").assertDoesNotExist()
    }

    // ── The trigger that could not fire ──────────────────────────────────

    @Test
    fun aListTooShortToScrollStillAsksForTheNextPage() {
        var calls = 0
        showScreen(chats = chats(5), hasMore = true, onLoadMore = { calls++ })
        composeTestRule.waitForIdle()

        // One page, asked for without the reader doing anything.
        assertEquals(1, calls)
    }

    @Test
    fun aPageInFlightStopsTheAskingRatherThanStackingRequests() {
        // The footer already says a page is coming.
        var calls = 0
        showScreen(
            chats = chats(5),
            hasMore = true,
            isLoadingMore = true,
            onLoadMore = { calls++ },
        )
        composeTestRule.waitForIdle()

        assertEquals(0, calls)
    }

    @Test
    fun aListWithNothingLeftNeverAsks() {
        var calls = 0
        showScreen(chats = chats(5), hasMore = false, onLoadMore = { calls++ })
        composeTestRule.waitForIdle()

        assertEquals(0, calls)
    }

    @Test
    fun aListLongEnoughToScrollWaitsForTheReader() {
        // The other half of the contract: 60 rows overflow the screen, so the reader now *has* a scroll and the screen has no reason to fetch a page they have not asked …
        var calls = 0
        showScreen(chats = chats(60), hasMore = true, onLoadMore = { calls++ })
        composeTestRule.waitForIdle()

        assertEquals(0, calls)
    }

    @Test
    fun reachingTheEndOfALongListAsksOnceAndThenWaits() {
        var calls = 0
        showScreen(chats = chats(60), hasMore = true, onLoadMore = { calls++ })

        composeTestRule.onNodeWithTag("recents_chats_list").performScrollToIndex(60)
        composeTestRule.waitForIdle()
        assertEquals(1, calls)

        // Parking on the end is not a second request.
        composeTestRule.waitForIdle()
        assertEquals(1, calls)
    }

    @Test
    fun theAutomaticPageStopsOnceThereIsSomethingToScroll() {
        val shown = mutableStateOf(chats(5))
        var calls = 0
        showPagedScreen(shown = shown, onLoadMore = {
            calls++
            // A page lands, and it is long enough to overflow the screen.
            shown.value = chats(60)
        })
        composeTestRule.waitForIdle()
        composeTestRule.waitForIdle()

        // Not a drain.
        assertEquals(1, calls)
        composeTestRule.onNodeWithTag("chat_row_chat-60").assertDoesNotExist()
        composeTestRule.onNodeWithTag("chat_row_chat-1").assertIsDisplayed()
    }

    @Test
    fun aPageThatNeverArrivesIsNotRetriedInALoop() {
        // The request goes out, the spinner goes round, nothing comes back.
        val shown = mutableStateOf(chats(5))
        val loadingMore = mutableStateOf(false)
        var calls = 0
        showPagedScreen(
            shown = shown,
            isLoadingMore = loadingMore,
            onLoadMore = { calls++ },
        )
        composeTestRule.waitForIdle()
        assertEquals(1, calls)

        loadingMore.value = true
        composeTestRule.waitForIdle()
        loadingMore.value = false
        composeTestRule.waitForIdle()
        composeTestRule.waitForIdle()

        assertEquals(1, calls)
    }

    @Test
    fun aFailedPageIsSomethingTheReaderCanDoRatherThanAnInstructionTheyCannot() {
        // The other half of the dead end: a page that does not arrive used to leave the footer reading "Scroll for older chats", and on the five-row list this screen …
        var calls = 0
        showScreen(
            chats = chats(5),
            hasMore = true,
            loadMoreError = "Could not reach the server",
            onLoadMore = { calls++ },
        )
        composeTestRule.waitForIdle()
        val before = calls

        composeTestRule.onNodeWithTag("chats_load_more_error").assertIsDisplayed()
        composeTestRule.onNodeWithText("Scroll for older chats").assertDoesNotExist()
        composeTestRule.onNodeWithText("No older chats").assertDoesNotExist()

        composeTestRule.onNodeWithTag("chats_load_more_error").performClick()
        composeTestRule.waitForIdle()

        // The tap asks for exactly what a scroll would have.
        assertEquals(before + 1, calls)
    }

    @Test
    fun aFailedPageIsNeverReportedAsTheEndOfTheList() {
        // `has_more` is kept true across a failure so asking again re-requests the same window.
        showScreen(
            chats = chats(5),
            hasMore = false,
            loadMoreError = "Could not reach the server",
        )

        composeTestRule.onNodeWithTag("chats_load_more_error").assertIsDisplayed()
        composeTestRule.onNodeWithText("No older chats").assertDoesNotExist()
    }

    /** A host whose list and in-flight flag the test can move, because "the page landed" and "the page did not land" are only distinguishable by what the screen is … */
    private fun showPagedScreen(
        shown: State<List<ChatSummary>>,
        isLoadingMore: State<Boolean> = mutableStateOf(false),
        onLoadMore: () -> Unit,
    ) {
        composeTestRule.setContent {
            PabrikTheme {
                RecentsChatsScreen(
                    workspaceName = "agentic coding",
                    chats = shown.value,
                    selectedChatId = null,
                    runningSessionIds = emptySet(),
                    hasMore = true,
                    isLoadingMore = isLoadingMore.value,
                    isLoading = false,
                    onChatSelected = {},
                    onOpenChat = {},
                    onLoadMore = onLoadMore,
                    onBack = {},
                )
            }
        }
    }

    // ── The one predicate both the footer and the scroll trigger read ──

    @Test
    fun pagingIsRefusedWhileThereIsNothingToPageOnto() {
        // The trigger's band is index-based, and an empty list holds one placeholder row at index 0 — so without this the first layout arms a fetch that appends onto …
        assertFalse(recentsChatsCanPage(chats = emptyList(), hasMore = true, isLoadingMore = false))
        assertFalse(recentsChatsCanPage(chats = chats(5), hasMore = false, isLoadingMore = false))
        assertFalse(recentsChatsCanPage(chats = chats(5), hasMore = true, isLoadingMore = true))
        assertTrue(recentsChatsCanPage(chats = chats(5), hasMore = true, isLoadingMore = false))
    }
}
