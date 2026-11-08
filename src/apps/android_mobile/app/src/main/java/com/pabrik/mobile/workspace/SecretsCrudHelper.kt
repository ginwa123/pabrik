package com.pabrik.mobile.workspace

object SecretsCrudHelper {
    const val MAX_DESCRIPTION_LEN = 500
    const val MASK = "********"

    fun displayValue(value: String, revealed: Boolean): String =
        if (revealed) value else MASK

    fun isValidValue(value: String): Boolean = value.isNotEmpty()

    fun isValidDescription(description: String): Boolean =
        description.length <= MAX_DESCRIPTION_LEN

    fun truncateDescription(description: String): String =
        if (description.length <= MAX_DESCRIPTION_LEN) description else description.take(MAX_DESCRIPTION_LEN)

    fun rotateError(value: String): String? =
        if (value.isEmpty()) "ValueRequired" else null

    fun describeLabel(description: String): String =
        description.trim().ifEmpty { "No description" }
}
