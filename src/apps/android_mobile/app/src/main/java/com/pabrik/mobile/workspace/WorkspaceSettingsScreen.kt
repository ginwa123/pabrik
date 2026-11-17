@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.pabrik.mobile.workspace

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.FeatureScaffold
import com.pabrik.mobile.ui.PabrikAccent
import com.pabrik.mobile.ui.PabrikBackgroundRaised
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText

private enum class SettingsTab(val label: String) {
    Usage("Usage"),
    Members("Members"),
    Secrets("Secrets"),
    Skills("Skills"),
    Memories("Memories"),
    Config("Config"),
}

@Composable
fun WorkspaceSettingsScreen(
    state: WorkspaceDataState,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var selectedTab by remember { mutableIntStateOf(0) }

    FeatureScaffold(
        title = "Workspace settings",
        subtitle = state.workspaceId,
        onBack = onBack,
        modifier = modifier,
        isLoading = state.isLoading,
        errorMessage = state.errorMessage.takeIf { state.secrets.isEmpty() && state.members.isEmpty() },
        testTag = "workspace_settings_screen",
    ) {
        ScrollableTabRow(
            selectedTabIndex = selectedTab,
            containerColor = PabrikBackgroundRaised,
            contentColor = PabrikText,
            edgePadding = 0.dp,
        ) {
            SettingsTab.entries.forEachIndexed { index, tab ->
                Tab(
                    selected = selectedTab == index,
                    onClick = { selectedTab = index },
                    text = {
                        Text(
                            text = tab.label,
                            modifier = Modifier.testTag("settings_tab_${tab.label.lowercase()}"),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                    selectedContentColor = PabrikAccent,
                    unselectedContentColor = PabrikMuted,
                )
            }
        }

        Spacer(Modifier.height(12.dp))

        when (SettingsTab.entries[selectedTab]) {
            SettingsTab.Usage -> UsageTab(state.usage)
            SettingsTab.Members -> MembersTab(state.members)
            SettingsTab.Secrets -> SecretsTab(state.secrets)
            SettingsTab.Skills -> SkillsTab(state.skills)
            SettingsTab.Memories -> MemoriesTab(state.memories)
            SettingsTab.Config -> ConfigTab(state.config)
        }
    }
}

@Composable
private fun UsageTab(usage: UsageData?) {
    if (usage == null) {
        EmptyState("No usage data yet.")
        return
    }
    SectionCard("Totals") {
        StatRow("Calls", usage.totals.calls.toString())
        StatRow("Sessions", usage.totals.sessions.toString())
        StatRow("Input tokens", usage.totals.inputTokens.toString())
        StatRow("Output tokens", usage.totals.outputTokens.toString())
        StatRow("Tool calls", usage.totals.toolCalls.toString())
        usage.totals.cacheHitRate?.let { StatRow("Cache hit rate", "${(it * 100).toInt()}%") }
    }
    if (usage.daily.isNotEmpty()) {
        SectionCard("Daily activity") {
            usage.daily.forEach { StatRow(it.label, "${it.calls} calls · ${it.tokens} tokens") }
        }
    }
    if (usage.models.isNotEmpty()) {
        SectionCard("Models") {
            usage.models.forEach { StatRow(it.label, "${it.calls} calls") }
        }
    }
    if (usage.tools.isNotEmpty()) {
        SectionCard("Tools") {
            usage.tools.forEach { StatRow(it.label, "${it.calls} calls") }
        }
    }
}

@Composable
private fun MembersTab(members: List<MemberEntry>) {
    if (members.isEmpty()) {
        EmptyState("No members in this workspace.")
        return
    }
    SectionCard("Members (${members.size})") {
        members.forEach { member ->
            InfoRow(
                label = member.name.ifBlank { member.email.ifBlank { member.userId } },
                value = member.role,
                detail = member.email,
            )
        }
    }
}

@Composable
private fun SecretsTab(secrets: List<SecretEntry>) {
    if (secrets.isEmpty()) {
        EmptyState("No secrets in this workspace.")
        return
    }
    SectionCard("Secrets (${secrets.size})") {
        secrets.forEach { secret ->
            InfoRow(
                label = secret.name,
                value = "••••••••",
                detail = secret.description.ifBlank { secret.createdAt },
            )
        }
    }
}

@Composable
private fun SkillsTab(skills: List<SkillEntry>) {
    if (skills.isEmpty()) {
        EmptyState("No skills in this workspace.")
        return
    }
    SectionCard("Skills (${skills.size})") {
        skills.forEach { skill ->
            InfoRow(
                label = skill.name,
                value = if (skill.isCanAutoImprove) "auto-improve" else "",
                detail = skill.description,
            )
        }
    }
}

@Composable
private fun MemoriesTab(memories: List<MemoryEntry>) {
    if (memories.isEmpty()) {
        EmptyState("No memories in this workspace.")
        return
    }
    SectionCard("Memories (${memories.size})") {
        memories.forEach { memory ->
            Column(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                Text(
                    text = memory.content,
                    style = MaterialTheme.typography.bodyMedium,
                    color = PabrikText,
                )
                if (memory.tags.isNotEmpty()) {
                    Text(
                        text = memory.tags.joinToString(", ") { "#$it" },
                        style = MaterialTheme.typography.labelSmall,
                        color = PabrikAccent,
                    )
                }
            }
        }
    }
}

@Composable
private fun ConfigTab(config: ConfigData?) {
    if (config == null) {
        EmptyState("No config for this workspace.")
        return
    }
    SectionCard("Profiles (${config.profiles.size})") {
        config.profiles.forEach { profile ->
            InfoRow(
                label = profile.name + if (profile.name == config.activeProfile) " · active" else "",
                value = profile.model,
                detail = profile.baseUrl,
            )
        }
    }
    SectionCard("MCP servers (${config.mcpServers.size})") {
        config.mcpServers.forEach { server ->
            InfoRow(label = server.name, value = server.url, detail = null)
        }
    }
    SectionCard("Runtime") {
        StatRow("Chat view", config.chatView)
        StatRow("Notify on complete", config.notifyOnComplete.toString())
        StatRow("Notify on error", config.notifyOnError.toString())
    }
}

@Composable
private fun SectionCard(
    title: String,
    content: @Composable () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .testTag("section_${title.lowercase().replace(' ', '_')}"),
        shape = RoundedCornerShape(16.dp),
        color = PabrikBackgroundRaised,
        border = BorderStroke(1.dp, PabrikBorder),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                color = PabrikAccent,
            )
            Spacer(Modifier.height(8.dp))
            content()
        }
    }
}

@Composable
private fun StatRow(
    label: String,
    value: String,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(text = label, style = MaterialTheme.typography.bodyMedium, color = PabrikMuted)
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium,
            color = PabrikText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(start = 12.dp),
        )
    }
}

@Composable
private fun InfoRow(
    label: String,
    value: String,
    detail: String?,
) {
    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.bodyMedium,
                color = PabrikText,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (value.isNotEmpty()) {
                Text(
                    text = value,
                    style = MaterialTheme.typography.labelMedium,
                    color = PabrikAccent,
                )
            }
        }
        if (!detail.isNullOrEmpty()) {
            Text(
                text = detail,
                style = MaterialTheme.typography.labelSmall,
                color = PabrikDim,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun EmptyState(message: String) {
    Text(
        text = message,
        style = MaterialTheme.typography.bodyMedium,
        color = PabrikMuted,
        modifier = Modifier.padding(16.dp),
    )
}
