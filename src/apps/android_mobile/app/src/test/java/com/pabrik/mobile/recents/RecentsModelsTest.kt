package com.pabrik.mobile.recents

import org.junit.Assert.assertEquals
import org.junit.Test

class RecentsModelsTest {
    @Test
    fun recentChatsForWorkspaceFiltersAndSortsNewestFirst() {
        val chats = listOf(
            ChatSummary("chat-old", "workspace-a", "Old", 100L),
            ChatSummary("chat-b", "workspace-b", "Other workspace", 500L),
            ChatSummary("chat-a", "workspace-a", "New", 300L),
        )

        val result = recentChatsForWorkspace(chats, "workspace-a")

        assertEquals(listOf("chat-a", "chat-old"), result.map { it.id })
    }

    @Test
    fun recentChatsForWorkspaceUsesIdAsStableTieBreaker() {
        val chats = listOf(
            ChatSummary("chat-b", "workspace-a", "Second", 300L),
            ChatSummary("chat-a", "workspace-a", "First", 300L),
        )

        val result = recentChatsForWorkspace(chats, "workspace-a")

        assertEquals(listOf("chat-a", "chat-b"), result.map { it.id })
    }

    @Test
    fun aRunningSessionOrdersFirstEvenThoughTheHumanTouchedItLongestAgo() {
        // The reported behaviour: on the desktop the session the agent is working on sits at the top of Recent, because the list is ordered by `updated_at` — the column …
        val running = ChatSummary(
            id = "chat-running",
            workspaceId = "workspace-a",
            title = "Agent is working on this",
            updatedAtEpochMillis = 9_000L,
            lastHumanTouchedAtEpochMillis = 100L,
        )
        val chats = listOf(
            running,
            ChatSummary("chat-human-recent", "workspace-a", "You were here", 4_000L, 4_000L),
            ChatSummary("chat-middle", "workspace-a", "Neither", 6_000L, 6_000L),
        )

        val result = recentChatsForWorkspace(chats, "workspace-a")

        assertEquals(listOf("chat-running", "chat-middle", "chat-human-recent"), result.map { it.id })
    }

    @Test
    fun aRunningSessionKeepsTheHumansOwnTimeInItsLabel() {
        // Same row, seen from the other side: topping the list must not make the pill lie.
        val now = 10_000_000_000L
        val running = ChatSummary(
            id = "chat-running",
            workspaceId = "workspace-a",
            title = "Agent is working on this",
            updatedAtEpochMillis = now - 2L * 60_000L,
            lastHumanTouchedAtEpochMillis = now - 3L * 60L * 60_000L,
        )

        assertEquals("2m", formatRelativeTime(running.updatedAtEpochMillis, now))
        assertEquals("3h", formatRelativeTime(running.lastHumanTouchedAtEpochMillis, now))
    }

    @Test
    fun hasTimestampReadsTheLabelKeyNotTheOrderKey() {
        // A hand-built row whose label key is missing gets no pill rather than a fabricated "56y" — the order key is a perfectly good sort value but it is not what the …
        val unlabelled = ChatSummary("chat-1", "workspace-a", "Legacy", 5_000L, 0L)

        assertEquals(false, unlabelled.hasTimestamp)
        // Still ordered, never dropped: no label is a presentation problem, an invisible session is a data problem.
        assertEquals(listOf("chat-1"), recentChatsForWorkspace(listOf(unlabelled), "workspace-a").map { it.id })
    }

    @Test
    fun blankChatTitleFallsBackToNewChat() {
        val chat = ChatSummary("chat-1", "workspace-a", "   ", 300L)

        assertEquals("New Chat", chat.displayTitle)
    }

    @Test
    fun formatRelativeTimeUsesCompactRecentLabels() {
        val now = 10_000_000_000L

        assertEquals("now", formatRelativeTime(now - 30_000L, now))
        assertEquals("5m", formatRelativeTime(now - 5L * 60_000L, now))
        assertEquals("2h", formatRelativeTime(now - 2L * 60L * 60_000L, now))
        assertEquals("3d", formatRelativeTime(now - 3L * 24L * 60L * 60_000L, now))
        assertEquals("1w", formatRelativeTime(now - 7L * 24L * 60L * 60_000L, now))
        assertEquals("2mo", formatRelativeTime(now - 60L * 24L * 60L * 60_000L, now))
        assertEquals("1y", formatRelativeTime(now - 365L * 24L * 60L * 60_000L, now))
    }

    @Test
    fun accessibilityTimeLabelsSpellOutUnits() {
        val now = 10_000_000_000L

        assertEquals(
            "updated just now",
            formatRelativeTimeForAccessibility(now - 30_000L, now),
        )
        assertEquals(
            "updated 1 hour ago",
            formatRelativeTimeForAccessibility(now - 60L * 60_000L, now),
        )
        assertEquals(
            "updated 2 days ago",
            formatRelativeTimeForAccessibility(now - 2L * 24L * 60L * 60_000L, now),
        )
    }
}
