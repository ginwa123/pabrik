package com.pabrik.mobile.chat

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.pabrik.mobile.ui.PabrikAccentSoft
import com.pabrik.mobile.ui.PabrikAqua
import com.pabrik.mobile.ui.PabrikBorder
import com.pabrik.mobile.ui.PabrikCard
import com.pabrik.mobile.ui.PabrikDim
import com.pabrik.mobile.ui.PabrikError
import com.pabrik.mobile.ui.PabrikMuted
import com.pabrik.mobile.ui.PabrikText
import org.json.JSONArray
import java.util.Locale

/** Width of the card's leading rule. */
private val TOOL_CARD_RULE_WIDTH = 2.dp

/** A tool row, rendered. */
@Composable
fun ToolCardView(
    model: ToolCardModel,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    onAnswer: (QuestionAnswer) -> Unit = {},
    /** Which chat this row belongs to. */
    sessionId: String = "",
) {
    // A card with neither a body nor any arguments has nothing to reveal, so its header is a label rather than a button.
    val hasArguments = model.parametersJson.isNotBlank()
    val hasBody = model.body !is ToolBody.Empty
    val expandable = hasBody || hasArguments

    val ruleColor by animateColorAsState(
        targetValue = CardRuleColor(model),
        label = "tool-card-rule",
    )

    Column(
        modifier = modifier
            .fillMaxWidth()
            // The web's "paragraph mode" (ChatView.vue's `.chat-tool-card`)
            .drawBehind {
                drawRect(
                    color = ruleColor,
                    size = Size(TOOL_CARD_RULE_WIDTH.toPx(), size.height),
                )
            }
            .testTag("tool_card_${model.kind.name.lowercase(Locale.ROOT)}"),
    ) {
        ToolCardHeader(
            toolName = model.label,
            primary = model.primary,
            rightMeta = model.rightMeta,
            success = model.success,
            running = model.pending,
            expanded = expanded,
            expandable = expandable,
            onToggle = onToggle,
        )

        if (expanded && hasBody) {
            ToolDivider()
            ToolBody {
                val error = model.errorText
                if (error != null) {
                    ToolErrorRow(message = error)
                } else {
                    ToolBodyFor(model, onAnswer, sessionId)
                }
            }
        }

        // Outside the `hasBody` block on purpose: a running tool's arguments live here and nowhere else, because its body is empty by definition.
        if (expanded && hasArguments) {
            ToolParametersBlock(
                parametersJson = model.parametersJson,
                exclude = model.excludedParameters,
            )
        }
    }
}

/** The left rule's colour, and with the box gone the card's only error channel. */
internal fun CardRuleColor(model: ToolCardModel): Color = when {
    model.pending -> PabrikDim
    model.success -> PabrikBorder
    else -> Color(0xFF6B3A38)
}

@Composable
private fun ToolBodyFor(
    model: ToolCardModel,
    onAnswer: (QuestionAnswer) -> Unit,
    sessionId: String,
) {
    when (val body = model.body) {
        is ToolBody.ReadFile -> ReadFileBody(body)
        is ToolBody.WriteFile -> WriteFileBody(body)
        is ToolBody.Shell -> ShellBody(body)
        is ToolBody.Search -> SearchBody(body)
        is ToolBody.Glob -> GlobBody(body)
        is ToolBody.ListDirectory -> ListDirectoryBody(body)
        is ToolBody.Diff -> DiffBody(body)
        is ToolBody.Plan -> PlanBody(body)
        is ToolBody.Question -> QuestionCard(body, model.toolCallId, onAnswer)
        is ToolBody.SubAgentSpawn -> SubAgentSpawnBody(body)
        is ToolBody.AgentCatalog -> AgentCatalogBody(body)
        is ToolBody.MemorySave -> MemorySaveBody(body)
        is ToolBody.MemoryLoad -> MemoryLoadBody(body)
        is ToolBody.MemoryList -> MemoryListBody(body)
        is ToolBody.SkillList -> SkillListBody(body)
        is ToolBody.SkillUse -> SkillUseBody(body)
        is ToolBody.SkillMutation -> SkillMutationBody(body)
        is ToolBody.KanbanMove -> KanbanMoveBody(body)
        is ToolBody.KanbanList -> KanbanListBody(body)
        is ToolBody.PresentFiles -> PresentFilesBody(body, sessionId)
        is ToolBody.GenerateImage -> GenerateImageBody(body)
        is ToolBody.Worktree -> WorktreeBody(body)
        is ToolBody.SessionReader -> SessionReaderBody(body)
        is ToolBody.ProgressiveTool -> ProgressiveBody(body)
        is ToolBody.Mcp -> MonospaceBlock(text = body.text)
        is ToolBody.Raw -> MonospaceBlock(text = body.text, color = PabrikMuted)
        ToolBody.Empty -> Unit
    }
}

