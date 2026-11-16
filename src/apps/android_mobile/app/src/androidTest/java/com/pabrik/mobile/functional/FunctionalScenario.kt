package com.pabrik.mobile.functional

/** The ids `tests/functional_android/` seeds and the scenarios in this package open. */
object FunctionalScenario {

    // ─── session ids ───────────────────────────────────────────────────────

    const val EMPTY = "sess_fn_empty"
    const val EXCHANGE = "sess_fn_exchange"
    const val MULTITURN = "sess_fn_multiturn"
    const val TOOL_CALLS = "sess_fn_toolcalls"
    const val TOOL_RESULT = "sess_fn_toolresult"
    const val MARKDOWN = "sess_fn_markdown"
    const val IMAGES = "sess_fn_images"
    const val REASONING = "sess_fn_reasoning"
    const val HTML = "sess_fn_html"
    const val PRESENT_FILES = "sess_fn_presentfiles"

    /** Every session the suite seeds, in seeding order. */
    val sessions = listOf(
        EMPTY, EXCHANGE, MULTITURN, TOOL_CALLS, TOOL_RESULT,
        MARKDOWN, IMAGES, REASONING, HTML, PRESENT_FILES,
    )

    // ─── the message ids the assertions name ───────────────────────────────

    /** `exchange` — a plain user turn and its reply. */
    const val EXCHANGE_USER = "sess_fn_exchange_0001"
    const val EXCHANGE_ASSISTANT = "sess_fn_exchange_0002"

    /** `multiturn` — eight alternating turns, so grouping and order both show. */
    val MULTITURN_IDS = listOf(
        "sess_fn_multiturn_0001", "sess_fn_multiturn_0002",
        "sess_fn_multiturn_0003", "sess_fn_multiturn_0004",
        "sess_fn_multiturn_0005", "sess_fn_multiturn_0006",
        "sess_fn_multiturn_0007", "sess_fn_multiturn_0008",
    )

    /** `toolcalls` — an assistant turn that is nothing but a tool call. */
    const val TOOL_CALLS_ASSISTANT = "sess_fn_toolcalls_0002"

    /** `toolresult` — the call, and the row with its output. */
    const val TOOL_RESULT_ASSISTANT = "sess_fn_toolresult_0002"
    const val TOOL_RESULT_TOOL = "sess_fn_toolresult_0003"

    /** `markdown` — a fenced block and a heading in one reply. */
    const val MARKDOWN_ASSISTANT = "sess_fn_markdown_0002"

    /** `images` — a user turn carrying two attachments. */
    const val IMAGES_USER = "sess_fn_images_0001"

    /** `reasoning` — a reply with a thinking trace behind it. */
    const val REASONING_ASSISTANT = "sess_fn_reasoning_0002"

    /** `html` — the document turn. */
    const val HTML_ASSISTANT = "sess_fn_html_0002"

    /** `presentfiles` — the call, and the row whose envelope names the files. */
    const val PRESENT_FILES_ASSISTANT = "sess_fn_presentfiles_0002"
    const val PRESENT_FILES_TOOL = "sess_fn_presentfiles_0003"

    /** Every declared message id, in one list. */
    val messageIds = listOf(
        EXCHANGE_USER, EXCHANGE_ASSISTANT,
        *MULTITURN_IDS.toTypedArray(),
        TOOL_CALLS_ASSISTANT,
        TOOL_RESULT_ASSISTANT, TOOL_RESULT_TOOL,
        MARKDOWN_ASSISTANT,
        IMAGES_USER,
        REASONING_ASSISTANT,
        HTML_ASSISTANT,
        PRESENT_FILES_ASSISTANT, PRESENT_FILES_TOOL,
    )
}
