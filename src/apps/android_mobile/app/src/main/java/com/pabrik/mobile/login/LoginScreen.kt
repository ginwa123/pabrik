package com.pabrik.mobile.login

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.server.ServerAddressDialog
import com.pabrik.mobile.server.ServerAddressRow
import com.pabrik.mobile.server.ServerChange
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikAccentSoft
import com.pabrik.mobile.ui.PabrikAqua
import com.pabrik.mobile.ui.PabrikBackground
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikCard
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikError
import com.pabrik.mobile.ui.PabrikErrorSoft
import com.pabrik.mobile.ui.PabrikField
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText
import com.pabrik.mobile.ui.PabrikTheme

private val EmailPattern = Regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")

data class LoginCredentials(
    val email: String,
    val password: String,
) {
    override fun toString(): String = "LoginCredentials(email=$email, password=••••••••)"
}

data class LoginValidation(
    val emailError: String? = null,
    val passwordError: String? = null,
) {
    val isValid: Boolean
        get() = emailError == null && passwordError == null
}

fun validateLogin(email: String, password: String): LoginValidation {
    val normalizedEmail = email.trim()
    return LoginValidation(
        emailError = when {
            normalizedEmail.isEmpty() -> "Enter your email address."
            !EmailPattern.matches(normalizedEmail) -> "Enter a valid email address."
            else -> null
        },
        passwordError = if (password.isBlank()) "Enter your password." else null,
    )
}

@Composable
fun LoginScreen(
    modifier: Modifier = Modifier,
    onSignIn: (LoginCredentials) -> Unit = {},
    authError: String? = null,
    isAuthenticating: Boolean = false,
    onOpenNetworkInspector: () -> Unit = {},
    /** The server this app is pointed at, and the way to point it somewhere else. */
    serverBaseUrl: String = AuthConfig.BUILD_DEFAULT_BASE_URL,
    defaultServerBaseUrl: String = AuthConfig.BUILD_DEFAULT_BASE_URL,
    onChangeServer: (String) -> ServerChange = { ServerChange.Applied(serverBaseUrl) },
    onUseDefaultServer: () -> ServerChange = { ServerChange.Applied(defaultServerBaseUrl) },
) {
    var serverDialogOpen by remember { mutableStateOf(false) }
    var email by rememberSaveable { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var passwordVisible by remember { mutableStateOf(false) }
    var submitted by rememberSaveable { mutableStateOf(false) }
    val validation = validateLogin(email, password)
    val scrollState = rememberScrollState()
    val focusManager = LocalFocusManager.current

    fun submit() {
        submitted = true
        if (validation.isValid && !isAuthenticating) {
            onSignIn(LoginCredentials(email.trim(), password))
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    colors = listOf(PabrikBackgroundRaised, PabrikBackground),
                ),
            )
            .imePadding(),
    ) {
        DecorativeBackground(Modifier.matchParentSize())

        // Reachable before sign-in on purpose: "why did my POST fail?" is the moment an inspector is most needed, and that POST is the login itself.
        IconButton(
            onClick = onOpenNetworkInspector,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(end = 12.dp, top = 4.dp)
                .testTag("login_open_network_inspector"),
        ) {
            Icon(
                imageVector = Icons.Filled.Insights,
                contentDescription = "Open network inspector",
                tint = PabrikDim,
            )
        }

        // In the `Box` beside the form, not inside it: the dialog is about the server rather than about the account, so it has to sit outside the card the credentials …
        if (serverDialogOpen) {
            ServerAddressDialog(
                currentBaseUrl = serverBaseUrl,
                defaultBaseUrl = defaultServerBaseUrl,
                onSave = onChangeServer,
                onUseDefault = onUseDefaultServer,
                onDismiss = { serverDialogOpen = false },
            )
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .verticalScroll(scrollState)
                .padding(horizontal = 24.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            BrandHeader()

            Spacer(Modifier.height(28.dp))

            Surface(
                modifier = Modifier
                    .widthIn(max = 420.dp)
                    .fillMaxWidth(),
                shape = RoundedCornerShape(28.dp),
                color = PabrikCard,
                border = androidx.compose.foundation.BorderStroke(1.dp, PabrikBorder),
                shadowElevation = 18.dp,
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 28.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            text = "Welcome back",
                            style = MaterialTheme.typography.headlineSmall,
                            color = PabrikText,
                        )
                        Text(
                            text = "Sign in to continue to your workspace.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = PabrikMuted,
                        )
                    }

                    LoginTextField(
                        value = email,
                        onValueChange = {
                            email = it
                            submitted = false
                        },
                        label = "Email address",
                        placeholder = "you@example.com",
                        leadingIcon = {
                            Icon(
                                imageVector = Icons.Default.Email,
                                contentDescription = null,
                                tint = PabrikMuted,
                            )
                        },
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Email,
                            imeAction = ImeAction.Next,
                            capitalization = KeyboardCapitalization.None,
                        ),
                        keyboardActions = KeyboardActions(
                            onNext = { focusManager.moveFocus(FocusDirection.Down) },
                        ),
                        isError = submitted && validation.emailError != null,
                        supportingText = validation.emailError.takeIf { submitted },
                        testTag = "login_email",
                    )

                    LoginTextField(
                        value = password,
                        onValueChange = {
                            password = it
                            submitted = false
                        },
                        label = "Password",
                        placeholder = "Enter your password",
                        leadingIcon = {
                            Icon(
                                imageVector = Icons.Default.Lock,
                                contentDescription = null,
                                tint = PabrikMuted,
                            )
                        },
                        trailingIcon = {
                            IconButton(
                                onClick = { passwordVisible = !passwordVisible },
                            ) {
                                Icon(
                                    imageVector = if (passwordVisible) {
                                        Icons.Default.VisibilityOff
                                    } else {
                                        Icons.Default.Visibility
                                    },
                                    contentDescription = if (passwordVisible) {
                                        "Hide password"
                                    } else {
                                        "Show password"
                                    },
                                    tint = PabrikMuted,
                                )
                            }
                        },
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Password,
                            imeAction = ImeAction.Done,
                            capitalization = KeyboardCapitalization.None,
                        ),
                        keyboardActions = KeyboardActions(onDone = { submit() }),
                        visualTransformation = if (passwordVisible) {
                            VisualTransformation.None
                        } else {
                            PasswordVisualTransformation()
                        },
                        isError = submitted && validation.passwordError != null,
                        supportingText = validation.passwordError.takeIf { submitted },
                        testTag = "login_password",
                    )

                    Button(
                        onClick = { submit() },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(54.dp)
                            .testTag("login_submit"),
                        enabled = !isAuthenticating,
                        shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = PabrikAccent,
                            contentColor = PabrikBackground,
                            disabledContainerColor = PabrikBorder,
                            disabledContentColor = PabrikMuted,
                        ),
                    ) {
                        if (isAuthenticating) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                color = PabrikBackground,
                                strokeWidth = 2.dp,
                            )
                        } else {
                            Text(
                                text = "Sign in",
                                style = MaterialTheme.typography.labelLarge,
                            )
                            Spacer(Modifier.width(10.dp))
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.ArrowForward,
                                contentDescription = null,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }

                    Text(
                        text = when {
                            authError != null -> authError
                            isAuthenticating -> "Signing in…"
                            submitted && validation.isValid -> "Credentials ready."
                            else -> "Connect to your Pabrik account to continue."
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(if (authError != null) "login_error" else "login_status")
                            .clip(RoundedCornerShape(12.dp))
                            .background(
                                if (authError != null) {
                                    PabrikErrorSoft
                                } else {
                                    PabrikAccent.copy(alpha = 0.10f)
                                },
                            )
                            .padding(horizontal = 12.dp, vertical = 10.dp),
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (authError != null) PabrikError else PabrikAccentSoft,
                    )
                }
            }

            Spacer(Modifier.height(24.dp))

            // Below the card, above the sign-off line, and on both auth screens.
            ServerAddressRow(
                baseUrl = serverBaseUrl,
                onChange = { serverDialogOpen = true },
                modifier = Modifier.widthIn(max = 420.dp),
            )

            Spacer(Modifier.height(12.dp))

            Text(
                text = "Pabrik · your private AI workspace",
                style = MaterialTheme.typography.labelMedium,
                color = PabrikDim,
            )
        }
    }
}

