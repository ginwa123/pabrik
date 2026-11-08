package com.pabrik.mobile.projects

// Skills CRUD helpers. Pure logic so they are unit-testable without a
// ViewModel or a network.
object SkillsCrud {

    // Whether a skill can be deleted (not locked).
    fun canDelete(locked: Boolean): Boolean = !locked

    // Whether a skill can be edited (not locked).
    fun canEdit(locked: Boolean): Boolean = !locked

    // Whether skill content is valid (non-empty).
    fun isValidContent(content: String): Boolean = content.trim().isNotEmpty()
}
