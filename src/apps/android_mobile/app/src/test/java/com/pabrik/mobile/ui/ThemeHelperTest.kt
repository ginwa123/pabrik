package com.pabrik.mobile.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ThemeHelperTest {

    @Test
    fun isDarkScheme() {
        assertTrue(ThemeHelper.isDarkScheme("dark"))
        assertFalse(ThemeHelper.isDarkScheme("light"))
    }

    @Test
    fun defaultThemeId() {
        assertEquals("dark", ThemeHelper.defaultThemeId())
    }

    @Test
    fun isValidThemeId() {
        assertTrue(ThemeHelper.isValidThemeId("dark"))
        assertFalse(ThemeHelper.isValidThemeId(""))
        assertFalse(ThemeHelper.isValidThemeId("   "))
    }
}
