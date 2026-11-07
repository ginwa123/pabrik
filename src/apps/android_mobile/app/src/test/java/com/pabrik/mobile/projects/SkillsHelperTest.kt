package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillsHelperTest {

    @Test
    fun validName() {
        assertTrue(SkillsHelper.isValidName("my-skill"))
        assertFalse(SkillsHelper.isValidName(""))
        assertFalse(SkillsHelper.isValidName("   "))
    }

    @Test
    fun isDuplicate() {
        assertTrue(SkillsHelper.isDuplicate("skill", listOf("SKILL", "other")))
        assertFalse(SkillsHelper.isDuplicate("new", listOf("SKILL", "other")))
    }

    @Test
    fun validateNewSuccess() {
        assertEquals(null, SkillsHelper.validateNew("NEW_SKILL", listOf("OTHER")))
    }

    @Test
    fun validateNewEmpty() {
        assertEquals("NameRequired", SkillsHelper.validateNew("", listOf()))
    }

    @Test
    fun validateNewDuplicate() {
        assertEquals("NameTaken", SkillsHelper.validateNew("skill", listOf("SKILL")))
    }
}
