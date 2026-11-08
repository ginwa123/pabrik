package com.pabrik.mobile.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SecretsCrudHelperTest {

    @Test
    fun aHiddenValueIsMasked() {
        assertEquals(SecretsCrudHelper.MASK, SecretsCrudHelper.displayValue("s3cret", revealed = false))
    }

    @Test
    fun aRevealedValueIsShown() {
        assertEquals("s3cret", SecretsCrudHelper.displayValue("s3cret", revealed = true))
    }

    @Test
    fun anEmptyValueIsInvalid() {
        assertFalse(SecretsCrudHelper.isValidValue(""))
    }

    @Test
    fun aNonEmptyValueIsValid() {
        assertTrue(SecretsCrudHelper.isValidValue("x"))
    }

    @Test
    fun aDescriptionAtTheCapIsValid() {
        assertTrue(SecretsCrudHelper.isValidDescription("a".repeat(500)))
    }

    @Test
    fun aDescriptionOverTheCapIsInvalid() {
        assertFalse(SecretsCrudHelper.isValidDescription("a".repeat(501)))
    }

    @Test
    fun aShortDescriptionIsNotTruncated() {
        assertEquals("short", SecretsCrudHelper.truncateDescription("short"))
    }

    @Test
    fun aLongDescriptionIsTruncatedToTheCap() {
        assertEquals(500, SecretsCrudHelper.truncateDescription("a".repeat(600)).length)
    }

    @Test
    fun rotatingWithAnEmptyValueIsRejected() {
        assertEquals("ValueRequired", SecretsCrudHelper.rotateError(""))
    }

    @Test
    fun rotatingWithAValueIsAllowed() {
        assertNull(SecretsCrudHelper.rotateError("new-value"))
    }

    @Test
    fun aBlankDescriptionFallsBackToALabel() {
        assertEquals("No description", SecretsCrudHelper.describeLabel("   "))
    }

    @Test
    fun aPresentDescriptionIsShown() {
        assertEquals("Deploy token", SecretsCrudHelper.describeLabel("Deploy token"))
    }
}