@Composable
private fun ReadFileBody(body: ToolBody.ReadFile) {
    val lines = body.lines
    if (lines.isEmpty()) {
        Text(
            text = "(empty)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 6.dp)
                .testTag("read_file_empty"),
        )
        return
    }
    val first = body.firstLineNumber
    val scroll = rememberScrollState()
    // `read_file` reads the whole file with no cap on the wire, and one `Row` plus two `Text`s per line is three composables per line — a 5,000-line file is 15,000 …
    var showAll by remember(body.path) { mutableStateOf(false) }
    val visible = if (showAll) lines else lines.take(MAX_RENDERED_FILE_LINES)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(PabrikCard)
            .horizontalScroll(scroll)
            .padding(vertical = 4.dp)
            .testTag("read_file_body"),
    ) {
        visible.forEachIndexed { index, line ->
            Row {
                Text(
                    text = (first + index).toString(),
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = PabrikDim,
                    modifier = Modifier
                        .width(44.dp)
                        .padding(end = 8.dp),
                )
                Text(
                    // A blank line still needs a glyph, or the row collapses to zero height and the gutter stops lining up with the text.
                    text = line.ifEmpty { " " },
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = PabrikText,
                    softWrap = false,
                )
            }
        }
        if (visible.size < lines.size) {
            Text(
                text = "… ${lines.size - visible.size} more lines — tap to show them",
                style = MaterialTheme.typography.labelSmall,
                color = PabrikDim,
                modifier = Modifier
                    .padding(horizontal = 8.dp, vertical = 4.dp)
                    .clickable { showAll = true }
                    .testTag("read_file_show_more"),
            )
        }
    }
}

/** How many lines of a read result are composed before the card offers more. */
private const val MAX_RENDERED_FILE_LINES = 500

@Composable
private fun WriteFileBody(body: ToolBody.WriteFile) {
    if (body.path.isBlank()) return
    ToolKeyValue(key = "wrote", value = body.path)
}

