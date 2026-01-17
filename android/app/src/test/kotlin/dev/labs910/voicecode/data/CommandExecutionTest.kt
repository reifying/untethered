package dev.labs910.voicecode.data

import dev.labs910.voicecode.domain.model.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

/**
 * Tests for command execution state management.
 * Mirrors iOS CommandExecutionStateTests.swift.
 */
class CommandExecutionTest {

    @Test
    fun `CommandExecution initialization has correct defaults`() {
        val execution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "git.status",
            shellCommand = "git status",
            workingDirectory = "/Users/test/project",
            startTime = Instant.now()
        )

        assertEquals("cmd-123", execution.commandSessionId)
        assertEquals("git.status", execution.commandId)
        assertEquals("git status", execution.shellCommand)
        assertEquals("/Users/test/project", execution.workingDirectory)
        assertEquals(CommandExecutionStatus.RUNNING, execution.status)
        assertTrue(execution.output.isEmpty())
        assertNull(execution.exitCode)
        assertNull(execution.durationMs)
        assertNull(execution.endTime)
    }

    @Test
    fun `CommandExecution can append output`() {
        val execution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "test",
            shellCommand = "echo test",
            workingDirectory = "/tmp",
            startTime = Instant.now()
        )

        execution.output.append("Line 1\n")
        execution.output.append("Line 2\n")

        assertTrue(execution.output.toString().contains("Line 1"))
        assertTrue(execution.output.toString().contains("Line 2"))
    }

    @Test
    fun `CommandExecution completed with exit code 0 is success`() {
        val execution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "test",
            shellCommand = "echo test",
            workingDirectory = "/tmp",
            startTime = Instant.now(),
            exitCode = 0,
            status = CommandExecutionStatus.COMPLETED
        )

        assertTrue(execution.isSuccess)
        assertEquals(CommandExecutionStatus.COMPLETED, execution.status)
    }

    @Test
    fun `CommandExecution completed with non-zero exit code is not success`() {
        val execution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "test",
            shellCommand = "false",
            workingDirectory = "/tmp",
            startTime = Instant.now(),
            exitCode = 1,
            status = CommandExecutionStatus.FAILED
        )

        assertFalse(execution.isSuccess)
        assertEquals(CommandExecutionStatus.FAILED, execution.status)
    }

    @Test
    fun `CommandExecution with exit code 127 indicates command not found`() {
        val execution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "nonexistent",
            shellCommand = "nonexistent-command",
            workingDirectory = "/tmp",
            startTime = Instant.now(),
            exitCode = 127,
            status = CommandExecutionStatus.FAILED
        )

        assertEquals(127, execution.exitCode)
        assertFalse(execution.isSuccess)
    }

    @Test
    fun `CommandExecution tracks duration`() {
        val execution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "test",
            shellCommand = "sleep 1",
            workingDirectory = "/tmp",
            startTime = Instant.now(),
            durationMs = 1234L
        )

        assertEquals(1234L, execution.durationMs)
    }

    @Test
    fun `Multiple CommandExecutions have independent state`() {
        val execution1 = CommandExecution(
            commandSessionId = "cmd-1",
            commandId = "git.status",
            shellCommand = "git status",
            workingDirectory = "/project1",
            startTime = Instant.now()
        )

        val execution2 = CommandExecution(
            commandSessionId = "cmd-2",
            commandId = "make.build",
            shellCommand = "make build",
            workingDirectory = "/project2",
            startTime = Instant.now()
        )

        execution1.output.append("Output 1")
        execution2.output.append("Output 2")

        assertNotEquals(execution1.commandSessionId, execution2.commandSessionId)
        assertTrue(execution1.output.toString().contains("Output 1"))
        assertFalse(execution1.output.toString().contains("Output 2"))
        assertTrue(execution2.output.toString().contains("Output 2"))
        assertFalse(execution2.output.toString().contains("Output 1"))
    }

    @Test
    fun `CommandExecution preserves working directory with spaces`() {
        val pathWithSpaces = "/Users/test/My Projects/voice-code"
        val execution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "test",
            shellCommand = "ls",
            workingDirectory = pathWithSpaces,
            startTime = Instant.now()
        )

        assertEquals(pathWithSpaces, execution.workingDirectory)
    }

    @Test
    fun `CommandExecution outputPreview handles empty output`() {
        val execution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "test",
            shellCommand = "true",
            workingDirectory = "/tmp",
            startTime = Instant.now()
        )

        assertEquals("", execution.outputPreview)
    }

    @Test
    fun `CommandExecution outputPreview handles exactly 200 chars`() {
        val execution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "test",
            shellCommand = "echo test",
            workingDirectory = "/tmp",
            startTime = Instant.now()
        )

        execution.output.append("A".repeat(200))

        assertEquals(200, execution.outputPreview.length)
        assertFalse(execution.outputPreview.endsWith("..."))
    }

    @Test
    fun `CommandExecution status enum has all expected values`() {
        val statuses = CommandExecutionStatus.values()

        assertEquals(3, statuses.size)
        assertTrue(statuses.contains(CommandExecutionStatus.RUNNING))
        assertTrue(statuses.contains(CommandExecutionStatus.COMPLETED))
        assertTrue(statuses.contains(CommandExecutionStatus.FAILED))
    }

    @Test
    fun `OutputStreamType distinguishes stdout from stderr`() {
        assertEquals(OutputStreamType.STDOUT, OutputStreamType.fromString("stdout"))
        assertEquals(OutputStreamType.STDERR, OutputStreamType.fromString("stderr"))
    }

    @Test
    fun `CommandExecution can track concurrent commands`() {
        val executions = mutableMapOf<String, CommandExecution>()
        val now = Instant.now()

        // Simulate 10 concurrent commands
        repeat(10) { i ->
            val sessionId = "cmd-$i"
            executions[sessionId] = CommandExecution(
                commandSessionId = sessionId,
                commandId = "command.$i",
                shellCommand = "echo $i",
                workingDirectory = "/tmp",
                startTime = now
            )
        }

        assertEquals(10, executions.size)

        // Verify all session IDs are unique
        val sessionIds = executions.keys.toSet()
        assertEquals(10, sessionIds.size)

        // Verify each execution can be accessed independently
        executions["cmd-5"]?.output?.append("Output from command 5")
        assertEquals("Output from command 5", executions["cmd-5"]?.output.toString())
        assertEquals("", executions["cmd-0"]?.output.toString())
    }
}
