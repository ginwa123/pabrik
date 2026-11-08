package com.pabrik.mobile.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PasswordChangeTest {

    @Test
    fun emptyNewPasswordShowsNoError() {
        assertNull(PasswordChange.newPasswordError("current", ""))
    }

    @Test
    fun newPasswordShorterThanTheMinimumIsRejected() {
        assertEquals("TooShort", PasswordChange.newPasswordError("current", "1234567"))
    }

    @Test
    fun newPasswordAtTheMinimumLengthIsAccepted() {
        assertNull(PasswordChange.newPasswordError("current", "12345678"))
    }

    @Test
    fun newPasswordLongerThanTheMaximumIsRejected() {
        assertEquals("TooLong", PasswordChange.newPasswordError("current", "a".repeat(73)))
    }

    @Test
    fun newPasswordAtTheMaximumLengthIsAccepted() {
        assertNull(PasswordChange.newPasswordError("current", "a".repeat(72)))
    }

    @Test
    fun reusingTheCurrentPasswordIsRejected() {
        assertEquals("Unchanged", PasswordChange.newPasswordError("samepass", "samepass"))
    }

    @Test
    fun mismatchedConfirmationIsReported() {
        assertEquals("Mismatch", PasswordChange.confirmError("newpass1", "newpass2"))
    }

    @Test
    fun emptyConfirmationShowsNoError() {
        assertNull(PasswordChange.confirmError("newpass1", ""))
    }

    @Test
    fun matchingConfirmationShowsNoError() {
        assertNull(PasswordChange.confirmError("newpass1", "newpass1"))
    }

    @Test
    fun submitIsAllowedWhenEveryFieldIsValid() {
        assertTrue(PasswordChange.canSubmit("current", "newpass1", "newpass1"))
    }

    @Test
    fun submitIsBlockedWithoutTheCurrentPassword() {
        assertFalse(PasswordChange.canSubmit("", "newpass1", "newpass1"))
    }

    @Test
    fun submitIsBlockedWhenTheNewPasswordIsTooShort() {
        assertFalse(PasswordChange.canSubmit("current", "short", "short"))
    }

    @Test
    fun submitIsBlockedWhenTheNewPasswordEqualsTheCurrentOne() {
        assertFalse(PasswordChange.canSubmit("samepass", "samepass", "samepass"))
    }

    @Test
    fun submitIsBlockedWhenTheConfirmationDiffers() {
        assertFalse(PasswordChange.canSubmit("current", "newpass1", "newpass2"))
    }

    @Test
    fun successNoteReportsNoOtherDeviceWhenNothingWasRevoked() {
        assertEquals(
            "Password changed. No other device was signed in.",
            PasswordChange.successNote(0),
        )
    }

    @Test
    fun successNoteUsesSingularForOneRevokedDevice() {
        assertEquals(
            "Password changed. One other device was signed out.",
            PasswordChange.successNote(1),
        )
    }

    @Test
    fun successNoteUsesPluralForSeveralRevokedDevices() {
        assertEquals(
            "Password changed. 3 other devices were signed out.",
            PasswordChange.successNote(3),
        )
    }
}
