package com.pabrik.mobile.recents

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.flow.distinctUntilChanged

/** How many rows from the end arm the next page. */
internal const val LOAD_MORE_INDEX_THRESHOLD = 2

/** What the paging trigger saw this frame, in the two words it acts on. */
internal data class ChatListPagingState(
    /** Every row the list has is on screen, so the list cannot scroll and the reader has no way to ask for the next page by hand. */
    val fitsViewport: Boolean,
    /** The last row is within [LOAD_MORE_INDEX_THRESHOLD] of the bottom. */
    val atEnd: Boolean,
    /** How many chat rows the list holds. */
    val rowCount: Int,
)

/** Read a `LazyListState`'s layout as the two questions the paging trigger asks. */
internal fun chatListPagingState(
    canPage: Boolean,
    totalItemsCount: Int,
    visibleItemCount: Int,
    lastVisibleIndex: Int,
    rowCount: Int,
    threshold: Int = LOAD_MORE_INDEX_THRESHOLD,
): ChatListPagingState {
    // Nothing to read.
    if (!canPage || totalItemsCount <= 0 || visibleItemCount <= 0) {
        return ChatListPagingState(
            fitsViewport = false,
            atEnd = false,
            rowCount = rowCount,
        )
    }

    // Every row is already on screen.
    val fitsViewport = totalItemsCount <= visibleItemCount

    return ChatListPagingState(
        fitsViewport = fitsViewport,
        // `false` while the list fits: there is no "bottom" left to approach, and [fitsViewport] is the honest answer for that screen.
        atEnd = !fitsViewport && lastVisibleIndex >= totalItemsCount - 1 - threshold,
        rowCount = rowCount,
    )
}

/** Ask for the next page of a chat list when the reader has run out of things they can do about it. */
@Composable
internal fun ChatListLoadMoreTrigger(
    listState: LazyListState,
    canPage: Boolean,
    rowCount: Int,
    onLoadMore: () -> Unit,
) {
    // Deliberately separate latches, and deliberately not shared between the two screens: one flag driving two scrollers would let a list that fits the screen here …
    var atEndLatched by remember { mutableStateOf(false) }
    var atEndLatchedRowCount by remember { mutableIntStateOf(0) }
    var filledToRowCount by remember { mutableIntStateOf(-1) }

    // Keyed on the row count as well as on `canPage` so a page that lands restarts the observer and is re-read: a longer list is a different list, and whether it …
    LaunchedEffect(listState, canPage, rowCount) {
        snapshotFlow {
            val info = listState.layoutInfo
            chatListPagingState(
                canPage = canPage,
                totalItemsCount = info.totalItemsCount,
                visibleItemCount = info.visibleItemsInfo.size,
                lastVisibleIndex = info.visibleItemsInfo.lastOrNull()?.index ?: -1,
                rowCount = rowCount,
            )
        }
            .distinctUntilChanged()
            .collect { paging ->
                if (!paging.atEnd) {
                    atEndLatched = false
                } else if (!atEndLatched || atEndLatchedRowCount != paging.rowCount) {
                    atEndLatched = true
                    atEndLatchedRowCount = paging.rowCount
                    onLoadMore()
                }

                if (paging.fitsViewport && paging.rowCount != filledToRowCount) {
                    filledToRowCount = paging.rowCount
                    onLoadMore()
                }
            }
    }
}
