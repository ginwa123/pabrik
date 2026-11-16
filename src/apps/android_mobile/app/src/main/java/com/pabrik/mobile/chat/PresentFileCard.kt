package com.pabrik.mobile.chat

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.auth.SessionCookieStore
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikCard
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikError
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What the card currently has to show for one file. */
internal sealed interface FilePreviewState {
    data object Loading : FilePreviewState
    data class Image(val bitmap: ImageBitmap) : FilePreviewState
    data class Text(val text: String, val truncated: Boolean) : FilePreviewState
    data class Failed(val message: String) : FilePreviewState
    data object NotApplicable : FilePreviewState
}

/** One presented file: its name, its size, and — the point of the card — an actual look at it. */
@Composable
internal fun PresentFileCard(
    file: ToolBody.PresentedFile,
    sessionId: String,
    modifier: Modifier = Modifier,
    // Nullable rather than defaulted, so a test can hand in a fake and the real path stays a decision made once, in the body, off `LocalContext` — not in a default …
    fileClient: FileClient? = null,
    opener: ExternalFileOpener? = null,
) {
    val context = LocalContext.current
    val client = fileClient ?: rememberFileClient(context)
    val externalOpener = opener ?: remember(context, client) { ExternalFileOpener(context, client) }
    val kind = remember(file.path, file.mime) { PresentFiles.kindOf(file.path, file.mime) }
    val displayName = remember(file.label, file.path) {
        PresentFiles.displayName(file.label, file.path)
    }

    var state by remember(file.path, kind) { mutableStateOf<FilePreviewState>(FilePreviewState.Loading) }
    var notice by remember(file.path) { mutableStateOf<String?>(null) }
    var isOpening by remember(file.path) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    // One effect owns every transition this card can make, so no two of them can race: the fetch, the image decode and the UTF-8 decode all happen here and nowhere …
    LaunchedEffect(file.path, kind, sessionId) {
        if (kind == PresentFileKind.EXTERNAL) {
            state = FilePreviewState.NotApplicable
            return@LaunchedEffect
        }
        if (PresentFiles.isTooLargeToPreviewInline(file.bytes)) {
            state = FilePreviewState.Failed(
                "Too big to preview here (${formatBytes(file.bytes)}) — tap Open to save it first.",
            )
            return@LaunchedEffect
        }
        state = FilePreviewState.Loading
        state = when (val result = withContext(Dispatchers.IO) { client.fetch(sessionId, file.path) }) {
            is FileFetchResult.Loaded -> when (kind) {
                PresentFileKind.IMAGE -> {
                    // `Default`, not `IO`: this is CPU-bound work — a 4 MB screenshot decoded on the main thread is the dropped frame the reader feels as the list stuttering.
                    val bitmap = withContext(Dispatchers.Default) {
                        BitmapFactory.decodeByteArray(result.bytes, 0, result.bytes.size)
                            ?.asImageBitmap()
                    }
                    if (bitmap == null) {
                        FilePreviewState.Failed("That image could not be decoded.")
                    } else {
                        FilePreviewState.Image(bitmap)
                    }
                }

                PresentFileKind.MARKDOWN, PresentFileKind.CODE, PresentFileKind.TEXT -> {
                    // Same reasoning as the image above: a half-megabyte String(...) is main-thread work if it happens on one.
                    val decoded = withContext(Dispatchers.Default) {
                        PresentFiles.decodeText(result.bytes)
                    }
                    FilePreviewState.Text(decoded.text, decoded.truncated)
                }

                PresentFileKind.EXTERNAL -> FilePreviewState.NotApplicable
            }

            is FileFetchResult.SignedOut -> FilePreviewState.Failed("Sign in again to see this file.")
            is FileFetchResult.Rejected -> FilePreviewState.Failed(result.message)
            is FileFetchResult.Unavailable -> FilePreviewState.Failed(result.message)
        }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(PabrikCard)
            .border(1.dp, PabrikBorder, RoundedCornerShape(6.dp))
            .testTag("present_file_row"),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 8.dp, end = 4.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = displayName,
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.Medium,
                    color = PabrikText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = fileMeta(file),
                    style = MaterialTheme.typography.labelSmall,
                    color = PabrikDim,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(6.dp))
            TextButton(
                onClick = {
                    if (isOpening) return@TextButton
                    isOpening = true
                    notice = null
                    scope.launch {
                        // Blocking fetch: the bytes have to exist before the viewer app is asked for them, so this is IO-bound and cannot ride the main thread.
                        val problem = withContext(Dispatchers.IO) {
                            externalOpener.open(
                                sessionId = sessionId,
                                path = file.path,
                                displayName = displayName,
                                mime = file.mime,
                            )
                        }
                        notice = problem
                        isOpening = false
                    }
                },
                enabled = !isOpening,
                modifier = Modifier.testTag("present_file_open"),
            ) {
                Text(
                    text = if (isOpening) "Opening…" else "Open",
                    style = MaterialTheme.typography.labelSmall,
                    color = PabrikAccent,
                )
            }
        }

        notice?.let { message ->
            Text(
                text = message,
                style = MaterialTheme.typography.labelSmall,
                color = PabrikError,
                modifier = Modifier
                    .padding(horizontal = 8.dp)
                    .padding(bottom = 6.dp)
                    .testTag("present_file_open_error"),
            )
        }

        when (val current = state) {
            is FilePreviewState.Loading -> LoadingBlock()
            is FilePreviewState.Image -> ImagePreviewBlock(current.bitmap)
            is FilePreviewState.Text -> TextPreviewBlock(kind = kind, state = current)
            is FilePreviewState.Failed -> MessageBlock(current.message, color = PabrikMuted)
            FilePreviewState.NotApplicable -> MessageBlock(
                "Open this file to see it in a viewer app.",
                color = PabrikDim,
            )
        }
    }
}

