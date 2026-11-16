package com.pabrik.mobile.storage

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** AES-GCM under a key held by the Android Keystore, so the key material never exists in the app's process address space. */
interface SealingCipher {
    /** Null when the value could not be sealed; the caller should not store it. */
    fun seal(plainText: String): String?

    /** Null when the value is not one this cipher wrote. */
    fun open(sealed: String): String?
}

class KeystoreSealingCipher(private val keyAlias: String) : SealingCipher {

    @Volatile
    private var key: SecretKey? = null

    override fun seal(plainText: String): String? = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(plainText.toByteArray(StandardCharsets.UTF_8))
        listOf(
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
            Base64.encodeToString(encrypted, Base64.NO_WRAP),
        ).joinToString(PAYLOAD_SEPARATOR)
    } catch (_: Exception) {
        null
    }

    override fun open(sealed: String): String? = try {
        val parts = sealed.split(PAYLOAD_SEPARATOR, limit = 2)
        if (parts.size != SEALED_PARTS) {
            null
        } else {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                key(),
                GCMParameterSpec(GCM_TAG_LENGTH_BITS, Base64.decode(parts[0], Base64.NO_WRAP)),
            )
            String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), StandardCharsets.UTF_8)
        }
    } catch (_: Exception) {
        null
    }

    private fun key(): SecretKey = key ?: synchronized(this) {
        key ?: loadOrCreateKey().also { key = it }
    }

    private fun loadOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = keyStore.getKey(keyAlias, null) as? SecretKey
        if (existing != null) return existing

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val PAYLOAD_SEPARATOR = ":"
        const val SEALED_PARTS = 2
        const val GCM_TAG_LENGTH_BITS = 128
    }
}
