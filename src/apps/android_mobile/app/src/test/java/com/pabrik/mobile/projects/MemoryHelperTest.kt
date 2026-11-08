package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MemoryHelperTest {

    @Test
    fun validName() {
        assertTrue(MemoryHelper.isValidName("my-memory"))
        assertFalse(MemoryHelper.isValidName(""))
        assertFalse(MemoryHelper.isValidName("   "))
    }

    @Test
    fun isDuplicate() {
        assertTrue(MemoryHelper.isDuplicate("mem", listOf("MEM", "other")))
        assertFalse(MemoryHelper.isDuplicate("new", listOf("MEM", "other")))
    }

    @Test
    fun validateNewSuccess() {
        assertEquals(null, MemoryHelper.validateNew("NEW_MEM", listOf("OTHER")))
    }

    @Test
    fun validateNewEmpty() {
        assertEquals("NameRequired", MemoryHelper.validateNew("", listOf()))
    }

    @Test
    fun validateNewDuplicate() {
        assertEquals("NameTaken", MemoryHelper.validateNew("mem", listOf("MEM")))
    }
}
