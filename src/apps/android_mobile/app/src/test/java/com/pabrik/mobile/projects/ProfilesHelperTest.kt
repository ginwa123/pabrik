package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfilesHelperTest {

    @Test
    fun validName() {
        assertTrue(ProfilesHelper.isValidName("gpt-4"))
        assertFalse(ProfilesHelper.isValidName(""))
        assertFalse(ProfilesHelper.isValidName("   "))
    }

    @Test
    fun isDuplicate() {
        assertTrue(ProfilesHelper.isDuplicate("profile", listOf("PROFILE", "other")))
        assertFalse(ProfilesHelper.isDuplicate("new", listOf("PROFILE", "other")))
    }

    @Test
    fun validateNewSuccess() {
        assertEquals(null, ProfilesHelper.validateNew("NEW_PROFILE", listOf("OTHER")))
    }

    @Test
    fun validateNewEmpty() {
        assertEquals("NameRequired", ProfilesHelper.validateNew("", listOf()))
    }

    @Test
    fun validateNewDuplicate() {
        assertEquals("NameTaken", ProfilesHelper.validateNew("profile", listOf("PROFILE")))
    }
}
