package com.pabrik.mobile.recents

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The arithmetic behind both paged chat screens' "ask for the next page". */
class ChatListPagingTest {

    /** What a `LazyColumn` reports for the screen this screen opens on: the drawer's five-row preview, plus the footer row. */
    @Test
    fun aListShorterThanTheScreenIsReportedAsUnscrollableRatherThanAsAnEnd() {
        val paging = chatListPagingState(
            canPage = true,
            totalItemsCount = 6,
            visibleItemCount = 6,
            lastVisibleIndex = 5,
            rowCount = 5,
        )

        assertTrue("everything fits, so there is no scroll to make", paging.fitsViewport)
        assertFalse(
            "a list with no overflow has no end left to approach",
            paging.atEnd,
        )
    }

    @Test
    fun anUnscrollableListAndAnApproachedEndAreNeverBothTrue() {
        // The two answers drive two separate latches, so a list claiming both would be counted twice for one position.
        val cases = listOf(
            Triple(6, 6, 5),
            Triple(6, 6, 0),
            Triple(101, 20, 98),
            Triple(101, 20, 19),
            Triple(1, 1, 0),
        )

        for ((total, visible, last) in cases) {
            val paging = chatListPagingState(
                canPage = true,
                totalItemsCount = total,
                visibleItemCount = visible,
                lastVisibleIndex = last,
                rowCount = total,
            )
            assertFalse(
                "total=$total visible=$visible last=$last claimed both",
                paging.fitsViewport && paging.atEnd,
            )
        }
    }

    @Test
    fun aListThatOverflowsTheScreenOnlyArmsNearItsLastRows() {
        // 101 rows in a viewport of 20.
        val atTop = chatListPagingState(
            canPage = true,
            totalItemsCount = 101,
            visibleItemCount = 20,
            lastVisibleIndex = 19,
            rowCount = 100,
        )
        val twoFromTheEnd = chatListPagingState(
            canPage = true,
            totalItemsCount = 101,
            visibleItemCount = 20,
            lastVisibleIndex = 97,
            rowCount = 100,
        )
        val onTheEnd = chatListPagingState(
            canPage = true,
            totalItemsCount = 101,
            visibleItemCount = 20,
            lastVisibleIndex = 98,
            rowCount = 100,
        )

        assertFalse(atTop.atEnd)
        assertFalse(twoFromTheEnd.atEnd)
        assertTrue(onTheEnd.atEnd)
        assertFalse(atTop.fitsViewport)
    }

    @Test
    fun aListThatCannotPageDisarmsEveryReason() {
        // `canPage` is in the *condition*, not only in the effect's key, so a list that stops being pageable disarms an already-armed trigger.
        val unlaidOut = chatListPagingState(
            canPage = true,
            totalItemsCount = 0,
            visibleItemCount = 0,
            lastVisibleIndex = -1,
            rowCount = 0,
        )
        val nothingLeft = chatListPagingState(
            canPage = false,
            totalItemsCount = 6,
            visibleItemCount = 6,
            lastVisibleIndex = 5,
            rowCount = 5,
        )
        val pageInFlight = chatListPagingState(
            canPage = false,
            totalItemsCount = 101,
            visibleItemCount = 20,
            lastVisibleIndex = 98,
            rowCount = 100,
        )

        for (paging in listOf(unlaidOut, nothingLeft, pageInFlight)) {
            assertFalse(paging.fitsViewport)
            assertFalse(paging.atEnd)
        }
    }

    @Test
    fun anEmptyScreenReportsItAsUnscrollableAndNeverAsAnApproachedEnd() {
        // An empty list holds one placeholder row at index 0, which is inside any band.
        val paging = chatListPagingState(
            canPage = true,
            totalItemsCount = 1,
            visibleItemCount = 1,
            lastVisibleIndex = 0,
            rowCount = 0,
        )

        assertTrue(paging.fitsViewport)
        assertFalse(paging.atEnd)
    }

    @Test
    fun theRowCountTravelsWithTheAnswer() {
        // It is what tells "the reader is still parked at the end of the list they already paged" from "the list has grown under them" — the second is a new end, and a …
        val before = chatListPagingState(
            canPage = true,
            totalItemsCount = 6,
            visibleItemCount = 6,
            lastVisibleIndex = 5,
            rowCount = 5,
        )
        val after = chatListPagingState(
            canPage = true,
            totalItemsCount = 6,
            visibleItemCount = 6,
            lastVisibleIndex = 5,
            rowCount = 25,
        )

        assertEquals(5, before.rowCount)
        assertEquals(25, after.rowCount)
    }
}
