package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SecretsHelperTest {

    @Test
    fun validName() {
        assertTrue(SecretsHelper.isValidName("API_KEY"))
        assertFalse(SecretsHelper.isValidName(""))
        assertFalse(SecretsHelper.isValidName("   "))
    }

    @Test
    fun isDuplicate() {
        assertTrue(SecretsHelper.isDuplicate("key", listOf("KEY", "other")))
        assertFalse(SecretsHelper.isDuplicate("new", listOf("KEY", "other")))
    }

    @Test
    fun validateNewSuccess() {
        assertEquals(null, SecretsHelper.validateNew("NEW_KEY", listOf("OTHER")))
    }

    @Test
    fun validateNewEmpty() {
        assertEquals("NameRequired", SecretsHelper.validateNew("", listOf()))
    }

    @Test
    fun validateNewDuplicate() {
        assertEquals("NameTaken", SecretsHelper.validateNew("key", listOf("KEY")))
    }
}
