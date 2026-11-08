package com.pabrik.mobile.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MembersHelperTest {

    @Test
    fun ownerOutranksAdminOutranksEditorOutranksViewer() {
        assertTrue(MembersHelper.rank("owner") > MembersHelper.rank("admin"))
        assertTrue(MembersHelper.rank("admin") > MembersHelper.rank("editor"))
        assertTrue(MembersHelper.rank("editor") > MembersHelper.rank("viewer"))
    }

    @Test
    fun anUnknownRoleRanksBelowViewer() {
        assertTrue(MembersHelper.rank("ghost") < MembersHelper.rank("viewer"))
    }

    @Test
    fun ownersAndAdminsCanManage() {
        assertTrue(MembersHelper.canManage("owner"))
        assertTrue(MembersHelper.canManage("admin"))
    }

    @Test
    fun editorsAndViewersCannotManage() {
        assertFalse(MembersHelper.canManage("editor"))
        assertFalse(MembersHelper.canManage("viewer"))
    }

    @Test
    fun editorsAndAboveCanEdit() {
        assertTrue(MembersHelper.canEdit("editor"))
        assertTrue(MembersHelper.canEdit("admin"))
        assertTrue(MembersHelper.canEdit("owner"))
    }

    @Test
    fun viewersCannotEdit() {
        assertFalse(MembersHelper.canEdit("viewer"))
    }

    @Test
    fun aPlainAddressIsValid() {
        assertTrue(MembersHelper.isValidEmail("dev@example.com"))
    }

    @Test
    fun anAddressWithoutAnAtSignIsInvalid() {
        assertFalse(MembersHelper.isValidEmail("dev.example.com"))
    }

    @Test
    fun anAddressWithoutADomainDotIsInvalid() {
        assertFalse(MembersHelper.isValidEmail("dev@example"))
    }

    @Test
    fun anAddressWithSpacesIsInvalid() {
        assertFalse(MembersHelper.isValidEmail("dev @example.com"))
    }

    @Test
    fun anAddressWithTwoAtSignsIsInvalid() {
        assertFalse(MembersHelper.isValidEmail("dev@@example.com"))
    }

    @Test
    fun anUnansweredInvitationIsPending() {
        assertEquals("pending", MembersHelper.invitationStatus(accepted = false, declined = false))
    }

    @Test
    fun anAcceptedInvitationIsAccepted() {
        assertEquals("accepted", MembersHelper.invitationStatus(accepted = true, declined = false))
    }

    @Test
    fun aDeclinedInvitationIsDeclined() {
        assertEquals("declined", MembersHelper.invitationStatus(accepted = false, declined = true))
    }
}
