package com.pabrik.mobile.chat

import java.util.Base64

/** One image the reader has attached to the turn they are composing. */
data class ChatAttachment(
    val id: String,
    val mimeType: String,
    /** Size of the *encoded payload*, which is what the cap is measured in. */
    val byteCount: Int,
    val dataUrl: String,
) {
    /** The base64 payload on its own, for a thumbnail that wants pixels rather than a data URL. */
    val base64: String get() = dataUrl.substringAfter(";base64,", dataUrl)
}

/** The rules a picked image has to satisfy, and the arithmetic behind them. */
object ChatAttachments {
    /** The server's own cap, on the *joined* `image_urls` string. */
    const val MAX_TOTAL_BYTES: Int = 10 * 1024 * 1024

    /** Longest edge, in pixels, of a downscaled attachment. */
    const val MAX_EDGE_PX: Int = 1280

    /** JPEG quality for the re-encode. 82 is the point where text in a screenshot is still crisp and the file has roughly halved twice over. */
    const val JPEG_QUALITY: Int = 82

    /** How many images one turn may carry. */
    const val MAX_COUNT: Int = 4

    /** The data URL for encoded bytes. The shape `image_urls` is defined as. */
    fun dataUrl(mimeType: String, bytes: ByteArray): String =
        "data:$mimeType;base64," + Base64.getEncoder().encodeToString(bytes)

    /** The joined `image_urls` value, in one place so the separator lives once. */
    fun dataUrls(attachments: List<ChatAttachment>): List<String> =
        attachments.map { it.dataUrl }

    /** What [MAX_TOTAL_BYTES] is measured against. */
    fun totalBytes(attachments: List<ChatAttachment>): Int =
        attachments.sumOf { it.byteCount }

    /** True when one more image of [byteCount] bytes still fits on this turn. */
    fun fitsBudget(attachments: List<ChatAttachment>, byteCount: Int): Boolean =
        attachments.size < MAX_COUNT && totalBytes(attachments) + byteCount <= MAX_TOTAL_BYTES

    /** Why an attachment was refused, or `null` when it was not. */
    fun rejection(attachments: List<ChatAttachment>, byteCount: Int): String? = when {
        attachments.size >= MAX_COUNT ->
            "Up to $MAX_COUNT images per message. Remove one to attach another."

        totalBytes(attachments) + byteCount > MAX_TOTAL_BYTES ->
            "Images are limited to ${MAX_TOTAL_BYTES / (1024 * 1024)} MB per message. " +
                "Remove one to make room."

        else -> null
    }

    /** The payload length [dataUrl] will produce for [bytes] — the number the cap is actually checked against. */
    fun encodedLength(bytes: Int): Int = 4 * ((bytes + 2) / 3)

    /** A content type to store the bytes as. */
    const val STORED_MIME: String = "image/jpeg"
}
