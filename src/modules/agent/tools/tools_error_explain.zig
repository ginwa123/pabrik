//! Model-facing explanations for the errors that reach a tool envelope. Every
//! An exec adapter used to render a failure as `<tool> failed:
//! <@errorName>`.

const std = @import("std");

/// The generic advice appended to the fallback message. Kept as one
/// const so the wording cannot drift between call sites.
const FALLBACK_ADVICE =
    "Re-send the call with valid arguments. " ++
    "If the same error repeats, do not retry the identical call — " ++
    "change the arguments or report the blocker.";

/// Render `err` as a sentence the model can act on. The result is allocated
/// with `allocator`; the caller owns it.
pub fn explain(allocator: std.mem.Allocator, err: anyerror, context: ?[]const u8) ![]u8 {
    return switch (err) {
        // ── command / shell ────────────────────────────────────────────
        error.TimeoutMissing => try allocator.dupe(
            u8,
            "`timeout` is required and has no default. It is the only deadline for a foreground command — add \"timeout\": <seconds> (1–600) to the arguments. Pass `mode=\"background\"` instead for a process that must outlive the call.",
        ),
        error.TimeoutTooLarge => try allocator.dupe(
            u8,
            "`timeout` must be 600 seconds or fewer — ten minutes is the ceiling for a foreground command. Split the work into smaller steps, or pass `mode=\"background\"` for a process that outlives the call.",
        ),
        error.MandatoryCwdMissing => try allocator.dupe(
            u8,
            "`cwd` is required and has no default. Without it the command runs in the SERVER's working directory (the project root), not your worktree — so a build or a test run silently acts on the wrong tree. Add \"cwd\": \"/absolute/path\" to the arguments.",
        ),
        error.CwdNotAbsolute => try allocator.dupe(
            u8,
            "`cwd` must be an ABSOLUTE path. A relative path is resolved against the server's working directory rather than where you are working, so it silently lands somewhere else. Send the full path — it starts with `/`, or a drive letter like `C:\\`.",
        ),
        error.CwdInvalid => try allocator.dupe(
            u8,
            "`cwd` contains a character that cannot appear in a path (a control byte, a NUL, or a Windows reserved device name). The usual cause on Windows is a path written with single backslashes — inside the JSON string `C:\\Users\\me` must be written `C:\\\\Users\\\\me`, or the decoder turns `\\U` / `\\A` into a control character and the path arrives mangled.",
        ),
        error.CommandForbidden => try allocator.dupe(
            u8,
            "This command matches a forbidden pattern (it would produce unbounded output or is otherwise unsafe). Rewrite it so its output is bounded — pipe through `| head -n <N>` / `| tail -n <N>` (bash) or `| Select-Object -First <N>` (pwsh).",
        ),
        error.TooManyArgvPrefix => try allocator.dupe(
            u8,
            "The shell argv prefix was too long to build. This is an internal limit, not something the arguments can fix — retry once, and if it repeats report the blocker instead of resending.",
        ),
        error.UnsupportedOS => try allocator.dupe(
            u8,
            "This tool is not available on the host operating system. Use a different tool for the same goal, or report the blocker.",
        ),
        error.NullArgv => try allocator.dupe(
            u8,
            "The command resolved to an empty argv. Send a non-empty `command` string.",
        ),

        // ── JSON arguments ─────────────────────────────────────────────
        error.SyntaxError => try allocator.dupe(
            u8,
            "The arguments were not valid JSON. Common causes: a Windows path written with single backslashes (write `C:\\Users\\me` as `C:\\\\Users\\\\me` inside the JSON string), a ```json fence around the object, or the call being cut off mid-object. Re-send one complete JSON object.",
        ),
        error.UnexpectedEndOfInput => try allocator.dupe(
            u8,
            "The arguments JSON ended before the object was closed. The call was truncated — re-send the complete JSON object.",
        ),
        error.MissingField => try allocator.dupe(
            u8,
            "A required field was absent from the arguments. Check the tool's parameter list and include every required field by its exact name.",
        ),
        error.UnknownField => try allocator.dupe(
            u8,
            "The arguments contained a field this tool does not accept. Remove the unknown field, or rename it to the exact parameter name (near-misses like `file_path` for `path` are silently dropped otherwise).",
        ),
        error.UnexpectedToken => try allocator.dupe(
            u8,
            "A field had the wrong JSON type (for example a string where a number or boolean was expected). Send each field with the type the schema declares.",
        ),
        error.InvalidCharacter => try allocator.dupe(
            u8,
            "A value contained a character that is not valid in its JSON type. Check for stray text inside a number or boolean, and for unescaped quotes inside a string.",
        ),
        error.Overflow => try allocator.dupe(
            u8,
            "A numeric field was outside the range its type allows. Send a value within the documented range.",
        ),
        error.InvalidNumber => try allocator.dupe(
            u8,
            "A numeric field was not a valid number. Send a JSON number (a numeric string is accepted by the lenient tools, but `abc` is not).",
        ),
        error.DuplicateField => try allocator.dupe(
            u8,
            "The same field appeared twice in the arguments object. Send each field exactly once.",
        ),
        error.LengthMismatch => try allocator.dupe(
            u8,
            "An array field had a different length than the schema requires. Check the field's documented length.",
        ),
        error.InvalidEnumTag => try allocator.dupe(
            u8,
            "A field's value was not one of the allowed options. Send one of the documented values.",
        ),
        error.OutOfMemory => try allocator.dupe(
            u8,
            "The process ran out of memory building the result. Retry with a smaller request (narrower path, lower `max_output` / `max_lines`, fewer results).",
        ),

        // ── paths ──────────────────────────────────────────────────────
        error.FileNotFound => try pathMsg(
            allocator,
            context,
            "not found. Check the spelling and that the file exists — use `list_directory` or `glob` to confirm the path before retrying.",
        ),
        error.PathNotFound => try pathMsg(
            allocator,
            context,
            "not found. Check the spelling and that the path exists — use `list_directory` or `glob` to confirm it before retrying.",
        ),
        error.NotDir => try pathMsg(
            allocator,
            context,
            "is not a directory. Pass a directory path, or use `read_file` if the target is a file.",
        ),
        error.IsDir => try pathMsg(
            allocator,
            context,
            "is a directory, not a file. Use `list_directory` to see its contents, or pass a file path.",
        ),
        error.PathNotAbsolute => try pathMsg(
            allocator,
            context,
            "is not an absolute path. Send an absolute path (for example `/home/you/project/src/main.zig`).",
        ),
        error.NotAbsolute => try pathMsg(
            allocator,
            context,
            "is not an absolute path. Send an absolute path (for example `/home/you/project/src/main.zig`).",
        ),
        error.RootNotAbsolute => try allocator.dupe(
            u8,
            "The root path was not absolute. Send an absolute root path.",
        ),
        error.IndexRootNotAbsolute => try allocator.dupe(
            u8,
            "The index root path was not absolute. Send an absolute root path.",
        ),
        error.InvalidPath => try pathMsg(
            allocator,
            context,
            "is not a valid path. Check for empty segments, a trailing separator, or characters the filesystem rejects.",
        ),
        error.InvalidPathReason => try pathMsg(
            allocator,
            context,
            "was rejected as unsafe or malformed. Send a plain absolute path with no NUL bytes, no control characters, and no `..` segments.",
        ),
        error.PathTraversal => try pathMsg(
            allocator,
            context,
            "escapes the allowed root with `..`. Send a path inside the workspace.",
        ),
        error.OutsideRoot => try pathMsg(
            allocator,
            context,
            "is outside the sandbox root. Send a path inside the workspace.",
        ),
        error.AccessDenied => try pathMsg(
            allocator,
            context,
            "could not be read because permission was denied. Choose a path the process may read, or report the blocker.",
        ),
        error.PermissionDenied => try pathMsg(
            allocator,
            context,
            "could not be accessed because permission was denied. Choose a path the process may access, or report the blocker.",
        ),
        error.PathAlreadyExists => try pathMsg(
            allocator,
            context,
            "already exists. Choose a different path, or use the tool's overwrite option when one exists.",
        ),
        error.PathTooLong => try pathMsg(
            allocator,
            context,
            "is longer than the filesystem allows. Use a shorter path.",
        ),
        error.SymLinkLoop => try pathMsg(
            allocator,
            context,
            "is reached through a symlink loop. Choose a path that does not traverse a circular symlink.",
        ),
        error.NoWorkingDirectory => try allocator.dupe(
            u8,
            "No working directory is set for this session, so a relative path cannot be resolved. Send an absolute path.",
        ),
        error.NoSpaceLeft => try allocator.dupe(
            u8,
            "The filesystem is full. Free space or write a smaller payload, then retry.",
        ),

        // ── file content ───────────────────────────────────────────────
        error.InputOutput => try allocator.dupe(
            u8,
            "The filesystem returned an I/O error. Retry once; if it repeats, report the blocker rather than resending the identical call.",
        ),
        error.WriteFailed => try pathMsg(
            allocator,
            context,
            "could not be written. Check that the parent directory exists and is writable, then retry.",
        ),
        error.FileWriteFailed => try pathMsg(
            allocator,
            context,
            "could not be written. Check that the parent directory exists and is writable, then retry.",
        ),
        error.WriteTmpFailed => try allocator.dupe(
            u8,
            "The temporary file used for an atomic write could not be created. Check that the temp directory is writable, then retry.",
        ),
        error.UnlinkFailed => try allocator.dupe(
            u8,
            "A temporary file could not be removed after the write. The write itself may have succeeded — verify before retrying.",
        ),
        error.RenameFailed => try allocator.dupe(
            u8,
            "The atomic rename failed. Check that the destination directory is writable and that no other process holds the file.",
        ),
        error.MkdirFailed => try allocator.dupe(
            u8,
            "A directory could not be created. Check the parent path and its permissions, or send `create_with_dir=true` where the tool offers it.",
        ),
        error.RmdirFailed => try allocator.dupe(
            u8,
            "A directory could not be removed. It is probably not empty — remove its contents first.",
        ),
        error.DeleteFailed => try pathMsg(
            allocator,
            context,
            "could not be deleted. Check the path and its permissions, then retry.",
        ),
        error.ContentTooLarge => try allocator.dupe(
            u8,
            "The content was larger than the tool accepts. Split it into smaller writes.",
        ),
        error.FileTooLarge => try pathMsg(
            allocator,
            context,
            "is too large to read in one call. Read a range with `offset` / `limit`, or use `search` to find the part you need.",
        ),
        error.OffsetOutOfRange => try allocator.dupe(
            u8,
            "`offset` was past the end of the file. Read the file without `offset` first to learn its length, then request a range inside it.",
        ),
        error.BinaryFileNotText => try pathMsg(
            allocator,
            context,
            "is a binary file, not text — its bytes are not readable as source. Only png/jpeg/gif/webp images can be read (they come back as a picture you can see); for anything else, run a tool on it instead (`pdftotext`, `unzip -p`, `strings`, or a project script).",
        ),
        error.ImageTooLarge => try pathMsg(
            allocator,
            context,
            "is an image larger than the 4 MB inline cap. Downscale or re-capture it at a smaller size, then read it again.",
        ),
        error.OldStrNotFound => try allocator.dupe(
            u8,
            "`old_str` was not found in the file. Read the file first and copy the text exactly — whitespace, indentation and line endings must match.",
        ),
        error.OldStrNotUnique => try allocator.dupe(
            u8,
            "`old_str` matched more than once. Expand it with surrounding context so it matches exactly one place.",
        ),
        error.NothingToChange => try allocator.dupe(
            u8,
            "The requested change is already in place — there is nothing to update. No retry is needed.",
        ),

        // ── search / glob ──────────────────────────────────────────────
        error.EmptyPattern => try allocator.dupe(
            u8,
            "The pattern was empty. Send a non-empty pattern — an empty one is a caller mistake, not a 'no match' result.",
        ),
        error.WhitespaceOnlyPattern => try allocator.dupe(
            u8,
            "The pattern contained only whitespace. Send a real pattern.",
        ),
        error.PatternContainsNulByte => try allocator.dupe(
            u8,
            "The pattern contained a NUL (0x00) byte. Patterns must be valid UTF-8 with no embedded NULs.",
        ),
        error.GlobContainsNulByte => try allocator.dupe(
            u8,
            "The glob filter contained a NUL (0x00) byte. Globs must be valid UTF-8 with no embedded NULs.",
        ),
        error.InvalidBraceExpansion => try allocator.dupe(
            u8,
            "The glob pattern has unmatched braces (a `{` without its `}`). Fix the brace syntax, or drop the braces.",
        ),
        error.InvalidFileType => try allocator.dupe(
            u8,
            "`file_type` must be 'f', 'file', 'd' or 'directory' — or omitted for all types.",
        ),
        error.InvalidMaxResults => try allocator.dupe(
            u8,
            "`max_results` must be greater than 0. Omit the field to use the default.",
        ),
        error.InvalidMaxOutput => try allocator.dupe(
            u8,
            "`max_output` must be greater than 0. Omit the field to use the default.",
        ),
        error.MaxOutputTooLarge => try allocator.dupe(
            u8,
            "`max_output` exceeded the hard ceiling. Narrow the path or use a more specific pattern so less output is produced.",
        ),
        error.HeadAndTailMutuallyExclusive => try allocator.dupe(
            u8,
            "`head` and `tail` are mutually exclusive. Set only one and omit the other.",
        ),
        error.InvalidHeadTail => try allocator.dupe(
            u8,
            "`head` / `tail` must be greater than 0. Omit the flag (or use `max_results`) instead of passing 0, which would look like a no-match.",
        ),
        error.RegexParseError => try allocator.dupe(
            u8,
            "The pattern is not a valid regex. Check for unmatched parentheses, unescaped metacharacters, or an invalid character class.",
        ),
        error.StderrTooLong => try allocator.dupe(
            u8,
            "The tool's own diagnostics exceeded the output limit. Narrow the path or use a more specific pattern to reduce them.",
        ),
        error.OutputReadFailed => try allocator.dupe(
            u8,
            "The output stream could not be captured. Retry; if it persists, narrow the path or use a smaller result window.",
        ),
        error.RgNotFound => try allocator.dupe(
            u8,
            "ripgrep (`rg`) is missing: pabrik looks for its bundled `rg-pabrik` beside the pabrik binary, then in pabrik's data dir, then `rg` on PATH. Reinstalling pabrik restores the bundled copy; `PABRIK_RG_BIN` points at an existing one. Until then use `glob` / `list_directory`, which do not need it.",
        ),
        error.Timeout => try allocator.dupe(
            u8,
            "The call hit its deadline. Narrow the path, use a more specific pattern, or raise the timeout where the tool exposes one.",
        ),
        error.PathError => try allocator.dupe(
            u8,
            "The path could not be accessed. Verify it exists, is readable, and that `cwd` is set correctly.",
        ),
        error.PathDoesNotExist => try pathMsg(
            allocator,
            context,
            "does not exist or is not a directory. Verify the path and that it points at a directory rather than a file.",
        ),

        // ── identity / lookup ──────────────────────────────────────────
        error.NotFound => try allocator.dupe(
            u8,
            "The requested item does not exist. Check the identifier and retry, or list the available items first.",
        ),
        error.RowMissing => try allocator.dupe(
            u8,
            "The requested row does not exist. Check the identifier and retry, or list the available items first.",
        ),
        error.NoRow => try allocator.dupe(
            u8,
            "The query returned no row. Check the identifier and retry, or list the available items first.",
        ),
        error.SessionNotFound => try allocator.dupe(
            u8,
            "The session does not exist. Check the session id, or list the available sessions first.",
        ),
        error.TaskNotFound => try allocator.dupe(
            u8,
            "The task does not exist. Check the task id, or list the board's tasks first.",
        ),
        error.PageNotFound => try allocator.dupe(
            u8,
            "The page does not exist. Check the page id, or list the available pages first.",
        ),
        error.ElementNotFound => try allocator.dupe(
            u8,
            "The element does not exist. Check the element id, or list the page's elements first.",
        ),
        error.ParentNotFound => try allocator.dupe(
            u8,
            "The parent element does not exist. Check the parent id, or list the page's elements first.",
        ),
        error.MarkerNotFound => try allocator.dupe(
            u8,
            "The marker was not found in the document. Re-read the document and use text that is actually present.",
        ),
        error.NoAssociatedPr => try allocator.dupe(
            u8,
            "No pull request or merge request is associated with this branch. Open one first, then retry.",
        ),
        error.NotARepository => try allocator.dupe(
            u8,
            "This directory is not a git repository. Run the command from inside a repository, or report the blocker.",
        ),
        error.CliMissing => try allocator.dupe(
            u8,
            "The forge CLI (`gh` or `glab`) is not installed or not on PATH. Install and authenticate it, then retry.",
        ),
        error.FetchFailed => try allocator.dupe(
            u8,
            "The remote request failed. Check network access and credentials, then retry — if it repeats, report the blocker.",
        ),
        error.GitCommandFailed => try allocator.dupe(
            u8,
            "The git command failed. Read the stderr in the result for the cause, fix it, then retry.",
        ),

        // ── validation ─────────────────────────────────────────────────
        error.InvalidInput => try allocator.dupe(
            u8,
            "The input was not valid for this tool. Check each field against the tool's parameter list and re-send.",
        ),
        error.InvalidContent => try allocator.dupe(
            u8,
            "The content was not valid for this tool. Check the field's documented format and re-send.",
        ),
        error.InvalidName => try allocator.dupe(
            u8,
            "The name was not valid. Use a plain single-token name with no path separators.",
        ),
        error.NameTooLong => try allocator.dupe(
            u8,
            "The name was too long. Shorten it and retry.",
        ),
        error.BadName => try allocator.dupe(
            u8,
            "The name was not valid. Use a plain single-token name with no path separators.",
        ),
        error.ValueRequired => try allocator.dupe(
            u8,
            "A required value was empty. Send a non-empty value for that field.",
        ),
        error.IdsRequired => try allocator.dupe(
            u8,
            "At least one id is required. Send the ids you want to act on.",
        ),
        error.EmptyItems => try allocator.dupe(
            u8,
            "The list was empty. Send at least one item.",
        ),
        error.EmptyOption => try allocator.dupe(
            u8,
            "Every option must be a non-blank string. Remove blank entries and retry.",
        ),
        error.TooFewOptions => try allocator.dupe(
            u8,
            "At least two options are required. Add another option, or omit the list entirely for a free-text question.",
        ),
        error.TooManyOptions => try allocator.dupe(
            u8,
            "Too many options were sent. Reduce the list to the documented maximum.",
        ),
        error.HeaderTooLong => try allocator.dupe(
            u8,
            "The header was too long. Shorten it to the documented maximum and retry.",
        ),
        error.MissingQuestion => try allocator.dupe(
            u8,
            "`question` is required and must not be blank. Send the question text.",
        ),
        error.RecommendedNotAnOption => try allocator.dupe(
            u8,
            "`recommended` must exactly match one of the strings in `options`. Fix the spelling or drop the field.",
        ),
        error.MultiSelectWithoutOptions => try allocator.dupe(
            u8,
            "`multi_select` requires at least two options. Add the options, or set `multi_select` to false.",
        ),
        error.CycleDetected => try allocator.dupe(
            u8,
            "The requested move would create a cycle. Choose a target that is not a descendant of the item being moved.",
        ),
        error.UnsupportedCommand => try allocator.dupe(
            u8,
            "That command is not supported by this tool. Use a supported command, or a different tool.",
        ),
        error.UnsupportedFlag => try allocator.dupe(
            u8,
            "That flag is not supported by this tool. Drop the flag, or check the tool's description for the supported ones.",
        ),
        error.NotImplemented => try allocator.dupe(
            u8,
            "This capability is not implemented yet. Use a different tool for the same goal, or report the blocker.",
        ),

        // ── workspace / session scoping ────────────────────────────────
        error.WorkspaceIdRequired => try allocator.dupe(
            u8,
            "A workspace id is required for this call. The session's own workspace is used when the field is omitted — do not send one.",
        ),
        error.WorkspaceIdNameRequired => try allocator.dupe(
            u8,
            "Both a workspace id and a name are required. Send both, or omit both to use the session's own workspace.",
        ),
        error.WorkspaceIdInSchema => try allocator.dupe(
            u8,
            "`workspace_id` is not a field of this tool and was ignored. The session's own workspace is always used — remove the field.",
        ),
        error.InvalidSessionId => try allocator.dupe(
            u8,
            "The session id was not valid. Check the id and retry.",
        ),
        error.MissingTaskIdTag => try allocator.dupe(
            u8,
            "The task id tag was missing. Include the task id in the documented format and retry.",
        ),
        error.ItemPathMissing => try allocator.dupe(
            u8,
            "The item's path was missing. Re-list the item to get its path, then retry.",
        ),

        // ── sub-agents ─────────────────────────────────────────────────
        error.TooManySubAgents => try allocator.dupe(
            u8,
            "Too many sub-agents were requested in one call. Split them across several calls.",
        ),
        error.NoSubAgents => try allocator.dupe(
            u8,
            "No sub-agents were requested. Send at least one.",
        ),
        error.EmptySubAgentTools => try allocator.dupe(
            u8,
            "A sub-agent was given an empty tool list. Give it at least one tool, or omit the field for the default set.",
        ),
        error.MissingSubAgentTools => try allocator.dupe(
            u8,
            "A sub-agent's tool list was missing. Send the tools it should have, or omit the field for the default set.",
        ),
        error.MissingSubAgentsField => try allocator.dupe(
            u8,
            "The `sub_agents` field was missing. Send the list of sub-agents to run.",
        ),
        error.InvalidSubAgentsFormat => try allocator.dupe(
            u8,
            "The `sub_agents` field was not in the expected format. Check the tool's description for the shape and re-send.",
        ),
        error.MissingSubAgentAgentName => try allocator.dupe(
            u8,
            "A sub-agent's `agent_name` was missing. Send the name of the agent it should run as.",
        ),
        error.MissingSubAgentInstruction => try allocator.dupe(
            u8,
            "A sub-agent's `instruction` was missing. Send what it should do.",
        ),
        error.MainAgentOnlyToolNotAllowed => try allocator.dupe(
            u8,
            "That tool is main-agent-only and cannot be given to a sub-agent. Remove it from the sub-agent's tool list.",
        ),
        error.AllToolsNotAllowed => try allocator.dupe(
            u8,
            "A sub-agent cannot be given every tool. List the specific tools it needs.",
        ),

        // ── skills ─────────────────────────────────────────────────────
        error.NoAssets => try allocator.dupe(
            u8,
            "The skill has no companion files, so there is no asset directory to materialise. Reference the skill's inline content instead.",
        ),
        error.InvalidSkillName => try allocator.dupe(
            u8,
            "The skill name is not a legal single token. Use a plain name with no path separators.",
        ),
        error.UnsafeAssetPath => try allocator.dupe(
            u8,
            "An asset path escapes the skill's directory (or is absolute, or uses a backslash). Send a relative path inside the skill.",
        ),
        error.CannotCreateTempDir => try allocator.dupe(
            u8,
            "No temporary directory could be created for the skill bundle. Check that the temp root is writable, then retry.",
        ),
        error.NoSkillSave => try allocator.dupe(
            u8,
            "The skill could not be saved. Check the name and content, then retry.",
        ),

        // ── network / transport ────────────────────────────────────────
        error.Transport => try allocator.dupe(
            u8,
            "The network request failed (DNS, TLS or timeout). Check connectivity and retry; if it repeats, report the blocker.",
        ),
        error.TargetUnreachable => try allocator.dupe(
            u8,
            "The target host could not be reached. Check the URL and network access, then retry.",
        ),
        error.RecvTimeout => try allocator.dupe(
            u8,
            "The response timed out. Retry; if it repeats, narrow the request or report the blocker.",
        ),
        error.SendTimeout => try allocator.dupe(
            u8,
            "The request timed out before it was sent. Retry; if it repeats, report the blocker.",
        ),
        error.ResponseTooLarge => try allocator.dupe(
            u8,
            "The response was larger than the tool accepts. Narrow the request so less data comes back.",
        ),
        error.InsecureScheme => try allocator.dupe(
            u8,
            "The URL scheme is not secure. Use `https://`.",
        ),
        error.NonPublicHost => try allocator.dupe(
            u8,
            "The URL points at a host that is not publicly reachable. Use a public URL.",
        ),
        error.UnsafePinnedUrl => try allocator.dupe(
            u8,
            "The pinned URL is not safe to send a credential to. Fix the URL, or unpin the credential.",
        ),
        error.AmbiguousUrl => try allocator.dupe(
            u8,
            "The URL was ambiguous. Send one complete, unambiguous URL.",
        ),
        error.InvalidUrl => try allocator.dupe(
            u8,
            "The URL was not valid. Send a complete URL including the scheme.",
        ),
        error.MissingUrl => try allocator.dupe(
            u8,
            "`url` is required. Send the URL to fetch.",
        ),
        error.UnknownProvider => try allocator.dupe(
            u8,
            "No web-search provider by that name is configured (or it is disabled). Call `list_web_search_providers` to see the available ones.",
        ),
        error.InvalidCurl => try allocator.dupe(
            u8,
            "The provider's curl template could not be parsed. Fix the provider configuration, then retry.",
        ),
        error.HostNotPinned => try allocator.dupe(
            u8,
            "The request host is not the host the provider pinned. Fix the provider configuration, then retry.",
        ),
        error.HeaderInjection => try allocator.dupe(
            u8,
            "A header value contained a newline, which would inject an extra header. Remove the newline and retry.",
        ),
        error.MalformedHeader => try allocator.dupe(
            u8,
            "A header was malformed. Send headers as `Name: value` pairs.",
        ),
        error.TooManyHeaders => try allocator.dupe(
            u8,
            "Too many headers were sent. Reduce the list and retry.",
        ),

        // ── images ─────────────────────────────────────────────────────
        error.InvalidImageUrl => try allocator.dupe(
            u8,
            "An image URL was not valid. Send a complete URL to a reachable image.",
        ),
        error.InvalidBase64 => try allocator.dupe(
            u8,
            "The base64 payload was not valid. Re-encode the data and retry.",
        ),
        error.NoImagesReturned => try allocator.dupe(
            u8,
            "The provider returned no images. Retry with a different prompt, or report the blocker.",
        ),
        error.ImageUrlsTooLarge => try allocator.dupe(
            u8,
            "Too many image URLs were sent. Reduce the list and retry.",
        ),

        // ── database ───────────────────────────────────────────────────
        error.DbError => try allocator.dupe(
            u8,
            "The database returned an error. Retry once; if it repeats, report the blocker with the error name.",
        ),
        error.QueryFailed => try allocator.dupe(
            u8,
            "The database query failed. Retry once; if it repeats, report the blocker with the error name.",
        ),
        error.InsertFailed => try allocator.dupe(
            u8,
            "The row could not be inserted. Check the field values and retry.",
        ),
        error.UpdateFailed => try allocator.dupe(
            u8,
            "The row could not be updated. Check the identifier and field values, then retry.",
        ),
        error.SeedFailed => try allocator.dupe(
            u8,
            "The seed data could not be written. Retry once; if it repeats, report the blocker.",
        ),
        error.SeedDocumentFailed => try allocator.dupe(
            u8,
            "The seed document could not be written. Retry once; if it repeats, report the blocker.",
        ),
        error.SeedSessionFailed => try allocator.dupe(
            u8,
            "The seed session could not be written. Retry once; if it repeats, report the blocker.",
        ),

        // ── MCP ────────────────────────────────────────────────────────
        error.FailedToCallMCPServer => try allocator.dupe(
            u8,
            "The MCP server could not be called. Check that it is running and reachable, then retry.",
        ),
        error.MCPJSONParseError => try allocator.dupe(
            u8,
            "The MCP server's response was not valid JSON. Retry; if it repeats, the server is misbehaving — report the blocker.",
        ),
        error.MCPInvalidResponse => try allocator.dupe(
            u8,
            "The MCP server's response did not match the expected shape. Retry; if it repeats, report the blocker.",
        ),
        error.DuplicateServer => try allocator.dupe(
            u8,
            "An MCP server with that name is already registered. Choose a different name, or update the existing server.",
        ),
        error.InvalidJson => try allocator.dupe(
            u8,
            "The JSON payload was not valid. Fix the JSON and retry.",
        ),

        // ── the guest substrate (--saas) ───────────────────────────────
        error.GuestWorkspaceUnknown => try allocator.dupe(
            u8,
            "This session does not resolve to a workspace, and in SaaS mode every command runs inside its workspace's VM — so there is nowhere to run it. Re-send the call from a session whose cwd is inside a workspace, or report the blocker.",
        ),
        error.GuestCwdOutsideWorkspace => try allocator.dupe(
            u8,
            "`cwd` is outside this session's workspace. In SaaS mode a workspace is its own VM, so a command can only run at or below the workspace root — send a `cwd` inside the workspace.",
        ),
        error.GuestManagerUnavailable => try allocator.dupe(
            u8,
            "`pabrik-vmd`, the process that owns the workspace VMs, is not reachable. Start it (`pabrik-vmd serve`), or point PABRIK_VMD_SOCKET at its socket, then retry. Nothing was run on the host.",
        ),
        error.GuestWorkspaceNotVm => try allocator.dupe(
            u8,
            "This workspace is not a VM workspace, so it has no microVM to run in — and SaaS mode never runs a workspace on the host. Create the workspace from a SaaS-mode server, or report the blocker.",
        ),
        error.GuestManagerRefused => try allocator.dupe(
            u8,
            "The workspace VM manager refused the command (the VM failed to start, or the workspace is unavailable). Read `pabrik-vmd`'s log for the cause — the retry to try is a fresh `pabrik-vmd stop`/re-run, not the identical call.",
        ),

        error.GuestLogUnknown => try allocator.dupe(
            u8,
            "This job's log path is not one the workspace VM manager could have minted, so it cannot be read. Use action=\"list\" and start the command again.",
        ),
        error.GuestLogUnreadable => try allocator.dupe(
            u8,
            "The workspace VM could not read this job's log — the VM may have stopped, and stopping it ends its jobs. action=\"list\" shows what this session is still running.",
        ),

        // ── fallback ───────────────────────────────────────────────────
        else => try fallback(allocator, err),
    };
}