@Composable
private fun ShellBody(body: ToolBody.Shell) {
    if (body.stdout.isNotEmpty()) {
        ToolSectionLabel(
            text = "stdout",
            meta = "${body.stdoutLines}L",
            color = PabrikAccentSoft,
        )
        MonospaceBlock(
            text = body.stdout,
            modifier = Modifier.testTag("shell_stdout"),
        )
    }
    if (body.hasStderr) {
        ToolSectionLabel(
            text = "stderr",
            meta = "${body.stderrLines}L",
            color = PabrikError,
        )
        MonospaceBlock(
            text = body.stderr,
            color = PabrikError,
            modifier = Modifier.testTag("shell_stderr"),
        )
    }
    if (body.stdout.isEmpty() && !body.hasStderr) {
        Text(
            text = if (body.timedOut) "(timed out)" else "(no output)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun SearchBody(body: ToolBody.Search) {
    if (body.warning != null) {
        ToolKeyValue(key = "warning", value = body.warning, valueColor = PabrikMuted)
    }
    if (body.truncatedHint != null) {
        ToolKeyValue(key = "truncated", value = body.truncatedHint, valueColor = PabrikMuted)
    }
    if (body.files.isEmpty()) {
        Text(
            text = "(no matches)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
        return
    }
    body.files.forEach { file ->
        Column(modifier = Modifier.padding(top = 4.dp)) {
            Text(
                text = file.path,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                color = PabrikAccentSoft,
                modifier = Modifier.padding(horizontal = 8.dp),
            )
            file.matches.forEach { match ->
                Row(modifier = Modifier.padding(horizontal = 8.dp, vertical = 1.dp)) {
                    Text(
                        text = match.line.toString().padStart(5),
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = FontFamily.Monospace,
                        color = PabrikDim,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = match.text.trimEnd(),
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        color = PabrikText,
                        softWrap = false,
                    )
                }
            }
        }
    }
}

@Composable
private fun GlobBody(body: ToolBody.Glob) {
    if (body.warning != null) {
        ToolKeyValue(key = "warning", value = body.warning, valueColor = PabrikMuted)
    }
    if (body.files.isEmpty()) {
        Text(
            text = "(no matches)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
        return
    }
    body.files.forEach { path ->
        Text(
            text = path,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikText,
            softWrap = false,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 1.dp)
                .testTag("glob_path"),
        )
    }
    if ((body.truncated ?: 0) > 0 || body.truncatedBySize) {
        Text(
            text = "+${body.truncated ?: 0} more dropped",
            style = MaterialTheme.typography.labelSmall,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
        )
    }
}

@Composable
private fun ListDirectoryBody(body: ToolBody.ListDirectory) {
    if (body.entries.isEmpty()) {
        Text(
            text = "(empty)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
        return
    }
    body.entries.forEach { entry ->
        Text(
            text = buildString {
                append(if (entry.isDirectory) "📁 " else "  ")
                append(entry.name)
                if (entry.isSymlink) append(" →")
            },
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = if (entry.isDirectory) PabrikAccentSoft else PabrikText,
            softWrap = false,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 1.dp)
                .testTag("dir_entry"),
        )
    }
}

@Composable
private fun DiffBody(body: ToolBody.Diff) {
    // `unified` is the backend's own rendering when it supplied one; a client that re-diffs `before`/`after` and disagrees with the server is worse than one that …
    if (body.unified.isNotBlank()) {
        MonospaceBlock(text = body.unified)
        return
    }
    DiffView(before = body.before, after = body.after)
}

/** Two-sided diff, in transcript order. */
@Composable
fun DiffView(
    before: String,
    after: String,
    modifier: Modifier = Modifier,
) {
    val rows = remember(before, after) { ToolDiff.compute(before, after) }
    if (rows.isEmpty()) {
        Text(
            text = "(no change)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
        return
    }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(PabrikCard)
            .padding(vertical = 4.dp)
            .testTag("diff_view"),
    ) {
        rows.forEach { row ->
            val color = when (row.kind) {
                DiffRowKind.Added -> Color(0xFF2F3A2F)
                DiffRowKind.Removed -> Color(0xFF3A2A2A)
                DiffRowKind.Context -> Color.Transparent
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(color),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = (row.beforeLine ?: row.afterLine ?: 0).toString(),
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = PabrikDim,
                    modifier = Modifier
                        .width(40.dp)
                        .padding(end = 4.dp),
                )
                Text(
                    text = when (row.kind) {
                        DiffRowKind.Added -> "+"
                        DiffRowKind.Removed -> "-"
                        DiffRowKind.Context -> " "
                    },
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold,
                    color = when (row.kind) {
                        DiffRowKind.Added -> Color(0xFF87A987)
                        DiffRowKind.Removed -> PabrikError
                        DiffRowKind.Context -> PabrikDim
                    },
                )
                Text(
                    text = row.text.ifEmpty { " " },
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = PabrikText,
                    softWrap = false,
                )
            }
        }
    }
}

@Composable
private fun PlanBody(body: ToolBody.Plan) {
    body.updatedAt?.let {
        ToolKeyValue(key = "updated", value = it)
    }
    if (body.empty) {
        Text(
            text = "(no plan yet)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 6.dp)
                .testTag("plan_empty"),
        )
        return
    }
    val lines = body.lines
    if (lines.isEmpty()) return
    Column(
        modifier = Modifier.padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        lines.forEach { line ->
            when (line.kind) {
                ToolBody.ChecklistLine.ChecklistKind.Checked -> ToolBullet(
                    text = "☑  ${line.text}",
                    color = PabrikMuted,
                    strikeThrough = true,
                )

                ToolBody.ChecklistLine.ChecklistKind.Unchecked -> ToolBullet(
                    text = "☐  ${line.text}",
                )

                ToolBody.ChecklistLine.ChecklistKind.Text -> Text(
                    text = line.text,
                    style = MaterialTheme.typography.bodySmall,
                    color = PabrikText,
                    modifier = Modifier
                        .padding(horizontal = 8.dp, vertical = 1.dp)
                        .testTag("plan_line"),
                )
            }
        }
    }
}

/** One `ask_user` reply, ready to post. */
data class QuestionAnswer(
    val questionId: String?,
    val toolCallId: String,
    val answer: String?,
    val skip: Boolean = false,
)

/** A blocking `ask_user` question, rendered with the affordance to answer it. */
@Composable
private fun QuestionCard(
    body: ToolBody.Question,
    toolCallId: String,
    onAnswer: (QuestionAnswer) -> Unit,
) {
    var draft by remember(body.questionId) { mutableStateOf("") }
    // Selection is local: nothing is posted until the reader confirms, and `multi_select` turns one answer into several, which is a decision the card owns rather …
    var selected by remember(body.questionId) { mutableStateOf(emptySet<String>()) }
    val canSubmit = body.isPending && (selected.isNotEmpty() || draft.isNotBlank())

    body.header?.let { ToolKeyValue(key = "header", value = it) }

    // Markdown, like the web's `renderMarkdownHtml` on the same field.
    MarkdownText(
        source = body.question,
        color = PabrikText,
        modifier = Modifier
            .padding(horizontal = 8.dp, vertical = 6.dp)
            .testTag("question_text"),
    )

    if (body.options.isNotEmpty()) {
        body.options.forEach { option ->
            val isSelected = option in selected
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(6.dp))
                    .background(if (isSelected) SELECTED_OPTION else Color.Transparent)
                    .clickable(enabled = body.isPending) {
                        selected = when {
                            !body.multiSelect -> setOf(option)
                            isSelected -> selected - option
                            else -> selected + option
                        }
                    }
                    .padding(horizontal = 8.dp, vertical = 6.dp)
                    .testTag("question_option"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = if (isSelected) "◉" else "○",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (isSelected) PabrikAccentSoft else PabrikDim,
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = option,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = PabrikText,
                    modifier = Modifier.weight(1f),
                )
                if (option == body.recommended) {
                    Text(
                        text = "recommended",
                        style = MaterialTheme.typography.labelSmall,
                        color = PabrikAqua,
                    )
                }
            }
        }
    }

    if (body.allowFreeText && body.isPending) {
        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            label = { Text("Your answer") },
            singleLine = false,
            maxLines = 4,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 4.dp)
                .testTag("question_input"),
        )
    }

    if (body.isPending) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "The run is stopped until this is answered.",
                style = MaterialTheme.typography.labelSmall,
                color = BLOCKING,
                modifier = Modifier
                    .weight(1f)
                    .testTag("question_blocked_note"),
            )
            TextButton(
                onClick = { onAnswer(QuestionAnswer(body.questionId, toolCallId, null, skip = true)) },
                modifier = Modifier.testTag("question_skip"),
            ) {
                Text("Skip", color = PabrikMuted)
            }
            TextButton(
                onClick = {
                    onAnswer(
                        QuestionAnswer(
                            questionId = body.questionId,
                            toolCallId = toolCallId,
                            answer = encodeAnswer(selected, draft, body.multiSelect),
                        ),
                    )
                },
                enabled = canSubmit,
                modifier = Modifier.testTag("question_send"),
            ) {
                Text("Answer", color = PabrikAccentSoft)
            }
        }
    } else {
        // One branch, one answer row.
        ToolKeyValue(
            key = "answer",
            value = body.answer
                ?: when (body.status) {
                    ToolBody.Question.STATUS_SKIPPED -> "skipped"
                    ToolBody.Question.STATUS_ABANDONED -> "abandoned"
                    ToolBody.Question.STATUS_UNAVAILABLE -> "unavailable"
                    else -> "not answered"
                },
            valueColor = if (body.answer != null) PabrikAqua else PabrikMuted,
        )
    }

    body.instruction?.let {
        Text(
            text = it,
            style = MaterialTheme.typography.labelSmall,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
        )
    }
}

