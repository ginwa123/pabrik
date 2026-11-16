package com.pabrik.mobile.testing

import com.pabrik.mobile.storage.SealingCipher
import java.util.Base64

/** A cipher that is obviously not encryption, so a test can tell "this value went through the cipher" from "this value was passed through" without claiming to … */
object Base64CacheCipher : SealingCipher {
    override fun seal(plainText: String): String =
        Base64.getEncoder().encodeToString(plainText.toByteArray(Charsets.UTF_8))

    override fun open(sealed: String): String? = try {
        String(Base64.getDecoder().decode(sealed), Charsets.UTF_8)
    } catch (_: IllegalArgumentException) {
        null
    }
}
