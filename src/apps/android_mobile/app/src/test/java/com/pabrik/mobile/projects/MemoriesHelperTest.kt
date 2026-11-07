package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MemoriesHelperTest {

    @Test
    fun validName() {
        assertTrue(MemoriesHelper.isValidName("my-memory"))
        assertFalse(MemoriesHelper.isValidName(""))
        assertFalse(MemoriesHelper.isValidName("   "))
    }

    @Test
    fun isDuplicate() {
        assertTrue(MemoriesHelper.isDuplicate("mem", listOf("MEM", "other")))
        assertFalse(MemoriesHelper.isDuplicate("new", listOf("MEM", "other")))
    }

    @Test
    fun validateNewSuccess() {
        assertEquals(null, MemoriesHelper.validateNew("NEW_MEM", listOf("OTHER")))
    }

    @Test
    fun validateNewEmpty() {
        assertEquals("NameRequired", MemoriesHelper.validateNew("", listOf()))
    }

    @Test
    fun validateNewDuplicate() {
        assertEquals("NameTaken", MemoriesHelper.validateNew("mem", listOf("MEM")))
    }
}
