package com.pabrik.mobile.projects

// Kanban settings helpers. Pure logic so they are unit-testable without a
// ViewModel or a network.
object KanbanSettings {

    fun isValidColumnName(name: String): Boolean = name.trim().isNotEmpty()

    // Reorder columns by moving [from] to [to] (0-based indices). Returns new list.
    fun <T> moveColumn(columns: List<T>, from: Int, to: Int): List<T> {
        if (from !in columns.indices || to !in columns.indices || from == to) return columns
        val mutable = columns.toMutableList()
        val item = mutable.removeAt(from)
        mutable.add(to, item)
        return mutable
    }

    // Validate a profile name (non-empty).
    fun isValidProfileName(name: String): Boolean = name.trim().isNotEmpty()
}