/// Build a path-shaped message. When `context` is null the sentence
/// degrades to a generic one rather than printing `path '(null)'`.
fn pathMsg(allocator: std.mem.Allocator, context: ?[]const u8, detail: []const u8) ![]u8 {
    const path = context orelse "the requested path";
    return std.fmt.allocPrint(allocator, "Path '{s}' {s}", .{ path, detail });
}

/// The honest fallback: keep the raw error name so a human reading the
/// log can still identify it, and add the generic repair advice.
fn fallback(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "unexpected error `{s}`. {s}",
        .{ @errorName(err), FALLBACK_ADVICE },
    );
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "explain: TimeoutMissing names the field and the fix" {
    // The reported bug. The message must name the field, say why it is
    // required, and show what to send — none of which the bare
    // `TimeoutMissing` does.
    const msg = try explain(testing.allocator, error.TimeoutMissing, null);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "timeout") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "required") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "\"timeout\"") != null);
    // It must not be the bare error name.
    try testing.expect(!std.mem.eql(u8, msg, "TimeoutMissing"));
}

test "explain: TimeoutTooLarge states the ceiling and the alternative" {
    const msg = try explain(testing.allocator, error.TimeoutTooLarge, null);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "600 seconds or fewer") != null);
    // The way out has to be NAMED, not merely alluded to: `mode="background"`
    // is the current spelling of "detach and tell me when it finishes", and a
    // model that cannot see the field and the value has nothing to send.
    try testing.expect(std.mem.indexOf(u8, msg, "mode=\"background\"") != null);
}

