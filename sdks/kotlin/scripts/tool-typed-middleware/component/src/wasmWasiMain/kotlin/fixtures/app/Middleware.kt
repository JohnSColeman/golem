package fixtures.app

import cloud.golem.annotations.Tool
import cloud.golem.annotations.ToolMiddleware
import cloud.golem.runtime.Either
import cloud.golem.runtime.ToolInvokeError
import cloud.golem.runtime.ToolRpc
import cloud.golem.runtime.mapTool
import fixtures.tools.BackendEchoUnderlying
import fixtures.tools.FilterMiddleware
import fixtures.tools.FilterUnderlying
import fixtures.tools.GitMiddleware
import fixtures.tools.GitUnderlying
import fixtures.tools.GrepMiddleware
import fixtures.tools.GrepUnderlying
import fixtures.tools.PublicEchoAdapter
import fixtures.tools.PublicEchoClient
import fixtures.tools.PublicEchoMiddleware
import fixtures.tools.PublicEchoUnderlying
import fixtures.tools.PublicError

/** Transparent: presents and wraps `public-echo`; commands it does not override pass straight through. */
@ToolMiddleware(name = "audit-echo")
class AuditEcho : PublicEchoMiddleware() {
    override fun echo(underlying: PublicEchoUnderlying, value: String) = underlying.echo(value)
}

/** Transparent over a definition with options, flags and a tail. */
@ToolMiddleware(name = "audit-grep")
class AuditGrep : GrepMiddleware() {
    override fun search(
        underlying: GrepUnderlying,
        pattern: String,
        caseSensitive: Boolean,
        maxCount: Int?,
        context: Int,
        include: List<String>,
        verbose: UInt,
        paths: List<String>,
    ) = underlying.search(pattern, caseSensitive, maxCount, context, include, verbose, paths)
}

/** Transparent over a command with stdin, stdout and stderr: stdin is forwarded and the outputs travel back with the value. */
@ToolMiddleware(name = "audit-filter")
class AuditFilter : FilterMiddleware() {
    override fun lines(underlying: FilterUnderlying, pattern: String, stdin: cloud.golem.runtime.ToolStdin?) =
        underlying.startLines(pattern, stdin).also { it.forwardOutputs(callerStdout, callerStderr) }.await()
}

/** Starts two calls before awaiting either, and answers with the first. */
@ToolMiddleware(name = "dual-echo")
class DualEcho : PublicEchoMiddleware() {
    override fun echo(underlying: PublicEchoUnderlying, value: String): Either<ToolInvokeError<PublicError>, String> {
        val first = underlying.startEcho(value)
        val second = underlying.startEcho("$value!")
        val answer = first.await()
        second.cancel()
        return answer
    }
}

/** Transparent over a command group with global options. */
@ToolMiddleware(name = "audit-git")
class AuditGit : GitMiddleware() {
    override fun remoteAdd(underlying: GitUnderlying, verbose: Boolean, dir: String?, name: String, url: String) =
        underlying.remote(verbose, dir).add(name, url)
}

data class Prefix(val text: String)

/** Adapter: presents `public-echo` while wrapping `backend-echo`. */
@ToolMiddleware(name = "backend-echo-adapter", parameters = Prefix::class)
class EchoAdapter : PublicEchoAdapter<BackendEchoUnderlying>() {
    override fun echo(underlying: BackendEchoUnderlying, value: String): Either<ToolInvokeError<PublicError>, String> =
        underlying.execute("${parameters<Prefix>().text}:$value")
            .mapTool { PublicError.Rejected(it.toString()) }
            .let { result ->
                when (result) {
                    is Either.Right -> Either.Right(result.value.toString())
                    is Either.Left -> Either.Left(result.value)
                }
            }
}

/** A typed call into the `public-echo` tool through the generated client. */
@Tool(name = "typed-caller", description = "Calls public-echo through the generated typed client")
fun typedCaller(value: String): String {
    val rpc = ToolRpc("public-echo")
    return when (val r = PublicEchoClient(rpc).echo(value)) {
        is Either.Right -> r.value
        is Either.Left -> "failed: ${r.value}"
    }
}
