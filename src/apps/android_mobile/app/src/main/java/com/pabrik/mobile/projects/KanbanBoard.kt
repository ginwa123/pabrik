package com.pabrik.mobile.projects

// Kanban board helpers. Pure logic so they are unit-testable without a
// ViewModel or a network.
object KanbanBoard {

    // Sort columns by their position field ascending.
    fun <T> sortByPosition(items: List<T>, positionOf: (T) -> Int): List<T> =
        items.sortedBy { positionOf(it) }

    // Group cards by column id, preserving card order within each column.
    fun <T> groupByColumn(cards: List<T>, columnIdOf: (T) -> String): Map<String, List<T>> =
        cards.groupBy { columnIdOf(it) }

    // Count cards per column.
    fun <T> countByColumn(cards: List<T>, columnIdOf: (T) -> String): Map<String, Int> =
        cards.groupingBy { columnIdOf(it) }.eachCount()
}
