package com.pabrik.mobile.server

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikError
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

/** The server this app talks to, and the one control that changes it. */
@Composable
fun ServerAddressRow(
    baseUrl: String,
    onChange: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .testTag("server_address_row"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(modifier = Modifier.weight(1f, fill = false)) {
            Text(
                text = "Server",
                style = MaterialTheme.typography.labelMedium,
                color = PabrikMuted,
            )
            Text(
                // The host and nothing else.
                text = hostLabelFor(baseUrl),
                modifier = Modifier.testTag("server_address_host"),
                style = MaterialTheme.typography.bodyMedium,
                color = PabrikText,
            )
        }
        TextButton(
            onClick = onChange,
            modifier = Modifier.testTag("server_address_change"),
        ) {
            Text(text = "Change", color = PabrikAccent)
        }
    }
}

/** The host, with the scheme and any trailing path left off. */
internal fun hostLabelFor(baseUrl: String): String {
    val withoutScheme = baseUrl.substringAfter("://", baseUrl)
    val authority = withoutScheme.substringBefore('/')
    return authority.ifBlank { baseUrl }
}

/** "Point the app somewhere else." The field takes the raw text and hands the **raw text** back, deliberately: validation is one function owned by the auth … */
@Composable
fun ServerAddressDialog(
    currentBaseUrl: String,
    defaultBaseUrl: String,
    onSave: (String) -> ServerChange,
    /** A separate callback rather than an empty string down [onSave]. */
    onUseDefault: () -> ServerChange,
    onDismiss: () -> Unit,
) {
    var draft by rememberSaveable { mutableStateOf(currentBaseUrl) }
    var error by rememberSaveable { mutableStateOf<String?>(null) }

    fun report(change: ServerChange) {
        when (change) {
            is ServerChange.Applied -> onDismiss()
            // The store's own sentence, verbatim.
            is ServerChange.Rejected -> error = change.reason
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = Modifier.testTag("server_address_dialog"),
        title = { Text(text = "Change server", color = PabrikText) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = {
                        draft = it
                        error = null
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("server_address_input"),
                    label = { Text("Server address") },
                    placeholder = { Text("pabrik.example.com") },
                    singleLine = true,
                    isError = error != null,
                    supportingText = {
                        Text(
                            text = error
                                ?: "The address your Pabrik server is reached at. https:// is added for you.",
                            color = if (error != null) PabrikError else PabrikMuted,
                        )
                    },
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Uri,
                        imeAction = ImeAction.Done,
                    ),
                    keyboardActions = KeyboardActions(onDone = { report(onSave(draft)) }),
                    shape = RoundedCornerShape(14.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = PabrikText,
                        unfocusedTextColor = PabrikText,
                        focusedBorderColor = PabrikAccent,
                        unfocusedBorderColor = PabrikBorder,
                        focusedContainerColor = PabrikField,
                        unfocusedContainerColor = PabrikField,
                        errorContainerColor = PabrikField,
                        focusedLabelColor = PabrikAccent,
                        unfocusedLabelColor = PabrikMuted,
                        errorLabelColor = PabrikError,
                        errorTextColor = PabrikText,
                        errorSupportingTextColor = PabrikError,
                        cursorColor = PabrikAccent,
                    ),
                )
                if (defaultBaseUrl != currentBaseUrl) {
                    TextButton(
                        onClick = { report(onUseDefault()) },
                        modifier = Modifier.testTag("server_address_default"),
                    ) {
                        Text(
                            text = "Use the default server",
                            color = PabrikMuted,
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { report(onSave(draft)) },
                modifier = Modifier.testTag("server_address_save"),
            ) {
                Text(text = "Save", color = PabrikAccent)
            }
        },
        dismissButton = {
            TextButton(
                onClick = onDismiss,
                modifier = Modifier.testTag("server_address_cancel"),
            ) {
                Text(text = "Cancel", color = PabrikMuted)
            }
        },
        containerColor = PabrikField,
    )
}
