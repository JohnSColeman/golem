package fixtures.tools

import cloud.golem.annotations.Arg
import cloud.golem.annotations.ArgKind
import cloud.golem.annotations.Constraint
import cloud.golem.annotations.Example
import cloud.golem.annotations.Implies
import cloud.golem.annotations.Repeat
import cloud.golem.annotations.ToolAnnotations
import cloud.golem.annotations.ToolCommand
import cloud.golem.annotations.ToolDefinition
import cloud.golem.annotations.ToolError
import cloud.golem.annotations.ToolErrorKind
import cloud.golem.annotations.ToolResult
import cloud.golem.runtime.Either

sealed class PublicError {
    @ToolError(kind = ToolErrorKind.RUNTIME, exitCode = 1)
    data class Rejected(val message: String) : PublicError()
}

sealed class BackendError {
    @ToolError(kind = ToolErrorKind.RUNTIME, exitCode = 1)
    data class Failed(val message: String) : BackendError()
}

@ToolDefinition(name = "public-echo", version = "1.2.3")
interface PublicEcho {
    fun echo(value: String): Either<PublicError, String>
}

@ToolDefinition(name = "backend-echo", version = "4.5.6")
interface BackendEcho {
    fun execute(encoded: String): Either<BackendError, Long>
}

@ToolDefinition(name = "grep", version = "1.0.0")
interface Grep {
    @ToolCommand(description = "Searches files for a pattern")
    @Constraint(requiresAll = ["pattern"], implies = [Implies(lhs = ["case-sensitive"], rhs = ["context=2"])])
    @ToolResult(formatters = ["human", "json"], default = "json")
    @Example(body = "grep foo src/", title = "basic")
    @ToolAnnotations(readOnly = true, destructive = false)
    fun search(
        pattern: String,
        @Arg(kind = ArgKind.FLAG, short = 'c', negatable = true) caseSensitive: Boolean,
        @Arg(kind = ArgKind.OPTION, short = 'm') maxCount: Int?,
        @Arg(kind = ArgKind.OPTION, default = "2") context: Int,
        @Arg(kind = ArgKind.OPTION, repeatable = Repeat.DELIMITED, delim = ',') include: List<String>,
        @Arg(kind = ArgKind.COUNT_FLAG, maxItems = 3) verbose: UInt,
        @Arg(kind = ArgKind.TAIL) paths: List<String>,
    ): List<String>
}

@ToolDefinition(name = "git", version = "0.1.0")
interface Git {
    @ToolCommand(description = "Manage the set of remotes")
    fun remote(@Arg(kind = ArgKind.FLAG) verbose: Boolean, @Arg(kind = ArgKind.OPTION) dir: String?): GitRemote
}

@ToolDefinition(name = "git-remote", version = "0.1.0")
interface GitRemote {
    fun add(name: String, url: String): String
}

@ToolDefinition(name = "filter", version = "0.1.0")
interface Filter {
    @ToolCommand(stdin = true, stdout = true, stderr = true)
    fun lines(pattern: String): Int
}
