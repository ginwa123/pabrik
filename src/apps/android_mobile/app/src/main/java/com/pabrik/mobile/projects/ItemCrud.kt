package com.pabrik.mobile.projects

// Optimistic item CRUD helpers. Pure functions, unit-testable without a
// ViewModel or a network.
object ItemCrud {

    // Remove [itemId] from [items] optimistically. Returns the new list and
    // the removed item (or null if not found) so the caller can restore it.
    fun <T : Any> remove(items: List<T>, idOf: (T) -> String, itemId: String): Pair<List<T>, T?> {
        val idx = items.indexOfFirst { idOf(it) == itemId }
        if (idx < 0) return items to null
        val removed = items[idx]
        val next = items.toMutableList().apply { removeAt(idx) }
        return next to removed
    }

    // Restore [removed] into [items] at its original position (end if unknown).
    fun <T : Any> restore(items: List<T>, removed: T?, idOf: (T) -> String): List<T> {
        if (removed == null) return items
        if (items.any { idOf(it) == idOf(removed) }) return items
        return items + removed
    }

    // Rename [itemId] to [newName] optimistically. Returns new list.
    fun <T> rename(items: List<T>, idOf: (T) -> String, itemId: String, newName: String, nameSetter: (T, String) -> T): List<T> {
        return items.map { item ->
            if (idOf(item) == itemId) nameSetter(item, newName) else item
        }
    }
}
