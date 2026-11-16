package com.pabrik.mobile.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The attachment rules, without a device. */
class ChatAttachmentsTest {

    // --- The data URL shape the backend validates ---------------------------

    @Test
    fun aDataUrlIsTheShapeImageUrlsIsDefinedAs() {
        val url = ChatAttachments.dataUrl("image/jpeg", byteArrayOf(1, 2, 3, 4))

        // The three parts `validateImageUrls` looks for, in order: the `data:image/` prefix, a non-empty MIME, a `;base64,` separator and a non-empty payload.
        assertTrue(url, url.startsWith("data:image/"))
        assertTrue(url, url.contains(";base64,"))
        assertTrue(url, url.substringAfter(";base64,").isNotEmpty())
        assertEquals("data:image/jpeg;base64,AQIDBA==", url)
    }

    @Test
    fun anEncodedPayloadContainsNoPipe() {
        // `image_urls` is joined on `|` and split on `|`, so a payload holding a pipe would be silently cut in half by the server.
        val bytes = ByteArray(512) { (it * 7).toByte() }
        val url = ChatAttachments.dataUrl("image/jpeg", bytes)

        assertFalse(url, url.contains("|"))
    }

    @Test
    fun base64RecoversThePayloadOnItsOwn() {
        val bytes = byteArrayOf(9, 8, 7, 6, 5)
        val attachment = ChatAttachment(
            id = "a1",
            mimeType = "image/jpeg",
            byteCount = bytes.size,
            dataUrl = ChatAttachments.dataUrl("image/jpeg", bytes),
        )

        assertEquals("CQgHBgU=", attachment.base64)
    }

    // --- The encoded length, which is what the cap is measured in -----------

    @Test
    fun theEncodedLengthIsNotTheRawLength() {
        // Base64 emits four characters per three bytes.
        assertEquals(4, ChatAttachments.encodedLength(1))
        assertEquals(4, ChatAttachments.encodedLength(3))
        assertEquals(8, ChatAttachments.encodedLength(4))
        assertEquals(8, ChatAttachments.encodedLength(6))
        assertEquals(12, ChatAttachments.encodedLength(7))
    }

    @Test
    fun theEncodedLengthMatchesWhatTheEncoderActuallyProduces() {
        for (size in listOf(1, 2, 3, 4, 5, 100, 1000)) {
            val bytes = ByteArray(size) { 1 }
            val url = ChatAttachments.dataUrl("image/jpeg", bytes)
            assertEquals(
                "size $size",
                ChatAttachments.encodedLength(size),
                url.length - "data:image/jpeg;base64,".length,
            )
        }
    }

    // --- The budget ---------------------------------------------------------

    @Test
    fun theBudgetIsTheServersOwnCap() {
        // `MAX_IMAGE_URLS_BYTES` in src/http_handlers/image_urls_validation.zig.
        assertEquals(10 * 1024 * 1024, ChatAttachments.MAX_TOTAL_BYTES)
    }

    @Test
    fun aTurnWithinBudgetAcceptsOneMoreImage() {
        val existing = attachment("a1", 1_000)

        assertTrue(ChatAttachments.fitsBudget(listOf(existing), 2_000))
        assertNull(ChatAttachments.rejection(listOf(existing), 2_000))
    }

    @Test
    fun theImageThatWouldCrossTheCapIsTheOneRefused() {
        val existing = attachment("a1", ChatAttachments.MAX_TOTAL_BYTES - 1_000)

        assertFalse(ChatAttachments.fitsBudget(listOf(existing), 2_000))
        val reason = ChatAttachments.rejection(listOf(existing), 2_000)
        assertTrue(reason, reason != null && reason.contains("MB"))
    }

    @Test
    fun theCapAllowsAPayloadExactlyOnIt() {
        // `validateImageUrls` rejects on `> MAX`, not `>=`.
        val existing = attachment("a1", ChatAttachments.MAX_TOTAL_BYTES - 1_000)

        assertTrue(ChatAttachments.fitsBudget(listOf(existing), 1_000))
    }

    @Test
    fun theCountIsCappedSeparatelyFromTheSize() {
        val full = (1..ChatAttachments.MAX_COUNT).map { attachment("a$it", 1_000) }

        // Four small images still leave room, so the refusal has to be about the count — a reader who is told "too big" for a 200 KB screenshot is told something false.
        assertFalse(ChatAttachments.fitsBudget(full, 1_000))
        val reason = ChatAttachments.rejection(full, 1_000)
        assertTrue(reason, reason != null && reason.contains("Up to"))
    }

    @Test
    fun theTotalIsTheSumOfTheEncodedPayloads() {
        val attachments = listOf(attachment("a1", 100), attachment("a2", 250), attachment("a3", 7))

        assertEquals(357, ChatAttachments.totalBytes(attachments))
    }

    // --- What goes on the wire ---------------------------------------------

    @Test
    fun theWireListIsTheDataUrlsInOrder() {
        val attachments = listOf(
            attachment("a1", 3),
            attachment("a2", 3),
        )

        assertEquals(attachments.map { it.dataUrl }, ChatAttachments.dataUrls(attachments))
    }

    @Test
    fun anEmptyTurnSendsNoImagesRatherThanAnEmptyEntry() {
        // `image_urls` is joined with `|`.
        assertEquals(emptyList<String>(), ChatAttachments.dataUrls(emptyList()))
    }

    private fun attachment(id: String, byteCount: Int) = ChatAttachment(
        id = id,
        mimeType = ChatAttachments.STORED_MIME,
        byteCount = byteCount,
        dataUrl = ChatAttachments.dataUrl(
            ChatAttachments.STORED_MIME,
            ByteArray(byteCount) { 1 },
        ),
    )
}
