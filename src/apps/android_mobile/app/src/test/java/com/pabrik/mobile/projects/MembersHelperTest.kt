package com.pabrik.mobile.projects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MembersHelperTest {

    @Test
    fun validEmail() {
        assertTrue(MembersHelper.isValidEmail("a@b.com"))
        assertFalse(MembersHelper.isValidEmail("notanemail"))
        assertFalse(MembersHelper.isValidEmail(""))
    }

    @Test
    fun isDuplicate() {
        assertTrue(MembersHelper.isDuplicate("a@b.com", listOf("A@B.COM", "other")))
        assertFalse(MembersHelper.isDuplicate("new@b.com", listOf("A@B.COM", "other")))
    }

    @Test
    fun validateInviteSuccess() {
        assertEquals(null, MembersHelper.validateInvite("new@b.com", listOf("a@b.com")))
    }

    @Test
    fun validateInviteInvalid() {
        assertEquals("InvalidEmail", MembersHelper.validateInvite("notanemail", listOf()))
    }

    @Test
    fun validateInviteDuplicate() {
        assertEquals("AlreadyMember", MembersHelper.validateInvite("a@b.com", listOf("A@B.COM")))
    }
}
