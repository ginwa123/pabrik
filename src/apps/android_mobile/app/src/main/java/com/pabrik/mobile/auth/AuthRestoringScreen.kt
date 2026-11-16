package com.pabrik.mobile.auth

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.server.ServerAddressDialog
import com.pabrik.mobile.server.ServerAddressRow
import com.pabrik.mobile.server.ServerChange
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikError
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

@Composable
fun AuthRestoringScreen(
    modifier: Modifier = Modifier,
    errorMessage: String? = null,
    onRetry: (() -> Unit)? = null,
    onUseAnotherAccount: (() -> Unit)? = null,
    /** The server, and the way to change it — offered **only in the error state**, because this is where a wrong or unreachable address lands. */
    serverBaseUrl: String? = null,
    defaultServerBaseUrl: String = AuthConfig.BUILD_DEFAULT_BASE_URL,
    onChangeServer: ((String) -> ServerChange)? = null,
    onUseDefaultServer: (() -> ServerChange)? = null,
) {
    var serverDialogOpen by remember { mutableStateOf(false) }
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(PabrikBackground)
            .statusBarsPadding()
            .navigationBarsPadding(),
        contentAlignment = Alignment.Center,
    ) {
        if (serverDialogOpen && serverBaseUrl != null && onChangeServer != null) {
            ServerAddressDialog(
                currentBaseUrl = serverBaseUrl,
                defaultBaseUrl = defaultServerBaseUrl,
                onSave = onChangeServer,
                // The "Use the default server" escape hatch is a no-op here in the sense that it is a second, equally valid way to say the same thing; it is wired to the same …
                onUseDefault = onUseDefaultServer ?: { ServerChange.Applied(defaultServerBaseUrl) },
                onDismiss = { serverDialogOpen = false },
            )
        }

        Column(
            modifier = Modifier.padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (errorMessage == null) {
                CircularProgressIndicator(
                    modifier = Modifier
                        .size(32.dp)
                        .testTag("auth_restoring"),
                    color = PabrikAccent,
                    strokeWidth = 3.dp,
                )
            }

            Text(
                text = if (errorMessage == null) {
                    "Restoring your session…"
                } else {
                    "Session check failed"
                },
                style = MaterialTheme.typography.titleMedium,
                color = PabrikText,
                textAlign = TextAlign.Center,
            )
            Text(
                text = errorMessage ?: "Checking your Pabrik account",
                modifier = Modifier.testTag("auth_restore_message"),
                style = MaterialTheme.typography.bodyMedium,
                color = if (errorMessage == null) PabrikMuted else PabrikError,
                textAlign = TextAlign.Center,
            )

            if (errorMessage != null) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Button(
                        onClick = { onRetry?.invoke() },
                        enabled = onRetry != null,
                        modifier = Modifier.testTag("auth_retry"),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = PabrikAccent,
                            contentColor = PabrikBackground,
                            disabledContainerColor = PabrikBorder,
                            disabledContentColor = PabrikMuted,
                        ),
                    ) {
                        Text(text = "Try again")
                    }
                    OutlinedButton(
                        onClick = { onUseAnotherAccount?.invoke() },
                        modifier = Modifier.testTag("auth_use_another_account"),
                    ) {
                        Text(text = "Sign in")
                    }
                }
                Text(
                    text = "Your saved session is kept until the server confirms it.",
                    style = MaterialTheme.typography.labelMedium,
                    color = PabrikDim,
                    textAlign = TextAlign.Center,
                )

                // Not a tab and not a separate route: a dialog over the screen the person is already on, so the way back is the way they arrived.
                if (serverBaseUrl != null && onChangeServer != null) {
                    ServerAddressRow(
                        baseUrl = serverBaseUrl,
                        onChange = { serverDialogOpen = true },
                    )
                }
            }
        }
    }
}