/** The `answer` string the endpoint expects. */
internal fun encodeAnswer(
    selected: Set<String>,
    draft: String,
    multiSelect: Boolean,
): String? {
    if (multiSelect) {
        if (selected.isEmpty()) return draft.trim().ifEmpty { null }
        return JSONArray(selected.toList()).toString()
    }
    // A tapped option wins over whatever is in the text field: that is the one the reader just chose, and a question may offer both.
    if (selected.isNotEmpty()) return selected.first()
    return draft.trim().ifEmpty { null }
}

@Composable
private fun SubAgentSpawnBody(body: ToolBody.SubAgentSpawn) {
    body.results.forEach { result ->
        Text(
            text = buildString {
                append(if (result.success) "✓ " else "✗ ")
                append(result.name.ifEmpty { "(unnamed)" })
                result.error?.let { append(" — ").append(it) }
            },
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = if (result.success) PabrikText else PabrikError,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 2.dp)
                .testTag("sub_agent_result"),
        )
        // The whole point of spawning a sub-agent is its response; a card that only shows the ok/fail line throws away the answer.
        result.response?.takeIf { it.isNotBlank() }?.let { response ->
            MonospaceBlock(
                text = response,
                color = PabrikMuted,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
            )
        }
    }
}

@Composable
private fun AgentCatalogBody(body: ToolBody.AgentCatalog) {
    body.agents.forEach { agent ->
        ToolKeyValue(
            key = agent.name,
            value = listOf(agent.model, agent.thinking)
                .filter { it.isNotBlank() }
                .joinToString(" · "),
        )
    }
}

