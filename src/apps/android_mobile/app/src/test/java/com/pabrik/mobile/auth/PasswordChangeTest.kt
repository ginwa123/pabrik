package com.pabrik.mobile.auth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PasswordChangeTest {

    @Test
    fun validLength() {
        assertTrue(PasswordChange.isValidLength("12345678"))
        assertTrue(PasswordChange.isValidLength("a".repeat(72)))
        assertFalse(PasswordChange.isValidLength("short"))
        assertFalse(PasswordChange.isValidLength("a".repeat(73)))
    }

    @Test
    fun unchanged() {
        assertTrue(PasswordChange.isUnchanged("abc", "abc"))
        assertFalse(PasswordChange.isUnchanged("abc", "def"))
    }

    @Test
    fun validateSuccess() {
        assertEquals(null, PasswordChange.validate("oldpass1", "newpass1"))
    }

    @Test
    fun validateTooShort() {
        assertEquals("PasswordTooShort", PasswordChange.validate("oldpass1", "short"))
    }

    @Test
    fun validateTooLong() {
        assertEquals("PasswordTooLong", PasswordChange.validate("oldpass1", "a".repeat(73)))
    }

    @Test
    fun validateUnchanged() {
        assertEquals("PasswordUnchanged", PasswordChange.validate("samepass", "samepass"))
    }
}
