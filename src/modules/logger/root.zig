const logger = @import("Logger.zig");

pub const LogLevel = logger.LogLevel;
pub const LogEntry = logger.LogEntry;
pub const Formatter = logger.Formatter;
pub const TextFormatter = logger.TextFormatter;
pub const JsonFormatter = logger.JsonFormatter;
pub const ColorFormatter = logger.ColorFormatter;
pub const AnsiColors = logger.AnsiColors;
pub const getAgentColor = logger.getAgentColor;

pub const RequestId = logger.RequestId;
pub const SessionId = logger.SessionId;
pub const generateRequestId = logger.generateRequestId;
pub const generateSessionId = logger.generateSessionId;

pub const timestampMs = logger.timestampMs;
pub const elapsedMs = logger.elapsedMs;
pub const formatDuration = logger.formatDuration;
pub const timestampIso = logger.timestampIso;
pub const timestampCompact = logger.timestampCompact;

pub const OutputMode = logger.OutputMode;
pub const LoggerConfig = logger.LoggerConfig;
pub const debugPrint = logger.debugPrint;
pub const Logger = logger.Logger;

pub const initGlobal = logger.initGlobal;
pub const initGlobalColor = logger.initGlobalColor;
pub const deinitGlobal = logger.deinitGlobal;
pub const getGlobal = logger.getGlobal;

test {
    _ = @import("test_runner.zig");
}
