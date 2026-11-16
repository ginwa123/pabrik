package com.pabrik.mobile.network

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pabrik.mobile.http.HttpHeader
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikAqua
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikCard
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikError
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText
import com.pabrik.mobile.ui.PabrikTheme

private enum class RecordTab(val label: String) {
    Request("Request"),
    Response("Response"),
    Curl("cURL"),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NetworkRecordDetailScreen(
    onBack: () -> Unit,
    onReplay: (NetworkLogEntry) -> Unit,
    modifier: Modifier = Modifier,
    recordId: Long? = null,
    store: NetworkLogStore = NetworkLogStore.default,
) {
    val entries by store.entries.collectAsStateWithLifecycle()
    val entry = recordId?.let { id -> entries.firstOrNull { candidate -> candidate.id == id } }

    var selectedTab by rememberSaveable { mutableStateOf(RecordTab.Request) }
    var revealSecrets by rememberSaveable { mutableStateOf(false) }
    var pendingReplay by remember { mutableStateOf<NetworkLogEntry?>(null) }
    val clipboard = LocalClipboardManager.current

    // A mutation re-records a real server-side effect, so it never fires on a single tap; the confirm dialog is the whole point of the guard.
    val requestReplay: (NetworkLogEntry) -> Unit = { target ->
        if (target.isMutation) {
            pendingReplay = target
        } else {
            onReplay(target)
        }
    }

    pendingReplay?.let { target ->
        ReplayConfirmationDialog(
            entry = target,
            onConfirm = {
                pendingReplay = null
                onReplay(target)
            },
            onDismiss = { pendingReplay = null },
        )
    }

    Scaffold(
        modifier = modifier
            .fillMaxSize()
            .testTag("network_detail"),
        containerColor = PabrikBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = entry?.label ?: "Record",
                        style = MaterialTheme.typography.titleMedium,
                        color = PabrikText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                navigationIcon = {
                    IconButton(
                        onClick = onBack,
                        modifier = Modifier.testTag("network_detail_back"),
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                            tint = PabrikText,
                        )
                    }
                },
                actions = {
                    if (entry != null) {
                        IconButton(
                            onClick = { clipboard.setText(AnnotatedString(buildCurlCommand(entry))) },
                            modifier = Modifier.testTag("network_copy_curl"),
                        ) {
                            Icon(
                                imageVector = Icons.Filled.ContentCopy,
                                contentDescription = "Copy as cURL",
                                tint = PabrikText,
                            )
                        }
                        IconButton(
                            onClick = { requestReplay(entry) },
                            modifier = Modifier.testTag("network_replay"),
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Replay,
                                contentDescription = "Replay request",
                                tint = PabrikText,
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = PabrikBackground,
                    navigationIconContentColor = PabrikText,
                    titleContentColor = PabrikText,
                    actionIconContentColor = PabrikText,
                ),
            )
        },
    ) { contentPadding ->
        if (entry == null) {
            MissingRecord(modifier = Modifier.padding(contentPadding))
            return@Scaffold
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(contentPadding)
                .testTag("network_detail_body"),
        ) {
            RecordSummary(entry = entry)

            SecretToggle(
                revealSecrets = revealSecrets,
                onRevealChanged = { next -> revealSecrets = next },
                entry = entry,
            )

            TabRow(
                selectedTabIndex = selectedTab.ordinal,
                containerColor = PabrikBackground,
                contentColor = PabrikText,
            ) {
                RecordTab.entries.forEach { tab ->
                    Tab(
                        selected = tab == selectedTab,
                        onClick = { selectedTab = tab },
                        modifier = Modifier.testTag("network_tab_${tab.name.lowercase()}"),
                        text = {
                            Text(
                                text = tab.label,
                                style = MaterialTheme.typography.labelLarge,
                                color = if (tab == selectedTab) PabrikText else PabrikDim,
                            )
                        },
                    )
                }
            }

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
            ) {
                Spacer(Modifier.height(12.dp))

                when (selectedTab) {
                    RecordTab.Request -> RequestPane(entry = entry, revealSecrets = revealSecrets)
                    RecordTab.Response -> ResponsePane(entry = entry, revealSecrets = revealSecrets)
                    RecordTab.Curl -> CurlPane(entry = entry, onRequestReplay = requestReplay)
                }

                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun RecordSummary(entry: NetworkLogEntry) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .testTag("network_detail_summary"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            MethodBadge(method = entry.method)
            Text(
                text = entry.statusLabel,
                style = MaterialTheme.typography.titleMedium,
                color = statusColorOf(entry),
            )
            if (entry.isReplay) {
                Text(
                    text = "replay",
                    style = MaterialTheme.typography.labelMedium,
                    color = PabrikDim,
                )
            }
        }

        Text(
            text = entry.url,
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = FontFamily.Monospace,
            color = PabrikMuted,
        )

        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            SummaryFact("took", formatDuration(entry.durationMillis))
            SummaryFact("sent", formatBytes(entry.requestBodyBytes))
            SummaryFact("received", formatBytes(entry.responseBodyBytes))
        }

        Text(
            text = formatClockTime(entry.startedAtEpochMillis),
            style = MaterialTheme.typography.labelMedium,
            color = PabrikDim,
        )
    }
}