test "explain: a path error interpolates the path it was given" {
    const msg = try explain(testing.allocator, error.FileNotFound, "/nope/missing.zig");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "/nope/missing.zig") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "not found") != null);
}

test "explain: a path error with no context still reads as a sentence" {
    // The null-context path must not print "(null)" or an empty path.
    const msg = try explain(testing.allocator, error.FileNotFound, null);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "(null)") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "''") == null);
    try testing.expect(msg.len > 0);
}

test "explain: JSON errors name the likely cause, not just the Zig name" {
    const syntax = try explain(testing.allocator, error.SyntaxError, null);
    defer testing.allocator.free(syntax);
    try testing.expect(std.mem.indexOf(u8, syntax, "JSON") != null);
    try testing.expect(std.mem.indexOf(u8, syntax, "backslash") != null);

    const missing = try explain(testing.allocator, error.MissingField, null);
    defer testing.allocator.free(missing);
    try testing.expect(std.mem.indexOf(u8, missing, "required field") != null);
}

test "explain: every mapped error produces a non-empty, non-bare message" {
    // The precedent: walk the errors this module claims to
    // explain and prove none of them falls through to a bare name.
    const errs = [_]anyerror{
        error.TimeoutMissing,
        error.TimeoutTooLarge,
        error.CommandForbidden,
        error.TooManyArgvPrefix,
        error.SyntaxError,
        error.UnexpectedEndOfInput,
        error.MissingField,
        error.UnknownField,
        error.UnexpectedToken,
        error.InvalidCharacter,
        error.Overflow,
        error.FileNotFound,
        error.PathNotFound,
        error.NotDir,
        error.IsDir,
        error.PathNotAbsolute,
        error.InvalidPath,
        error.PathTraversal,
        error.AccessDenied,
        error.PermissionDenied,
        error.PathAlreadyExists,
        error.InputOutput,
        error.WriteFailed,
        error.OffsetOutOfRange,
        error.OldStrNotFound,
        error.OldStrNotUnique,
        error.EmptyPattern,
        error.RegexParseError,
        error.RgNotFound,
        error.Timeout,
        error.NotFound,
        error.RowMissing,
        error.SessionNotFound,
        error.TaskNotFound,
        error.InvalidInput,
        error.ValueRequired,
        error.TooManyOptions,
        error.MissingQuestion,
        error.WorkspaceIdRequired,
        error.TooManySubAgents,
        error.InvalidSkillName,
        error.Transport,
        error.UnknownProvider,
        error.DbError,
        error.FailedToCallMCPServer,
    };
    for (errs) |e| {
        const msg = try explain(testing.allocator, e, "/some/path");
        defer testing.allocator.free(msg);
        try testing.expect(msg.len > 0);
        // Not the bare error name, and not the fallback sentence.
        try testing.expect(!std.mem.eql(u8, msg, @errorName(e)));
        try testing.expect(std.mem.indexOf(u8, msg, "unexpected error") == null);
    }
}

test "explain: an unmapped error still gets actionable advice" {
    // Positive control for the `else` prong: an error this module does
    // not map must keep its name (for the human reading the log) AND
    // carry the generic repair advice.
    const err = error.SomeErrorNoOneEverReturns;
    const msg = try explain(testing.allocator, err, null);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "SomeErrorNoOneEverReturns") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "Re-send the call") != null);
}

test "explain: no message leaks a raw Zig type name or a null pointer" {
    // A message that says `?[]const u8` or `(null)` is a bug the model
    // cannot act on. Sweep a representative set.
    const errs = [_]anyerror{
        error.TimeoutMissing,
        error.FileNotFound,
        error.SyntaxError,
        error.NotFound,
        error.Transport,
        error.DbError,
    };
    for (errs) |e| {
        const msg = try explain(testing.allocator, e, null);
        defer testing.allocator.free(msg);
        try testing.expect(std.mem.indexOf(u8, msg, "(null)") == null);
        try testing.expect(std.mem.indexOf(u8, msg, "[]const u8") == null);
        try testing.expect(std.mem.indexOf(u8, msg, "@errorName") == null);
    }
}
