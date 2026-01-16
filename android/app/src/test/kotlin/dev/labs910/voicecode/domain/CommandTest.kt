package dev.labs910.voicecode.domain

import dev.labs910.voicecode.domain.model.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

/**
 * Tests for Command domain models.
 */
class CommandTest {

    @Test
    fun `Command isGroup returns true for group type with children`() {
        val command = Command(
            id = "docker",
            label = "Docker",
            type = CommandType.GROUP,
            children = listOf(
                Command(id = "docker.up", label = "Up", type = CommandType.COMMAND),
                Command(id = "docker.down", label = "Down", type = CommandType.COMMAND)
            )
        )

        assertTrue(command.isGroup)
    }

    @Test
    fun `Command isGroup returns false for group type without children`() {
        val command = Command(
            id = "docker",
            label = "Docker",
            type = CommandType.GROUP,
            children = emptyList()
        )

        assertFalse(command.isGroup)
    }

    @Test
    fun `Command isGroup returns false for command type`() {
        val command = Command(
            id = "build",
            label = "Build",
            type = CommandType.COMMAND
        )

        assertFalse(command.isGroup)
    }

    @Test
    fun `Command flatten returns self for non-group`() {
        val command = Command(
            id = "build",
            label = "Build",
            type = CommandType.COMMAND
        )

        val flattened = command.flatten()

        assertEquals(1, flattened.size)
        assertEquals(command, flattened[0])
    }

    @Test
    fun `Command flatten includes all children for group`() {
        val child1 = Command(id = "docker.up", label = "Up", type = CommandType.COMMAND)
        val child2 = Command(id = "docker.down", label = "Down", type = CommandType.COMMAND)
        val command = Command(
            id = "docker",
            label = "Docker",
            type = CommandType.GROUP,
            children = listOf(child1, child2)
        )

        val flattened = command.flatten()

        assertEquals(3, flattened.size)
        assertEquals(command, flattened[0])
        assertEquals(child1, flattened[1])
        assertEquals(child2, flattened[2])
    }

    @Test
    fun `Command flatten handles nested groups`() {
        val leaf = Command(id = "a.b.c", label = "Leaf", type = CommandType.COMMAND)
        val innerGroup = Command(
            id = "a.b",
            label = "Inner",
            type = CommandType.GROUP,
            children = listOf(leaf)
        )
        val outerGroup = Command(
            id = "a",
            label = "Outer",
            type = CommandType.GROUP,
            children = listOf(innerGroup)
        )

        val flattened = outerGroup.flatten()

        assertEquals(3, flattened.size)
        assertEquals("a", flattened[0].id)
        assertEquals("a.b", flattened[1].id)
        assertEquals("a.b.c", flattened[2].id)
    }

    @Test
    fun `CommandType fromString handles all cases`() {
        assertEquals(CommandType.COMMAND, CommandType.fromString("command"))
        assertEquals(CommandType.COMMAND, CommandType.fromString("COMMAND"))
        assertEquals(CommandType.GROUP, CommandType.fromString("group"))
        assertEquals(CommandType.GROUP, CommandType.fromString("GROUP"))
        assertEquals(CommandType.COMMAND, CommandType.fromString("unknown")) // Default
    }

    @Test
    fun `CommandExecution outputPreview truncates long output`() {
        val execution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "test",
            shellCommand = "echo test",
            workingDirectory = "/tmp",
            startTime = Instant.now()
        )

        execution.output.append("A".repeat(300))

        val preview = execution.outputPreview

        assertTrue(preview.length <= 203) // 200 + "..."
        assertTrue(preview.endsWith("..."))
    }

    @Test
    fun `CommandExecution outputPreview returns full output if short`() {
        val execution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "test",
            shellCommand = "echo test",
            workingDirectory = "/tmp",
            startTime = Instant.now()
        )

        execution.output.append("Short output")

        assertEquals("Short output", execution.outputPreview)
    }

    @Test
    fun `CommandExecution isSuccess checks exit code`() {
        val successExecution = CommandExecution(
            commandSessionId = "cmd-123",
            commandId = "test",
            shellCommand = "echo test",
            workingDirectory = "/tmp",
            startTime = Instant.now(),
            exitCode = 0
        )

        val failedExecution = CommandExecution(
            commandSessionId = "cmd-456",
            commandId = "test",
            shellCommand = "false",
            workingDirectory = "/tmp",
            startTime = Instant.now(),
            exitCode = 1
        )

        assertTrue(successExecution.isSuccess)
        assertFalse(failedExecution.isSuccess)
    }

    @Test
    fun `OutputStreamType fromString handles all cases`() {
        assertEquals(OutputStreamType.STDOUT, OutputStreamType.fromString("stdout"))
        assertEquals(OutputStreamType.STDOUT, OutputStreamType.fromString("STDOUT"))
        assertEquals(OutputStreamType.STDERR, OutputStreamType.fromString("stderr"))
        assertEquals(OutputStreamType.STDERR, OutputStreamType.fromString("STDERR"))
        assertEquals(OutputStreamType.STDOUT, OutputStreamType.fromString("unknown")) // Default
    }
}
