package com.pabrik.mobile.chat

/** Why the transcript is being asked to move. */
enum class ChatPinReason {
    /** A chat was opened. Always lands on the newest turn. */
    SESSION_OPENED,

    /** Content below the viewport changed — an append, a prepend-free grow. */
    NEWER_CONTENT,

    /** The reader asked for a turn by sending one. */
    TURN_SENT,

    /** The reader pressed the transcript's "take me to the newest turn" control. */
    READER_JUMPED,
}

/** The distance reading that means "nothing has been measured yet". */
const val DISTANCE_UNMEASURED: Int = Int.MIN_VALUE

/** The furthest reading there is: the end of the transcript is not on screen. */
const val DISTANCE_FAR: Int = Int.MAX_VALUE

/** Where the reader was when a backwards page was requested. */
data class ChatScrollAnchor(val key: String, val offset: Int)

/** What the transcript should do about its scroll position. */
sealed interface ChatScrollAction {
    /** Leave the viewport alone. */
    data object Hold : ChatScrollAction

    /** Park the viewport on the newest turn. */
    data class PinToNewest(val reason: ChatPinReason) : ChatScrollAction

    /** Put the reader back on the message a prepend pushed out of view. */
    data class RestoreAnchor(val key: String, val offset: Int) : ChatScrollAction
}

/** Decides where the transcript goes when its content changes. */
object ChatScrollPolicy {
    fun decide(
        sessionChanged: Boolean,
        groupCount: Int,
        previousGroupCount: Int,
        anchor: ChatScrollAnchor?,
        isFollowingNewest: Boolean,
    ): ChatScrollAction = when {
        // Nothing is rendered.
        groupCount == 0 -> ChatScrollAction.Hold

        // Opening a chat is an explicit "show me this conversation", and the newest turn is where that starts.
        sessionChanged -> ChatScrollAction.PinToNewest(ChatPinReason.SESSION_OPENED)

        // A prepend is the reader's own scroll reaching the top.
        anchor != null && groupCount > previousGroupCount ->
            ChatScrollAction.RestoreAnchor(anchor.key, anchor.offset)

        // Fewer groups than before: the list shrank under the reader — a streaming placeholder collapsing into the turn above it, or a page replaced by a shorter one.
        groupCount < previousGroupCount -> ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT)

        // A streamed delta replaces the newest group in place, so neither count moved and this is the only branch that can see it.
        isFollowingNewest -> ChatScrollAction.PinToNewest(ChatPinReason.NEWER_CONTENT)

        else -> ChatScrollAction.Hold
    }

    /** Whether the transcript should offer an explicit "take me to the newest turn" control. */
    fun shouldOfferJumpToNewest(distanceFromBottomPx: Int, bandPx: Int): Boolean =
        distanceFromBottomPx != DISTANCE_UNMEASURED && distanceFromBottomPx > bandPx
}

/** The transcript's scroll bookkeeping: what the last known group count was, which chat is on screen, and whether the reader is still following the end. */
class ChatScrollState {

    /** Whether a new turn should pull the viewport down. */
    var isFollowingNewest: Boolean = true
        private set

    private var openedSessionId: String? = null
    private var lastGroupCount: Int = 0
    private var pendingAnchor: ChatScrollAnchor? = null

    /** Set when a chat is opened and cleared by the first content change it produces. */
    private var sessionOpenPending: Boolean = false

    /** True while the reader is dragging or flinging. */
    private var readerIsScrolling: Boolean = false

    /** True between "the reader asked for the newest turn" and the transcript proving it got there. */
    private var followArmed: Boolean = false

    /** Remembers where the reader was when a backwards page was requested, so the response can put them back rather than at the end. */
    fun armOlderPage(anchor: ChatScrollAnchor?) {
        pendingAnchor = anchor
    }

    /** The transcript changed. Returns where it should now be. */
    fun onContentChanged(sessionId: String?, groupCount: Int): ChatScrollAction {
        val openedNow = openedSessionId != sessionId
        if (openedNow) {
            openedSessionId = sessionId
            sessionOpenPending = true
            // An anchor from the chat we just left points at a message that is not in this one.
            pendingAnchor = null
            // Whatever the reader was doing, they asked for this chat.
            isFollowingNewest = true
        }

        val action = ChatScrollPolicy.decide(
            sessionChanged = sessionOpenPending,
            groupCount = groupCount,
            previousGroupCount = lastGroupCount,
            anchor = pendingAnchor,
            isFollowingNewest = isFollowingNewest,
        )
        // Only spent once it has actually moved something.
        if (action !is ChatScrollAction.Hold) sessionOpenPending = false

        when (action) {
            is ChatScrollAction.PinToNewest -> {
                isFollowingNewest = true
                // The pin this produced is the answer the reader asked for, so the arm is spent: a later scroll away is the reader's own.
                followArmed = false
            }

            is ChatScrollAction.RestoreAnchor -> pendingAnchor = null
            ChatScrollAction.Hold -> Unit
        }

        lastGroupCount = groupCount
        return action
    }

    /** The reader asked for a turn by sending one, so the newest turn is where they want to be even if they were reading history when they hit send. */
    fun onTurnSent(): ChatScrollAction {
        isFollowingNewest = true
        pendingAnchor = null
        // The turn does not exist yet, so nothing but the viewport reading can report the pin landing before it arrives.
        followArmed = true
        return ChatScrollAction.PinToNewest(ChatPinReason.TURN_SENT)
    }

    /** The reader pressed the "take me to the newest turn" control. */
    fun onReaderJumpedToNewest(): ChatScrollAction {
        isFollowingNewest = true
        pendingAnchor = null
        return ChatScrollAction.PinToNewest(ChatPinReason.READER_JUMPED)
    }

    /** The viewport moved. */
    fun onViewportMoved(
        lastVisibleIndex: Int,
        totalItems: Int,
        isScrolling: Boolean,
    ) {
        val wasScrolling = readerIsScrolling
        readerIsScrolling = isScrolling
        if (!wasScrolling && !isScrolling) return
        if (totalItems <= 0) return
        if (lastVisibleIndex >= totalItems - 1) {
            // We are where the reader last asked to be, so the arm is spent.
            followArmed = false
            isFollowingNewest = true
            return
        }
        // A send is an explicit "take me to the newest turn", and the scroll the transcript is running to honour it is not the reader's.
        if (followArmed) return
        isFollowingNewest = false
    }
}
