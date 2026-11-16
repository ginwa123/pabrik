package com.pabrik.mobile.http

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException

/** [BinaryHttpResponseSpec]'s own equality, and the one thing about it that is easy to get wrong. */
class BinaryHttpResponseSpecTest {

    /** `data class` + `ByteArray` gives you an `equals` that compares the array by *identity*, so a fake returning a freshly-decoded body never equals an expected … */
    @Test
    fun `two specs with equal bytes are equal`() {
        val first = BinaryHttpResponseSpec(200, "image/png", byteArrayOf(1, 2, 3))
        val second = BinaryHttpResponseSpec(200, "image/png", byteArrayOf(1, 2, 3))
        assertEquals(first, second)
        assertEquals(first.hashCode(), second.hashCode())
    }

    @Test
    fun `different bytes are not equal`() {
        val first = BinaryHttpResponseSpec(200, "image/png", byteArrayOf(1, 2, 3))
        val second = BinaryHttpResponseSpec(200, "image/png", byteArrayOf(1, 2, 4))
        assertTrue(first != second)
    }

    @Test
    fun `a different status is not equal`() {
        assertTrue(
            BinaryHttpResponseSpec(200, "text/plain", byteArrayOf(1)) !=
                BinaryHttpResponseSpec(404, "text/plain", byteArrayOf(1)),
        )
    }

    @Test
    fun `a default spec is a 200 with no body`() {
        val spec = BinaryHttpResponseSpec(200)
        assertEquals(200, spec.statusCode)
        assertEquals("", spec.contentType)
        assertEquals(0, spec.body.size)
    }
}

/** The capped read behind every binary fetch. */
class ReadBytesCappedTest {

    @Test
    fun `bytes come back verbatim, not utf-8 decoded`() {
        // A PNG header plus bytes that are invalid UTF-8.
        val png = byteArrayOf(
            0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0xFF.toByte(), 0xFE.toByte(), 0x7F,
        )
        assertTrue(ByteArrayInputStream(png).readBytesCapped(1024).contentEquals(png))
    }

    @Test
    fun `a stream exactly at the cap is allowed`() {
        val bytes = ByteArray(8) { 7 }
        assertEquals(8, ByteArrayInputStream(bytes).readBytesCapped(8).size)
    }

    @Test
    fun `a stream one byte over the cap is refused`() {
        try {
            ByteArrayInputStream(ByteArray(9) { 7 }).readBytesCapped(8)
            fail("a 9-byte body under an 8-byte cap must not read")
        } catch (expected: IOException) {
            assertTrue(expected.message!!.contains("8"))
        }
    }

    @Test
    fun `a body spanning many chunks is assembled whole`() {
        val bytes = ByteArray(READ_CHUNK_BYTES_FOR_TEST * 3 + 11) { (it % 251).toByte() }
        assertTrue(ByteArrayInputStream(bytes).readBytesCapped(bytes.size).contentEquals(bytes))
    }

    @Test
    fun `a null stream reads as empty, matching the json exchange`() {
        val nothing: java.io.InputStream? = null
        assertEquals(0, nothing.readBytesCapped(1024).size)
    }

    private companion object {
        /** A third of the 16 KiB read buffer, so three reads plus a partial. */
        const val READ_CHUNK_BYTES_FOR_TEST = 5_000
    }
}
