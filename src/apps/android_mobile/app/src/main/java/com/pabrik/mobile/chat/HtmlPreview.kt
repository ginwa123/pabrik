package com.pabrik.mobile.chat

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikText
import java.io.ByteArrayInputStream

/** What a turn looks like when it is a document rather than an answer. */
@Composable
fun HtmlResponseText(
    source: String,
    color: Color = PabrikText,
    modifier: Modifier = Modifier,
    isComplete: Boolean = true,
) {
    val segments = remember(source, isComplete) { HtmlResponse.segments(source, isComplete) }
    if (segments.isEmpty()) return

    // Counted here rather than picked in a list up front, because a turn carrying five copies of the *same* document compares equal five times — position is the only …
    var documentsSeen = 0

    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag("html_response"),
    ) {
        for (segment in segments) {
            when (segment) {
                is ResponseSegment.Prose -> MarkdownText(
                    source = segment.text,
                    color = color,
                )

                is ResponseSegment.Document ->
                    if (HtmlResponse.getsLiveFrame(documentsSeen++)) {
                        HtmlDocumentFrame(html = segment.html)
                    } else {
                        // Past the frame budget.
                        MarkdownText(source = segment.html, color = color)
                    }
            }
        }
    }
}

/** One rendered document, in a frame the transcript can lay out. */
@Composable
private fun HtmlDocumentFrame(html: String, modifier: Modifier = Modifier) {
    var heightPx by remember(html) { mutableIntStateOf(0) }

    // The *state* is captured, not the value inside it.
    val onHeight = rememberUpdatedState<(Int) -> Unit>({ px -> heightPx = px })
    val context = LocalContext.current
    val holder = remember(context) {
        HtmlFrameHolder(context) { px -> onHeight.value(px) }
    }

    DisposableEffect(holder) {
        onDispose { holder.destroy() }
    }

    val frameHeight = with(LocalDensity.current) { heightPx.toDp() }
        .coerceAtLeast(MIN_FRAME_HEIGHT)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(top = 6.dp, bottom = 10.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(PabrikField)
            .border(1.dp, PabrikBorder, RoundedCornerShape(8.dp)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "HTML preview",
                color = PabrikDim,
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
        AndroidView(
            modifier = Modifier
                .fillMaxWidth()
                .height(frameHeight)
                .testTag("chat_html_frame"),
            factory = { holder.webView },
            update = { holder.load(html) },
        )
    }
}

/** A `WebView`, its configuration, and the single document it has loaded. */
private class HtmlFrameHolder(context: Context, onHeight: (Int) -> Unit) {

    val webView: WebView = WebView(context).apply {
        configureForPreview()
        addJavascriptInterface(HeightReporter(onHeight), HEIGHT_BRIDGE)
    }

    private var loaded: String? = null

    fun load(html: String) {
        if (loaded == html) return
        loaded = html
        webView.loadDataWithBaseURL(
            null,
            htmlFrameSource(html),
            "text/html",
            "utf-8",
            null,
        )
    }

    fun destroy() {
        webView.removeJavascriptInterface(HEIGHT_BRIDGE)
        webView.stopLoading()
        // `destroy()` on a WebView that is still loading is how a recycled frame's page keeps running against a dead renderer; blanking it first is the order `WebView`'s …
        webView.loadUrl("about:blank")
        webView.destroy()
    }
}

/** The JS bridge the frame's reporter calls into. */
private class HeightReporter(private val onHeight: (Int) -> Unit) {

    private val main = Handler(Looper.getMainLooper())

    @JavascriptInterface
    fun reportHeight(px: Int) {
        if (px <= 0) return
        main.post { onHeight(px.coerceAtMost(MAX_FRAME_HEIGHT_PX)) }
    }
}

/** Configure a `WebView` that is about to be handed model-authored HTML. */
@SuppressLint("SetJavaScriptEnabled")
private fun WebView.configureForPreview() {
    settings.apply {
        javaScriptEnabled = true
        domStorageEnabled = false
        javaScriptCanOpenWindowsAutomatically = false
        setSupportMultipleWindows(false)
        setGeolocationEnabled(false)
        allowFileAccess = false
        allowContentAccess = false
        @Suppress("DEPRECATION")
        allowFileAccessFromFileURLs = false
        @Suppress("DEPRECATION")
        allowUniversalAccessFromFileURLs = false
        mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        cacheMode = WebSettings.LOAD_NO_CACHE
        mediaPlaybackRequiresUserGesture = true
    }
    isVerticalScrollBarEnabled = false
    isHorizontalScrollBarEnabled = false
    overScrollMode = View.OVER_SCROLL_NEVER
    isLongClickable = false
    // The transcript is not the only focusable thing on the screen: the composer sits a row or two below, and a `WebView` that takes focus on tap pops the keyboard …
    isFocusable = false
    isFocusableInTouchMode = false
    webViewClient = PreviewWebViewClient()
}

/** A client that lets the document exist and nothing else. */
private class PreviewWebViewClient : WebViewClient() {

    override fun shouldInterceptRequest(
        view: WebView,
        request: WebResourceRequest,
    ): WebResourceResponse? {
        val scheme = request.url?.scheme?.lowercase() ?: return BLOCKED
        return if (scheme == "data" || scheme == "about") null else BLOCKED
    }

    override fun shouldOverrideUrlLoading(
        view: WebView,
        request: WebResourceRequest,
    ): Boolean = true

    private companion object {
        val BLOCKED = WebResourceResponse(
            "text/plain",
            "utf-8",
            ByteArrayInputStream(ByteArray(0)),
        )
    }
}

/** Tall enough to read a heading into; short enough not to be a blank slab. */
private val MIN_FRAME_HEIGHT = 160.dp

/** A ceiling on what one report may move the frame by, in pixels. */
private const val MAX_FRAME_HEIGHT_PX = 200_000
