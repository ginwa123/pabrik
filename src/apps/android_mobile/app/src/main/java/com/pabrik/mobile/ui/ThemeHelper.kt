package com.pabrik.mobile.ui

// Theme helpers. Pure logic so they are unit-testable without a Composable.
object ThemeHelper {

    // Whether a scheme name is a dark scheme.
    fun isDarkScheme(scheme: String): Boolean = scheme == "dark"

    // Default theme id (matches Vue's default dark theme).
    fun defaultThemeId(): String = "dark"

    // Validate a theme id (non-empty).
    fun isValidThemeId(id: String): Boolean = id.trim().isNotEmpty()
}