@Composable
private fun SummaryFact(label: String, value: String) {
    Column {
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium,
            color = PabrikText,
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = PabrikDim,
        )
    }
}

@Composable
private fun SecretToggle(
    revealSecrets: Boolean,
    onRevealChanged: (Boolean) -> Unit,
    entry: NetworkLogEntry,
) {
    if (!entry.containsSecrets) return

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .padding(bottom = 8.dp)
            .testTag("network_reveal_secrets"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Reveal secrets",
                style = MaterialTheme.typography.bodyMedium,
                color = PabrikText,
            )
            Text(
                text = "This record carries live credentials.",
                style = MaterialTheme.typography.labelMedium,
                color = PabrikDim,
            )
        }
        Switch(
            checked = revealSecrets,
            onCheckedChange = onRevealChanged,
            modifier = Modifier.testTag("network_reveal_secrets_switch"),
        )
    }
}

@Composable
private fun RequestPane(entry: NetworkLogEntry, revealSecrets: Boolean) {
    HeaderList(
        title = "Request headers",
        headers = if (revealSecrets) entry.requestHeaders else redactHeaders(entry.requestHeaders),
        testTag = "network_request_headers",
    )
    BodyBlock(
        title = "Request body",
        body = if (revealSecrets) entry.requestBody else redactBody(entry.requestBody),
        truncated = entry.requestBodyTruncated,
        testTag = "network_request_body",
        accent = PabrikError,
    )
}

@Composable
private fun ResponsePane(entry: NetworkLogEntry, revealSecrets: Boolean) {
    HeaderList(
        title = "Response headers",
        headers = if (revealSecrets) entry.responseHeaders else redactHeaders(entry.responseHeaders),
        testTag = "network_response_headers",
    )

    if (entry.responseBody != null) {
        BodyBlock(
            title = "Response body",
            body = if (revealSecrets) entry.responseBody else redactBody(entry.responseBody),
            truncated = entry.responseBodyTruncated,
            testTag = "network_response_body",
        )
    }

    if (entry.errorMessage != null) {
        BodyBlock(
            title = "Failure",
            body = entry.errorMessage,
            truncated = false,
            testTag = "network_error_body",
            accent = PabrikError,
        )
    }
}

@Composable
private fun CurlPane(
    entry: NetworkLogEntry,
    onRequestReplay: (NetworkLogEntry) -> Unit,
) {
    val command = remember(entry.id, entry.statusCode, entry.durationMillis) {
        buildCurlCommand(entry)
    }
    val clipboard = LocalClipboardManager.current

    if (entry.containsSecrets) {
        Text(
            text = "This command carries live credentials. The clipboard, and any terminal you paste it into, will hold them.",
            style = MaterialTheme.typography.bodyMedium,
            color = PabrikError,
            modifier = Modifier.padding(bottom = 10.dp),
        )
    }

    CodeBlock(text = command, testTag = "network_curl_command")

    Row(
        modifier = Modifier.padding(top = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        TextButton(
            onClick = { clipboard.setText(AnnotatedString(command)) },
            modifier = Modifier.testTag("network_curl_copy"),
        ) {
            Icon(
                imageVector = Icons.Filled.ContentCopy,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = PabrikAccent,
            )
            Spacer(Modifier.width(6.dp))
            Text("Copy", color = PabrikAccent)
        }

        TextButton(
            onClick = { onRequestReplay(entry) },
            modifier = Modifier.testTag("network_curl_replay"),
        ) {
            Icon(
                imageVector = Icons.Filled.Replay,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = PabrikAccent,
            )
            Spacer(Modifier.width(6.dp))
            Text("Replay", color = PabrikAccent)
        }
    }
}

@Composable
private fun HeaderList(
    title: String,
    headers: List<HttpHeader>,
    testTag: String,
) {
    SectionTitle(title)
    if (headers.isEmpty()) {
        Text(
            text = "No headers",
            style = MaterialTheme.typography.bodyMedium,
            color = PabrikDim,
        )
    } else {
        Column(
            modifier = Modifier.testTag(testTag),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            headers.forEach { header ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Top,
                ) {
                    Text(
                        text = header.name,
                        style = MaterialTheme.typography.labelMedium,
                        fontFamily = FontFamily.Monospace,
                        color = PabrikMuted,
                        modifier = Modifier.width(132.dp),
                    )
                    Text(
                        text = header.value,
                        style = MaterialTheme.typography.labelMedium,
                        fontFamily = FontFamily.Monospace,
                        color = PabrikText,
                    )
                }
            }
        }
    }
    Spacer(Modifier.height(16.dp))
}