@Composable
private fun MemorySaveBody(body: ToolBody.MemorySave) {
    if (body.id.isNotBlank()) ToolKeyValue(key = "id", value = body.id)
}

@Composable
private fun MemoryLoadBody(body: ToolBody.MemoryLoad) {
    body.results.forEach { hit ->
        Column(modifier = Modifier.padding(vertical = 3.dp)) {
            Text(
                text = hit.id,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace,
                color = PabrikAccentSoft,
                modifier = Modifier.padding(horizontal = 8.dp),
            )
            Text(
                text = hit.snippet,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = PabrikText,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 1.dp),
            )
        }
    }
    if (body.results.isEmpty()) {
        Text(
            text = "(no memories matched)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun MemoryListBody(body: ToolBody.MemoryList) {
    if (body.memories.isEmpty()) {
        Text(
            text = "(no memories stored)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
        return
    }
    body.memories.forEach { memory ->
        Text(
            text = buildString {
                append(memory.title.ifEmpty { memory.id })
                if (memory.sizeBytes > 0) {
                    append("  ·  ")
                    append(formatBytes(memory.sizeBytes))
                }
            },
            style = MaterialTheme.typography.bodySmall,
            color = PabrikText,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 1.dp)
                .testTag("memory_entry"),
        )
    }
}

@Composable
private fun SkillListBody(body: ToolBody.SkillList) {
    if (body.skills.isEmpty()) {
        Text(
            text = "(no matching skill)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
        return
    }
    body.skills.forEach { entry -> SkillRow(entry) }
    if (!body.sawEverything) MoreResultsNote(body.nextOffset)
}

/** One name + description row, shared by the two paged-search cards. */
@Composable
private fun SkillRow(entry: ToolBody.SkillEntry) {
    Column(modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)) {
        Text(
            text = buildString {
                append(entry.name)
                if (entry.scope.isNotBlank()) {
                    append("  [").append(entry.scope).append("]")
                }
            },
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikText,
        )
        if (entry.description.isNotBlank()) {
            Text(
                text = entry.description,
                style = MaterialTheme.typography.labelSmall,
                color = PabrikMuted,
            )
        }
    }
}

/** The foot of a page that is not the whole answer. */
@Composable
private fun MoreResultsNote(nextOffset: Int?) {
    val suffix = nextOffset?.let { " (next page starts at offset $it)" }.orEmpty()
    Text(
        text = "more results exist; narrow the query to see them$suffix",
        style = MaterialTheme.typography.labelSmall,
        color = PabrikDim,
        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
    )
}

@Composable
private fun SkillUseBody(body: ToolBody.SkillUse) {
    if (body.content.isNotBlank()) {
        MonospaceBlock(text = body.content)
    } else if (!body.loaded) {
        Text(
            text = "(the skill body was empty)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun SkillMutationBody(body: ToolBody.SkillMutation) {
    body.path?.let { ToolKeyValue(key = "path", value = it) }
    if (!body.changed) {
        Text(
            text = "(nothing changed)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun KanbanMoveBody(body: ToolBody.KanbanMove) {
    ToolKeyValue(key = "column", value = body.columnName.ifEmpty { "(unknown)" })
    ToolKeyValue(key = "position", value = body.position.toString())
}

@Composable
private fun KanbanListBody(body: ToolBody.KanbanList) {
    if (body.columns.isNotEmpty()) {
        ToolSectionLabel(text = "columns", color = PabrikAccentSoft)
        body.columns.forEach { column ->
            ToolKeyValue(key = column.name, value = "${column.taskCount} task(s)")
        }
    }
    if (body.tasks.isNotEmpty()) {
        ToolSectionLabel(text = "tasks", meta = body.tasks.size.toString(), color = PabrikAccentSoft)
        body.tasks.forEach { task ->
            Text(
                text = buildString {
                    append("• ")
                    append(task.name)
                    task.columnName?.let { append("  [").append(it).append("]") }
                },
                style = MaterialTheme.typography.bodySmall,
                color = PabrikText,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 1.dp),
            )
        }
    }
    if (body.hasMore) {
        Text(
            text = "more tasks exist; narrow the query to see them",
            style = MaterialTheme.typography.labelSmall,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
        )
    }
}

/** One [PresentFileCard] per file. */
@Composable
private fun PresentFilesBody(body: ToolBody.PresentFiles, sessionId: String) {
    body.files.forEach { file ->
        PresentFileCard(file = file, sessionId = sessionId)
    }
    if (body.files.isEmpty()) {
        Text(
            text = "(no files)",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = PabrikDim,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun GenerateImageBody(body: ToolBody.GenerateImage) {
    if (body.model.isNotBlank()) ToolKeyValue(key = "model", value = body.model)
    if (body.size.isNotBlank()) ToolKeyValue(key = "size", value = body.size)
    body.images.forEach { image ->
        ToolKeyValue(key = "image ${image.index}", value = image.path)
    }
    body.revisedPrompt?.let { ToolKeyValue(key = "revised", value = it) }
}

@Composable
private fun WorktreeBody(body: ToolBody.Worktree) {
    body.branch?.let { ToolKeyValue(key = "branch", value = it) }
    body.base?.let { ToolKeyValue(key = "base", value = it) }
    body.note?.let { ToolKeyValue(key = "note", value = it, valueColor = PabrikMuted) }
}

@Composable
private fun SessionReaderBody(body: ToolBody.SessionReader) {
    when (body.behavior) {
        "list" -> body.sessions.forEach { session ->
            Column(modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)) {
                Text(
                    text = session.name.ifEmpty { session.path },
                    style = MaterialTheme.typography.bodySmall,
                    color = PabrikText,
                )
                if (session.description.isNotBlank()) {
                    Text(
                        text = session.description,
                        style = MaterialTheme.typography.labelSmall,
                        color = PabrikMuted,
                    )
                }
            }
        }

        "search" -> body.results.forEach { result ->
            Column(modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)) {
                Text(
                    text = result.path,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = PabrikAccentSoft,
                )
                result.matches.forEach { match ->
                    Text(
                        text = match.text,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        color = PabrikText,
                    )
                }
            }
        }

        // `read` returns whole messages, which the generic renderer shows.
        else -> MonospaceBlock(text = "(${body.count} message(s), ${body.totalCount} total)")
    }
}

@Composable
private fun ProgressiveBody(body: ToolBody.ProgressiveTool) {
    if (body.description.isNotBlank()) {
        Text(
            text = body.description,
            style = MaterialTheme.typography.bodySmall,
            color = PabrikMuted,
            modifier = Modifier
                .padding(horizontal = 8.dp, vertical = 4.dp)
                .testTag("progressive_description"),
        )
    }
    // The same row renderer `search_skills` uses: both are paged searches over a list of `{name, description, …}` objects, so the two cards look alike.
    body.tools.forEach { tool -> SkillRow(tool) }
}

/** 1234 → "1.2 KB". Decimal units, because that is what a file manager shows. */
internal fun formatBytes(bytes: Long): String {
    if (bytes < 1000) return "$bytes B"
    val units = listOf("KB", "MB", "GB", "TB")
    var value = bytes.toDouble() / 1000.0
    var index = 0
    while (value >= 1000 && index < units.lastIndex) {
        value /= 1000.0
        index++
    }
    return String.format(Locale.ROOT, "%.1f %s", value, units[index])
}

/** The keys a card already draws, so the Arguments block does not repeat them. */
internal val ToolCardModel.excludedParameters: Set<String>
    get() = when (kind) {
        ToolKind.Diff -> setOf("old_str", "new_str", "before", "after")
        ToolKind.ReadFile -> setOf("content")
        else -> emptySet()
    }

/** The amber the whole client uses for "waiting on something outside the run" */
internal val BLOCKING = Color(0xFFD8B96A)

/** A selected option row, against the card's own background. */
private val SELECTED_OPTION = Color(0xFF2C2A33)
