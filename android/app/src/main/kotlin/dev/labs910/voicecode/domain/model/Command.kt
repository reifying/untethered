package dev.labs910.voicecode.domain.model

import java.time.Instant

/**
 * Domain model for a shell command.
 * Corresponds to iOS Command.swift model.
 */
data class Command(
    val id: String,
    val label: String,
    val type: CommandType,
    val description: String? = null,
    val children: List<Command>? = null
) {
    /**
     * Whether this command has child commands (is a group).
     */
    val isGroup: Boolean get() = type == CommandType.GROUP && !children.isNullOrEmpty()

    /**
     * Flattened list of all commands including children.
     */
    fun flatten(): List<Command> {
        return if (isGroup) {
            listOf(this) + (children?.flatMap { it.flatten() } ?: emptyList())
        } else {
            listOf(this)
        }
    }
}

/**
 * Command type.
 */
enum class CommandType {
    COMMAND,
    GROUP;

    companion object {
        fun fromString(value: String): CommandType = when (value.lowercase()) {
            "command" -> COMMAND
            "group" -> GROUP
            else -> COMMAND
        }
    }
}

/**
 * A command execution session.
 */
data class CommandExecution(
    val commandSessionId: String,
    val commandId: String,
    val shellCommand: String,
    val workingDirectory: String,
    val startTime: Instant,
    val endTime: Instant? = null,
    val exitCode: Int? = null,
    val durationMs: Long? = null,
    val output: StringBuilder = StringBuilder(),
    val status: CommandExecutionStatus = CommandExecutionStatus.RUNNING
) {
    /**
     * Preview of the output (first 200 chars).
     */
    val outputPreview: String
        get() {
            val text = output.toString()
            return if (text.length <= 200) text else text.take(200) + "..."
        }

    /**
     * Whether the command completed successfully.
     */
    val isSuccess: Boolean get() = exitCode == 0
}

/**
 * Command execution status.
 */
enum class CommandExecutionStatus {
    RUNNING,
    COMPLETED,
    FAILED
}

/**
 * Output stream type.
 */
enum class OutputStreamType {
    STDOUT,
    STDERR;

    companion object {
        fun fromString(value: String): OutputStreamType = when (value.lowercase()) {
            "stdout" -> STDOUT
            "stderr" -> STDERR
            else -> STDOUT
        }
    }
}
