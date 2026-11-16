package com.pabrik.mobile.chat

/** How one transcript row is framed: as a chat bubble, as flat prose, or as a tool card. */
enum class MessageChrome {
    /** A tool result: a card, never a bubble. */
    TOOL_CARD,

    /** The reader's own turn: tinted, rounded, right-aligned, width-capped. */
    BUBBLE,

    /** An assistant turn: transparent, borderless, full-width prose. */
    PARAGRAPH,
}

/** Which frame [message] is drawn in. */
fun messageChrome(message: ChatMessage): MessageChrome = when {
    message.role == ChatMessage.ROLE_TOOL -> MessageChrome.TOOL_CARD
    message.isUser -> MessageChrome.BUBBLE
    else -> MessageChrome.PARAGRAPH
}

/** Vertical gap between the rows of one group, in dp. */
fun groupGapDp(group: ChatMessageGroup): Int = if (group.isUser) 6 else 10
