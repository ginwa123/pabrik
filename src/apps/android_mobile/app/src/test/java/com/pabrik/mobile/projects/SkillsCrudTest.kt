package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillsCrudTest {

    @Test
    fun canDelete() {
        assertTrue(SkillsCrud.canDelete(false))
        assertFalse(SkillsCrud.canDelete(true))
    }

    @Test
    fun canEdit() {
        assertTrue(SkillsCrud.canEdit(false))
        assertFalse(SkillsCrud.canEdit(true))
    }

    @Test
    fun isValidContent() {
        assertTrue(SkillsCrud.isValidContent("some content"))
        assertFalse(SkillsCrud.isValidContent(""))
        assertFalse(SkillsCrud.isValidContent("   "))
    }
}
