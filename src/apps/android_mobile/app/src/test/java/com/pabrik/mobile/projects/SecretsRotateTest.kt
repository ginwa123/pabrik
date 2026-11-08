package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SecretsRotateTest {

    @Test
    fun isValidValue() {
        assertTrue(SecretsRotate.isValidValue("secret"))
        assertFalse(SecretsRotate.isValidValue(""))
    }

    @Test
    fun isChanged() {
        assertTrue(SecretsRotate.isChanged("old", "new"))
        assertFalse(SecretsRotate.isChanged("same", "same"))
    }

    @Test
    fun validateRotateSuccess() {
        assertEquals(null, SecretsRotate.validateRotate("old", "new"))
    }

    @Test
    fun validateRotateEmpty() {
        assertEquals("ValueRequired", SecretsRotate.validateRotate("old", ""))
    }

    @Test
    fun validateRotateUnchanged() {
        assertEquals("ValueUnchanged", SecretsRotate.validateRotate("same", "same"))
    }
}
