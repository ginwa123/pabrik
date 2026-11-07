package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

data class Col(val id: String, val pos: Int)
data class Card(val id: String, val col: String)

class KanbanBoardTest {

    @Test
    fun sortByPosition() {
        val cols = listOf(Col("c", 2), Col("a", 0), Col("b", 1))
        val sorted = KanbanBoard.sortByPosition(cols) { it.pos }
        assertEquals(listOf("a", "b", "c"), sorted.map { it.id })
    }

    @Test
    fun groupByColumn() {
        val cards = listOf(Card("1", "c1"), Card("2", "c2"), Card("3", "c1"))
        val grouped = KanbanBoard.groupByColumn(cards) { it.col }
        assertEquals(listOf("1", "3"), grouped["c1"]?.map { it.id })
        assertEquals(listOf("2"), grouped["c2"]?.map { it.id })
    }

    @Test
    fun countByColumn() {
        val cards = listOf(Card("1", "c1"), Card("2", "c2"), Card("3", "c1"))
        val counts = KanbanBoard.countByColumn(cards) { it.col }
        assertEquals(2, counts["c1"])
        assertEquals(1, counts["c2"])
    }

    @Test
    fun emptyInputs() {
        assertEquals(emptyList<Col>(), KanbanBoard.sortByPosition(emptyList<Col>()) { it.pos })
        assertTrue(KanbanBoard.groupByColumn(emptyList<Card>()) { it.col }.isEmpty())
    }
}
