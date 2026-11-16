package com.pabrik.mobile.projects

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue

/** What pressing `+` on a project of [itemType] actually does. */
sealed interface CreateTaskStartDecision {
    /** Make this now, with no dialog between the press and the POST. */
    data class Create(val request: CreateTaskRequest) : CreateTaskStartDecision

    /** Open the picker and wait for the reader to choose a type. */
    data object Pick : CreateTaskStartDecision

    /** Open a form and wait for the reader to fill it in. */
    data object NameTask : CreateTaskStartDecision

    /** This project does not take tasks. Do nothing at all. */
    data object NotAllowed : CreateTaskStartDecision
}

internal fun createTaskStartDecision(itemType: String): CreateTaskStartDecision =
    when (itemType) {
        ProjectTypes.AGENT -> CreateTaskStartDecision.Create(
            CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME),
        )
        ProjectTypes.KANBAN -> CreateTaskStartDecision.NameTask
        ProjectTypes.ROUTINE -> CreateTaskStartDecision.NotAllowed
        else -> CreateTaskStartDecision.Pick
    }

/** Which step the create flow is on. */
sealed interface CreateTaskStep {
    /** Nothing open. */
    data object Idle : CreateTaskStep

    /** The two-card picker, for one specific project. */
    data class Picking(
        val workspaceId: String,
        val itemId: String,
        val projectName: String,
    ) : CreateTaskStep

    /** The memory form, for one specific project. */
    data class NamingMemory(
        val workspaceId: String,
        val itemId: String,
        val projectName: String,
    ) : CreateTaskStep

    /** The board card form, for one specific kanban project. */
    data class NamingTask(
        val workspaceId: String,
        val itemId: String,
        val projectName: String,
        val projectPath: String = "",
    ) : CreateTaskStep
}

/** The one open create flow, wherever it was started from. */
@Stable
class CreateTaskController(
    private val onCreate: (workspaceId: String, itemId: String, request: CreateTaskRequest) -> Unit,
) {
    var step: CreateTaskStep by mutableStateOf(CreateTaskStep.Idle)
        private set

    /** The reader pressed `+` on a project. */
    fun start(item: ProjectSummary) {
        when (val decision = createTaskStartDecision(item.itemType)) {
            is CreateTaskStartDecision.Create -> onCreate(
                // The project row's workspace id, falling back to the one the drawer is showing.
                item.workspaceId,
                item.id,
                decision.request,
            )

            CreateTaskStartDecision.NotAllowed -> Unit

            CreateTaskStartDecision.Pick -> step = CreateTaskStep.Picking(
                workspaceId = item.workspaceId,
                itemId = item.id,
                projectName = item.displayName,
            )

            CreateTaskStartDecision.NameTask -> step = CreateTaskStep.NamingTask(
                workspaceId = item.workspaceId,
                itemId = item.id,
                projectName = item.displayName,
                projectPath = item.path,
            )
        }
    }

    /** The reader chose "Standard Chat". Creates and closes — the chat opens. */
    fun pickStandardChat() {
        val current = step as? CreateTaskStep.Picking ?: return
        // Closed before the create so the sheet is not on screen over the chat route the create is about to navigate to.
        step = CreateTaskStep.Idle
        onCreate(
            current.workspaceId,
            current.itemId,
            CreateTaskRequest.StandardChat(TaskTypes.DEFAULT_NEW_CHAT_NAME),
        )
    }

    /** The reader chose "Memory". No name is asked for a chat, only a file. */
    fun pickMemory() {
        val current = step as? CreateTaskStep.Picking ?: return
        step = CreateTaskStep.NamingMemory(
            workspaceId = current.workspaceId,
            itemId = current.itemId,
            projectName = current.projectName,
        )
    }

    /** Submit the board card form. */
    fun submitTaskForm(form: KanbanTaskForm) {
        val current = step as? CreateTaskStep.NamingTask ?: return
        if (!canSubmitKanbanTask(form)) return
        // Closed here, not on a callback, for the reason [submitMemory] is
        step = CreateTaskStep.Idle
        onCreate(
            current.workspaceId,
            current.itemId,
            form.toRequest(),
        )
    }

    /** The two-field shorthand, for callers that have nothing else to say. */
    fun submitTask(name: String, description: String) =
        submitTaskForm(KanbanTaskForm(name = name, description = description))

    /** Submit the memory form. */
    fun submitMemory(name: String, content: String) {
        val current = step as? CreateTaskStep.NamingMemory ?: return
        if (!canSubmitMemory(name, content)) return
        // Closed here rather than on a callback from the caller: this method is the only place the form can be submitted, so a form left open after a successful create …
        step = CreateTaskStep.Idle
        onCreate(
            current.workspaceId,
            current.itemId,
            CreateTaskRequest.Memory(name.trim(), content),
        )
    }

    /** Back out of the memory form, to the picker for the same project. */
    fun backToPicker() {
        val current = step as? CreateTaskStep.NamingMemory ?: return
        step = CreateTaskStep.Picking(
            workspaceId = current.workspaceId,
            itemId = current.itemId,
            projectName = current.projectName,
        )
    }

    /** Dismiss whatever is open. */
    fun dismiss() {
        step = CreateTaskStep.Idle
    }
}

/** Whether the memory form's fields are complete enough to submit. */
fun canSubmitMemory(name: String, content: String): Boolean =
    isValidMemoryName(name) && content.isNotBlank()

/** Whether a title alone is enough to create a card. */
fun canSubmitTask(name: String): Boolean = canSubmitKanbanTask(KanbanTaskForm(name = name))

/** The controller, remembered across recompositions. */
@Composable
fun rememberCreateTaskController(
    onCreate: (workspaceId: String, itemId: String, request: CreateTaskRequest) -> Unit,
): CreateTaskController {
    val currentOnCreate by rememberUpdatedState(onCreate)
    return remember { CreateTaskController { w, i, r -> currentOnCreate(w, i, r) } }
}