@Composable
private fun LoadingBlock() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 40.dp)
            .padding(horizontal = 8.dp, vertical = 8.dp)
            .testTag("present_file_loading"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(14.dp),
            color = PabrikAccent,
            strokeWidth = 2.dp,
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = "Loading preview…",
            style = MaterialTheme.typography.labelSmall,
            color = PabrikDim,
        )
    }
}

@Composable
private fun ImagePreviewBlock(bitmap: ImageBitmap) {
    // Nothing here decodes.
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(6.dp)
            .clip(RoundedCornerShape(4.dp))
            .background(PabrikCard)
            .testTag("present_file_image"),
    ) {
        Image(
            bitmap = bitmap,
            contentDescription = "preview",
            // Fit, never crop: a wireframe screenshot cropped to a box is not the file the reader asked to see.
            contentScale = ContentScale.Fit,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 320.dp),
        )
    }
}

@Composable
private fun TextPreviewBlock(kind: PresentFileKind, state: FilePreviewState.Text) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 6.dp, vertical = 6.dp)
            .testTag("present_file_text"),
    ) {
        // Markdown goes through the transcript's own renderer, so a README and an assistant reply of the same source look the same — which is the whole point of having …
        if (kind == PresentFileKind.MARKDOWN) {
            MarkdownText(source = state.text)
        } else {
            Text(
                text = state.text,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = if (kind == PresentFileKind.CODE) FontFamily.Monospace else null,
                color = PabrikText,
            )
        }
        if (state.truncated) {
            Text(
                text = "Truncated for inline display — tap Open for the full file.",
                style = MaterialTheme.typography.labelSmall,
                color = PabrikDim,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
    }
}

@Composable
private fun MessageBlock(message: String, color: Color) {
    Text(
        text = message,
        style = MaterialTheme.typography.labelSmall,
        color = color,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 6.dp)
            .testTag("present_file_message"),
    )
}

/** `12 KB · image/png`, the web's `fileMeta`. */
private fun fileMeta(file: ToolBody.PresentedFile): String {
    val size = if (file.bytes > 0) formatBytes(file.bytes) else "unknown size"
    val mime = file.mime.trim()
    return if (mime.isEmpty()) "$size · unknown type" else "$size · $mime"
}

/** The app's [FileClient] for a card, remembered per context. */
@Composable
private fun rememberFileClient(context: Context): FileClient = remember(context) {
    FileClient(sessionStore = SessionCookieStore(context))
}
