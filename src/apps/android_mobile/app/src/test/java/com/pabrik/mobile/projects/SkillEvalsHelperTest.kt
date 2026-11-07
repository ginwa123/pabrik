package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillEvalsHelperTest {

    @Test
    fun validName() {
        assertTrue(SkillEvalsHelper.isValidName("my-eval"))
        assertFalse(SkillEvalsHelper.isValidName(""))
        assertFalse(SkillEvalsHelper.isValidName("   "))
    }

    @Test
    fun isDuplicate() {
        assertTrue(SkillEvalsHelper.isDuplicate("eval", listOf("EVAL", "other")))
        assertFalse(SkillEvalsHelper.isDuplicate("new", listOf("EVAL", "other")))
    }

    @Test
    fun validateNewSuccess() {
        assertEquals(null, SkillEvalsHelper.validateNew("NEW_EVAL", listOf("OTHER")))
    }

    @Test
    fun validateNewEmpty() {
        assertEquals("NameRequired", SkillEvalsHelper.validateNew("", listOf()))
    }

    @Test
    fun validateNewDuplicate() {
        assertEquals("NameTaken", SkillEvalsHelper.validateNew("eval", listOf("EVAL")))
    }
}