@Composable
private fun BodyBlock(
    title: String,
    body: String?,
    truncated: Boolean,
    testTag: String,
    accent: Color = PabrikText,
) {
    val clipboard = LocalClipboardManager.current
    val shown = body.orEmpty()

    SectionTitle(title)
    if (truncated) {
        Text(
            text = "Body clipped at ${formatBytes(NetworkLogStore.MAX_BODY_CHARS)}.",
            style = MaterialTheme.typography.labelMedium,
            color = PabrikDim,
            modifier = Modifier.padding(bottom = 4.dp),
        )
    }
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.End,
    ) {
        TextButton(
            onClick = { clipboard.setText(AnnotatedString(shown)) },
            modifier = Modifier.testTag("${testTag}_copy"),
        ) {
            Text("Copy", style = MaterialTheme.typography.labelMedium, color = PabrikAccent)
        }
    }
    CodeBlock(
        text = shown.ifEmpty { "(empty)" },
        testTag = testTag,
        accent = accent,
    )
    Spacer(Modifier.height(16.dp))
}

@Composable
private fun CodeBlock(
    text: String,
    testTag: String,
    accent: Color = PabrikText,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(testTag),
        shape = RoundedCornerShape(12.dp),
        color = PabrikCard,
        contentColor = accent,
        border = BorderStroke(1.dp, PabrikBorder),
    ) {
        Text(
            text = text,
            modifier = Modifier
                .horizontalScroll(rememberScrollState())
                .padding(12.dp),
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
            lineHeight = 18.sp,
        )
    }
}

@Composable
private fun SectionTitle(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.labelLarge,
        color = PabrikDim,
        modifier = Modifier.padding(bottom = 6.dp),
    )
}

@Composable
private fun MissingRecord(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .testTag("network_detail_missing"),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                text = "This request is no longer buffered",
                style = MaterialTheme.typography.titleMedium,
                color = PabrikMuted,
            )
            Text(
                text = "The inspector keeps the most recent ${NetworkLogStore.MAX_ENTRIES} calls in memory.",
                style = MaterialTheme.typography.bodyMedium,
                color = PabrikDim,
            )
        }
    }
}

@Composable
private fun ReplayConfirmationDialog(
    entry: NetworkLogEntry,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        modifier = Modifier.testTag("network_replay_confirm"),
        onDismissRequest = onDismiss,
        containerColor = PabrikBackgroundRaised,
        titleContentColor = PabrikText,
        textContentColor = PabrikMuted,
        title = { Text("Replay ${entry.method} ${entry.path}?") },
        text = {
            Text("This sends the request to ${entry.host} again, including the credentials it was recorded with.")
        },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                modifier = Modifier.testTag("network_replay_confirm_accept"),
            ) {
                Text("Replay", color = PabrikAqua)
            }
        },
        dismissButton = {
            TextButton(
                onClick = onDismiss,
                modifier = Modifier.testTag("network_replay_confirm_dismiss"),
            ) {
                Text("Cancel", color = PabrikMuted)
            }
        },
    )
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun NetworkRecordDetailPreview() {
    PabrikTheme {
        NetworkRecordDetailScreen(
            onBack = {},
            onReplay = {},
        )
    }
}
