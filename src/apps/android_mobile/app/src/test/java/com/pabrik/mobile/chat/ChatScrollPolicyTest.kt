package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Where a transcript puts its viewport, and — more to the point — where it refuses to. */
class ChatScrollPolicyTest {

    // --- The decision table --------------------------------------------------

    @Test
    fun openingAChatLandsOnTheNewestTurn() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = true,
            groupCount = 12,
            previousGroupCount = 40,
            anchor = null,
            isFollowingNewest = false,
        )

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.SESSION_OPENED), action)
    }

    @Test
    fun openingAChatLandsOnTheNewestTurnEvenWhenTheCountsAreIdentical() {
        // The regression this whole file exists for.
        val action = ChatScrollPolicy.decide(
            sessionChanged = true,
            groupCount = 12,
            previousGroupCount = 12,
            anchor = null,
            isFollowingNewest = false,
        )

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.SESSION_OPENED), action)
    }

    @Test
    fun openingAChatLandsOnTheNewestTurnEvenWithAnAnchorStrandedFromTheLastOne() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = true,
            groupCount = 3,
            previousGroupCount = 0,
            anchor = ChatScrollAnchor(key = "m99", offset = -14),
            isFollowingNewest = true,
        )

        // An anchor names a message in the chat that was just left.
        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.SESSION_OPENED), action)
    }

    @Test
    fun anEmptyTranscriptIsNeverScrolled() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = true,
            groupCount = 0,
            previousGroupCount = 0,
            anchor = null,
            isFollowingNewest = true,
        )

        assertEquals(ChatScrollAction.Hold, action)
    }

    @Test
    fun aPrependPutsTheReaderBackOnTheMessageTheyWereReading() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 21,
            previousGroupCount = 9,
            anchor = ChatScrollAnchor(key = "m7", offset = -12),
            isFollowingNewest = false,
        )

        assertEquals(ChatScrollAction.RestoreAnchor(key = "m7", offset = -12), action)
    }

    @Test
    fun aPrependBeatsTheFollowFlag() {
        // The reader asked to read further back; following the tail here would throw away the page they just pulled.
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 21,
            previousGroupCount = 9,
            anchor = ChatScrollAnchor(key = "m7", offset = 0),
            isFollowingNewest = true,
        )

        assertEquals(ChatScrollAction.RestoreAnchor(key = "m7", offset = 0), action)
    }

    @Test
    fun anAppendFollowsTheTailWhileTheReaderIsAtTheEnd() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 10,
            previousGroupCount = 9,
            anchor = null,
            isFollowingNewest = true,
        )

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }

    @Test
    fun anAppendLeavesARewerInHistoryAlone() {
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 10,
            previousGroupCount = 9,
            anchor = null,
            isFollowingNewest = false,
        )

        assertEquals(ChatScrollAction.Hold, action)
    }

    @Test
    fun aGrownTailFollowsTheReaderEvenThoughNoCountMoved() {
        // A streamed delta replaces the newest message in place: same group count, same message count, taller by a line.
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 10,
            previousGroupCount = 10,
            anchor = null,
            isFollowingNewest = true,
        )

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }

    @Test
    fun aShrunkListLandsOnTheNewestTurn() {
        // The streaming placeholder collapsing into the turn above it removes a group, and the reader must not be left hanging past a shorter list.
        val action = ChatScrollPolicy.decide(
            sessionChanged = false,
            groupCount = 9,
            previousGroupCount = 10,
            anchor = null,
            isFollowingNewest = false,
        )

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }

    // --- The bookkeeping around it -------------------------------------------

    @Test
    fun aColdOpenWithNoCacheStillLandsOnTheNewestTurnWhenTheFirstPageArrives() {
        // `openSession` paints an empty transcript first when there is nothing cached, and the rows land a frame later.
        val scroll = ChatScrollState()

        scroll.onViewportMoved(lastVisibleIndex = 30, totalItems = 40, isScrolling = true)
        assertFalse("precondition: the reader left the end in the previous chat", scroll.isFollowingNewest)

        assertEquals(ChatScrollAction.Hold, scroll.onContentChanged(sessionId = "s2", groupCount = 0))

        val action = scroll.onContentChanged(sessionId = "s2", groupCount = 25)

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.SESSION_OPENED), action)
    }

    @Test
    fun switchingChatsReArmsTheFollowFlagWhateverTheReaderWasDoing() {
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        assertFalse(scroll.isFollowingNewest)

        scroll.onContentChanged(sessionId = "s2", groupCount = 4)

        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun aSettledLayoutIsNotAReaderLeaving() {
        // The trap the old watcher walked into.
        val scroll = ChatScrollState()

        scroll.onViewportMoved(lastVisibleIndex = 0, totalItems = 40, isScrolling = false)

        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun theFirstLayoutOfAListWithNothingInItChangesNothing() {
        val scroll = ChatScrollState()

        scroll.onViewportMoved(lastVisibleIndex = -1, totalItems = 0, isScrolling = false)
        scroll.onViewportMoved(lastVisibleIndex = -1, totalItems = 0, isScrolling = true)

        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun aDragAwayFromTheEndStopsTheTranscriptFollowing() {
        val scroll = ChatScrollState()

        scroll.onViewportMoved(lastVisibleIndex = 9, totalItems = 10, isScrolling = true)
        assertTrue(scroll.isFollowingNewest)

        scroll.onViewportMoved(lastVisibleIndex = 4, totalItems = 10, isScrolling = true)
        assertFalse(scroll.isFollowingNewest)
    }

    @Test
    fun theSettlingFrameOfAFlingStillCountsAsTheReadersOwnMovement() {
        // A fling settles and stops reporting an in-progress scroll in the same snapshot, so gating on the *current* reading alone would discard the position the fling …
        val scroll = ChatScrollState()

        scroll.onViewportMoved(lastVisibleIndex = 8, totalItems = 10, isScrolling = true)
        scroll.onViewportMoved(lastVisibleIndex = 3, totalItems = 10, isScrolling = false)

        assertFalse(scroll.isFollowingNewest)
    }

    @Test
    fun scrollingBackToTheEndResumesFollowing() {
        val scroll = ChatScrollState()
        scroll.onViewportMoved(lastVisibleIndex = 3, totalItems = 10, isScrolling = true)
        assertFalse(scroll.isFollowingNewest)

        scroll.onViewportMoved(lastVisibleIndex = 9, totalItems = 10, isScrolling = true)
        scroll.onViewportMoved(lastVisibleIndex = 9, totalItems = 10, isScrolling = false)

        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun sendingATurnTakesTheReaderToTheNewestTurn() {
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 1, totalItems = 10, isScrolling = true)

        val action = scroll.onTurnSent()

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.TURN_SENT), action)
        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun anAnchorIsConsumedExactlyOnce() {
        // Consumed once, because a stale anchor replayed on a later append would yank the reader back to an old message with no gesture to explain it.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.armOlderPage(ChatScrollAnchor(key = "m7", offset = -8))

        assertEquals(
            ChatScrollAction.RestoreAnchor(key = "m7", offset = -8),
            scroll.onContentChanged(sessionId = "s1", groupCount = 20),
        )
        assertEquals(
            ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT),
            scroll.onContentChanged(sessionId = "s1", groupCount = 21),
        )
    }

    @Test
    fun anArmedAnchorThatNeverArrivesIsDroppedByTheNextOpen() {
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.armOlderPage(ChatScrollAnchor(key = "m7", offset = 0))
        // The reader left before the page came back.
        scroll.onContentChanged(sessionId = "s2", groupCount = 5)

        val action = scroll.onContentChanged(sessionId = "s2", groupCount = 6)

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }

    // --- Offering the reader a way back to the end --------------------------

    /** The band the control uses, in pixels. */
    private val band = 24

    @Test
    fun aTranscriptParkedOnItsNewestTurnOffersNoJump() {
        // A control that is always there is a control that does nothing, and a reader who has learned to distrust it will not tap it when it matters.
        assertFalse(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = 0,
                bandPx = band,
            ),
        )
    }

    @Test
    fun aReaderInsideThePaddingBandIsStillAtTheEnd() {
        // Zero is a transcript parked on its newest turn, and a reader a line or two above it reads a small positive distance.
        assertFalse(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = 12,
                bandPx = band,
            ),
        )
    }

    @Test
    fun aReaderWhoHasLeftTheEndIsOfferedAJump() {
        assertTrue(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = 500,
                bandPx = band,
            ),
        )
    }

    @Test
    fun aReaderScrolledUpInsideOneTallAnswerIsStillOfferedAJump() {
        // Why the distance is measured in pixels.
        assertTrue(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = 900,
                bandPx = band,
            ),
        )
    }

    @Test
    fun aTranscriptWhoseEndIsNotOnScreenIsOfferedAJump() {
        // `DISTANCE_FAR` is a real answer and the furthest one, not a synonym for "unknown".
        assertTrue(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = DISTANCE_FAR,
                bandPx = band,
            ),
        )
    }

    @Test
    fun anUnmeasuredLayoutOffersNoJump() {
        // A cold open lays the list out before the first row arrives.
        assertTrue(
            "the unmeasured sentinel must be negative, and no reading is",
            DISTANCE_UNMEASURED < 0,
        )
        assertFalse(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = DISTANCE_UNMEASURED,
                bandPx = band,
            ),
        )
    }

    @Test
    fun aJumpTakesTheReaderToTheNewestTurn() {
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        assertFalse("precondition: the reader is in history", scroll.isFollowingNewest)

        val action = scroll.onReaderJumpedToNewest()

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.READER_JUMPED), action)
        assertTrue(scroll.isFollowingNewest)
    }

    @Test
    fun aJumpKeepsTheTranscriptFollowingTheStream() {
        // The reason the jump goes through the policy rather than straight to `scrollToItem`.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        scroll.onReaderJumpedToNewest()

        val action = scroll.onContentChanged(sessionId = "s1", groupCount = 10)

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }

    @Test
    fun aJumpDiscardsAnOlderPageAnchorThatIsStillInFlight() {
        // The subtle one.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.armOlderPage(ChatScrollAnchor(key = "m7", offset = -8))
        scroll.onViewportMoved(lastVisibleIndex = 1, totalItems = 10, isScrolling = true)
        scroll.onReaderJumpedToNewest()

        val action = scroll.onContentChanged(sessionId = "s1", groupCount = 20)

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), action)
    }

    @Test
    fun anEmptyTranscriptIsNeverOfferedAJump() {
        // Nothing measured is [DISTANCE_UNMEASURED], and there is no newest turn to take anybody to.
        assertEquals(
            ChatScrollAction.Hold,
            ChatScrollState().onContentChanged(sessionId = "s1", groupCount = 0),
        )
        assertFalse(
            ChatScrollPolicy.shouldOfferJumpToNewest(
                distanceFromBottomPx = DISTANCE_UNMEASURED,
                bandPx = band,
            ),
        )
    }

    @Test
    fun sendingATurnFromHistoryFollowsTheTurnWhenItLands() {
        // The reported behaviour, in its plainest form: the reader is reading history, they ask for a turn, and the turn they asked for is the one on screen when it …
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        assertFalse("precondition: the reader is in history", scroll.isFollowingNewest)

        val sent = scroll.onTurnSent()

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.TURN_SENT), sent)
        assertTrue(
            "asking for a turn re-arms the follow before the turn exists",
            scroll.isFollowingNewest,
        )
        // There is no optimistic bubble, so the row arrives over SSE a frame or two later.
        assertEquals(
            ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT),
            scroll.onContentChanged(sessionId = "s1", groupCount = 11),
        )
    }

    @Test
    fun aScrollInFlightWhenTheTurnWasSentDoesNotDisarmTheFollow() {
        // The race.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        assertFalse("precondition: the reader is in history", scroll.isFollowingNewest)
        scroll.onTurnSent()

        // The fling's trailing frame, still reading the pre-send position.
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)

        assertEquals(
            "a movement that was already in flight when the turn was sent is not " +
                "the reader leaving, and must not cancel the follow they asked for",
            ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT),
            scroll.onContentChanged(sessionId = "s1", groupCount = 11),
        )
    }

    @Test
    fun aQueuedTurnFollowsTheTranscriptWhenTheWorkerDrainsIt() {
        // A queue is a send that produces no row: nothing lands between asking and the worker draining the turn, so the follow has to survive a stretch of unrelated …
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        scroll.onTurnSent()

        // The reader arrives at the end: the pin did what it was asked to.
        scroll.onViewportMoved(lastVisibleIndex = 9, totalItems = 10, isScrolling = true)
        // The run they queued behind streams while they wait.
        scroll.onContentChanged(sessionId = "s1", groupCount = 11)
        // And then the queued turn is drained into the transcript.
        val drained = scroll.onContentChanged(sessionId = "s1", groupCount = 12)

        assertEquals(ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT), drained)
    }

    @Test
    fun leavingAfterTheTurnLandedStillStopsTheTranscriptFollowing() {
        // The other side of the same latch, and the reason it has to be spent.
        val scroll = ChatScrollState()
        scroll.onContentChanged(sessionId = "s1", groupCount = 10)
        scroll.onViewportMoved(lastVisibleIndex = 2, totalItems = 10, isScrolling = true)
        scroll.onTurnSent()
        scroll.onContentChanged(sessionId = "s1", groupCount = 11)

        // A fresh gesture, after the sent turn is already on screen.
        scroll.onViewportMoved(lastVisibleIndex = 3, totalItems = 11, isScrolling = true)

        assertFalse(
            "a deliberate scroll away after the turn landed must disengage the follow",
            scroll.isFollowingNewest,
        )
        assertEquals(
            ChatScrollAction.Hold,
            scroll.onContentChanged(sessionId = "s1", groupCount = 12),
        )
    }
}
