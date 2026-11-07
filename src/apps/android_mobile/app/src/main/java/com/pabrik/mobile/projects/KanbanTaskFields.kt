package com.pabrik.mobile.projects

// Kanban task field helpers. Pure logic so they are unit-testable without a
// ViewModel or a network.
object KanbanTaskFields {

    fun isValidTitle(title: String): Boolean = title.trim().isNotEmpty()

    // Parse a comma/space separated tag string into a trimmed, deduped list.
    fun parseTags(raw: String): List<String> =
        raw.split(',', ' ')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()

    // Join tags back into a comma-separated string.
    fun joinTags(tags: List<String>): String = tags.joinToString(", ")

    // Validate a PR link (must be http/https URL or empty).
    fun isValidPrLink(link: String): Boolean =
        link.isEmpty() || link.startsWith("http://") || link.startsWith("https://")
}