@Composable
private fun BrandHeader() {
    Row(
        modifier = Modifier
            .widthIn(max = 420.dp)
            .fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(50.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(PabrikAccent),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = "N",
                color = PabrikBackground,
                fontSize = 26.sp,
                fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = "PABRIK",
                style = MaterialTheme.typography.titleMedium,
                color = PabrikText,
                letterSpacing = 2.sp,
            )
            Text(
                text = "Native client",
                style = MaterialTheme.typography.labelMedium,
                color = PabrikMuted,
            )
        }
    }
}

@Composable
private fun LoginTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    placeholder: String,
    leadingIcon: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    trailingIcon: (@Composable () -> Unit)? = null,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    isError: Boolean = false,
    supportingText: String? = null,
    testTag: String,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier
            .fillMaxWidth()
            .testTag(testTag),
        label = { Text(label) },
        placeholder = { Text(placeholder) },
        leadingIcon = leadingIcon,
        trailingIcon = trailingIcon,
        singleLine = true,
        isError = isError,
        visualTransformation = visualTransformation,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        supportingText = supportingText?.let { message ->
            { Text(message) }
        },
        shape = RoundedCornerShape(14.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = PabrikText,
            unfocusedTextColor = PabrikText,
            focusedBorderColor = PabrikAccent,
            unfocusedBorderColor = PabrikBorder,
            focusedContainerColor = PabrikField,
            unfocusedContainerColor = PabrikField,
            errorContainerColor = PabrikErrorSoft,
            focusedLabelColor = PabrikAccent,
            unfocusedLabelColor = PabrikMuted,
            errorLabelColor = PabrikError,
            errorTextColor = PabrikText,
            errorSupportingTextColor = PabrikError,
            cursorColor = PabrikAccent,
        ),
    )
}

@Composable
private fun DecorativeBackground(modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.alpha(0.9f)) {
        drawCircle(
            color = PabrikAccent.copy(alpha = 0.14f),
            radius = size.minDimension * 0.62f,
            center = androidx.compose.ui.geometry.Offset(size.width * 0.92f, size.height * 0.04f),
        )
        drawCircle(
            color = PabrikAqua.copy(alpha = 0.08f),
            radius = size.minDimension * 0.48f,
            center = androidx.compose.ui.geometry.Offset(size.width * 0.02f, size.height * 0.92f),
        )
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun LoginScreenPreview() {
    PabrikTheme {
        LoginScreen()
    }
}
