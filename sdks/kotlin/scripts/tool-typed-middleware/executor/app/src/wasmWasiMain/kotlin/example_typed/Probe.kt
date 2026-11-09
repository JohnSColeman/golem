package example_typed

import cloud.golem.BaseAgent
import cloud.golem.annotations.Agent
import cloud.golem.annotations.Arg
import cloud.golem.annotations.ArgKind
import cloud.golem.annotations.Repeat
import cloud.golem.annotations.Constraint
import cloud.golem.annotations.Tool
import cloud.golem.annotations.ToolCommand
import cloud.golem.annotations.ToolErrorCase
import cloud.golem.annotations.ToolResult
import cloud.golem.annotations.Endpoint
import cloud.golem.annotations.ToolDefinition
import cloud.golem.annotations.ToolError
import cloud.golem.annotations.ToolErrorKind
import cloud.golem.annotations.ToolMiddleware
import cloud.golem.runtime.Either
import cloud.golem.runtime.PromiseId
import cloud.golem.runtime.SchemaValue
import cloud.golem.runtime.ToolCustomError
import cloud.golem.runtime.ToolError as WireToolError
import cloud.golem.runtime.ToolFutureInvokeResult
import cloud.golem.runtime.ToolInvokeResult
import cloud.golem.runtime.ToolRpcError
import cloud.golem.runtime.ToolStreams
import cloud.golem.runtime.TypedSchemaValue
import cloud.golem.runtime.Promises
import cloud.golem.runtime.ToolRpc
import cloud.golem.runtime.Webhooks

@ToolDefinition(name = "middleware-probe", version = "1.0.0")
interface MiddlewareProbe {
    fun apply(value: String): String
    fun check(skuId: String): Either<ProbeError, String>
}

sealed class ProbeError {
    @ToolError(kind = ToolErrorKind.RUNTIME, exitCode = 3)
    data class Rejected(val message: String) : ProbeError()

    @ToolError(kind = ToolErrorKind.USAGE, exitCode = 4)
    object Gone : ProbeError()
}

@ToolMiddleware(name = "typed-audit")
class TypedAudit : MiddlewareProbeMiddleware() {
    override fun apply(underlying: MiddlewareProbeUnderlying, value: String): Either<cloud.golem.runtime.ToolInvokeError<Nothing>, String> =
        when (val r = underlying.apply("audit($value)")) {
            is Either.Right -> Either.Right("mw(${r.value})")
            is Either.Left -> Either.Left(r.value)
        }
}

@Agent(mount = "/probes/{name}", description = "Calls middleware-probe through the generated typed client")
class ProbeCaller(val name: String) : BaseAgent() {
    @Endpoint(post = "/probe")
    fun probe(value: String): String = when (val r = MiddlewareProbeClient(ToolRpc("middleware-probe")).apply(value)) {
        is Either.Right -> r.value
        is Either.Left -> "failed: ${r.value}"
    }

    @Endpoint(post = "/check")
    fun check(skuId: String): String = when (val r = MiddlewareProbeClient(ToolRpc("middleware-probe")).check(skuId)) {
        is Either.Right -> r.value
        is Either.Left -> when (val e = r.value) {
            is cloud.golem.runtime.ToolInvokeError.Tool -> "declared:${e.error}"
            else -> "protocol:$e"
        }
    }
}

@ToolDefinition(name = "backend-probe", version = "1.0.0")
interface BackendProbe {
    fun execute(encoded: String): Long
}

data class Prefix(val text: String)

@ToolMiddleware(name = "probe-adapter", parameters = Prefix::class)
class ProbeAdapter : MiddlewareProbeAdapter<BackendProbeUnderlying>() {
    override fun apply(underlying: BackendProbeUnderlying, value: String): Either<cloud.golem.runtime.ToolInvokeError<Nothing>, String> =
        when (val r = underlying.execute("${parameters<Prefix>().text}:$value")) {
            is Either.Right -> Either.Right("adapted(${r.value})")
            is Either.Left -> Either.Left(r.value)
        }

    override fun check(underlying: BackendProbeUnderlying, skuId: String): Either<cloud.golem.runtime.ToolInvokeError<ProbeError>, String> =
        if (skuId == "bad") {
            Either.Left(cloud.golem.runtime.ToolInvokeError.Tool(ProbeError.Rejected("adapter says no")))
        } else {
            Either.Right("adapter-check:$skuId")
        }
}

@ToolDefinition(name = "refined-probe", version = "1.0.0")
interface RefinedProbe {
    fun bounded(
        @Arg(min = "1", max = "10") level: Int,
        @Arg(kind = ArgKind.OPTION, default = "0.5", min = "0.25", max = "2") ratio: Double,
        @Arg(kind = ArgKind.OPTION, default = "ab", regex = "^[a-z]+$", minLength = 2, maxLength = 8) tag: String,
    ): String
}

@ToolMiddleware(name = "refined-adapter")
class RefinedAdapter : RefinedProbeAdapter<BackendProbeUnderlying>() {
    override fun bounded(underlying: BackendProbeUnderlying, level: Int, ratio: Double, tag: String): Either<cloud.golem.runtime.ToolInvokeError<Nothing>, String> =
        Either.Right("bounded(level=$level ratio=$ratio tag=$tag)")
}

@Agent(mount = "/refined/{name}", description = "Calls backend-probe through an adapter whose presented tool declares numeric bounds")
class RefinedCaller(val name: String) : BaseAgent() {
    @Endpoint(post = "/bounded")
    fun bounded(level: String, tag: String): String = when (val r = RefinedProbeClient(ToolRpc("backend-probe")).bounded(level.toInt(), 0.5, tag)) {
        is Either.Right -> r.value
        is Either.Left -> "failed:${r.value}"
    }

    @Endpoint(post = "/describe")
    fun describe(command: String): String {
        val body = cloud.golem.runtime.ToolHost.describe("backend-probe")?.find(listOf(command))?.body ?: return "no $command command"
        return body.arguments.joinToString(";") { "${it.name}:${it.witType}:min=${it.min}:max=${it.max}:len=${it.minLength}-${it.maxLength}:re=${it.regex}" }
    }
}

@Agent(mount = "/adapted/{name}", description = "Calls backend-probe through the adapter's presented shape")
class AdaptedCaller(val name: String) : BaseAgent() {
    @Endpoint(post = "/probe")
    fun probe(value: String): String = when (val r = MiddlewareProbeClient(ToolRpc("backend-probe")).apply(value)) {
        is Either.Right -> r.value
        is Either.Left -> "failed: ${r.value}"
    }

    @Endpoint(post = "/check")
    fun check(skuId: String): String = when (val r = MiddlewareProbeClient(ToolRpc("backend-probe")).check(skuId)) {
        is Either.Right -> r.value
        is Either.Left -> when (val e = r.value) {
            is cloud.golem.runtime.ToolInvokeError.Tool -> "declared:${e.error}"
            else -> "protocol:$e"
        }
    }
}

@ToolDefinition(name = "arg-probe", version = "1.0.0")
interface ArgProbe {
    @Constraint(requiresAll = ["pattern"])
    @ToolResult(formatters = ["json", "table"], default = "json")
    fun search(
        pattern: String,
        @Arg(kind = ArgKind.OPTION, short = 'm') maxCount: Int?,
        @Arg(kind = ArgKind.OPTION, default = "2") context: Int,
        @Arg(kind = ArgKind.OPTION, repeatable = Repeat.EITHER, delim = ',') include: List<String>,
        @Arg(kind = ArgKind.FLAG, short = 'c', negatable = true) caseSensitive: Boolean,
        @Arg(kind = ArgKind.COUNT_FLAG, maxItems = 3) verbose: UInt,
        @Arg(kind = ArgKind.TAIL) paths: List<String>,
    ): String

    fun ping(): String
}

/** Starts two calls before awaiting either, cancels the second, and prefixes the first answer. */
@ToolMiddleware(name = "arg-audit")
class ArgAudit : ArgProbeMiddleware() {
    override fun search(
        underlying: ArgProbeUnderlying,
        pattern: String,
        maxCount: Int?,
        context: Int,
        include: List<String>,
        caseSensitive: Boolean,
        verbose: UInt,
        paths: List<String>,
    ): Either<cloud.golem.runtime.ToolInvokeError<Nothing>, String> {
        val first = underlying.startSearch(pattern, maxCount, context, include, caseSensitive, verbose, paths)
        val second = underlying.startSearch("$pattern!", maxCount, context, include, caseSensitive, verbose, paths)
        val answer = first.await()
        second.cancel()
        return when (answer) {
            is Either.Right -> Either.Right("mw(${answer.value})")
            is Either.Left -> answer
        }
    }
}

@ToolDefinition(name = "stream-probe", version = "1.0.0")
interface StreamProbe {
    @ToolCommand(stdin = true, stdout = true)
    fun upper(): String

    fun plain(): String
}

/** Forwards stdin and streams the wrapped tool's stdout to the caller as it arrives. */
@ToolMiddleware(name = "stream-audit")
class StreamAudit : StreamProbeMiddleware() {
    override fun upper(underlying: StreamProbeUnderlying, stdin: cloud.golem.runtime.ToolStdin?) =
        underlying.startUpper(stdin).also { it.forwardOutputs(callerStdout, callerStderr) }.await()
}

@ToolDefinition(name = "git-probe", version = "1.0.0")
interface GitProbe {
    fun remote(@Arg(kind = ArgKind.FLAG) verbose: Boolean, @Arg(kind = ArgKind.OPTION) dir: String?): GitRemoteProbe

    fun status(): String
}

@ToolDefinition(name = "git-remote-probe", version = "1.0.0")
interface GitRemoteProbe {
    fun add(name: String, url: String): String

    fun list(): String
}

/** Transparent over a command group with global options. */
@ToolMiddleware(name = "git-audit")
class GitAudit : GitProbeMiddleware() {
    override fun remoteAdd(
        underlying: GitProbeUnderlying,
        verbose: Boolean,
        dir: String?,
        name: String,
        url: String,
    ): Either<cloud.golem.runtime.ToolInvokeError<Nothing>, String> = when (val r = underlying.remote(verbose, dir).add(name, url)) {
        is Either.Right -> Either.Right("mw(${r.value})")
        is Either.Left -> r
    }
}

@Agent(mount = "/args/{name}", description = "Calls arg-probe and stream-probe through the generated typed clients")
class ArgCaller(val name: String) : BaseAgent() {
    @Endpoint(post = "/search")
    fun search(pattern: String): String = when (
        val r = ArgProbeClient(ToolRpc("arg-probe")).search(pattern, 3, 5, listOf("a", "b"), true, 2u, listOf("x", "y"))
    ) {
        is Either.Right -> r.value
        is Either.Left -> "failed: ${r.value}"
    }

    @Endpoint(post = "/search-defaults")
    fun searchDefaults(pattern: String): String = when (
        val r = ArgProbeClient(ToolRpc("arg-probe")).search(pattern, null, 2, emptyList(), false, 0u, emptyList())
    ) {
        is Either.Right -> r.value
        is Either.Left -> "failed: ${r.value}"
    }

    @Endpoint(post = "/git-add")
    fun gitAdd(name: String): String = when (val r = GitProbeClient(ToolRpc("git-probe")).remote(true, "d1").add(name, "https://example.invalid/repo")) {
        is Either.Right -> r.value
        is Either.Left -> "failed: ${r.value}"
    }

    @Endpoint(post = "/describe")
    fun describe(tool: String): String = describeCommand(tool, "search")

    @Endpoint(post = "/upper")
    fun upper(text: String): String = when (val r = StreamProbeClient(ToolRpc("stream-probe")).upper(text.encodeToByteArray())) {
        is Either.Right -> "${r.value.stdout?.decodeToString()}|${r.value.value}"
        is Either.Left -> "failed: ${r.value}"
    }
}

@Agent(mount = "/webhooks/{name}", webhookSuffix = "/incoming", description = "Creates a webhook and awaits its payload")
class WebhookCaller(val name: String) : BaseAgent() {
    private var promise: PromiseId? = null

    @Endpoint(post = "/create")
    fun create(): String {
        val id = Promises.create()
        promise = id
        return Webhooks.create(id)
    }

    @Endpoint(post = "/await")
    fun awaitPayload(): String = Promises.await(promise ?: return "no pending webhook").decodeToString()
}

@Tool(
    name = "kt-lookup",
    description = "Looks a key up; declares two errors",
    errors = [
        ToolErrorCase("not-found", "No such key", usage = true, exitCode = 4),
        ToolErrorCase("over-limit", payload = Limit::class),
    ],
)
fun ktLookup(key: String): String {
    if (key.isEmpty()) throw ToolCustomError("not-found")
    if (key.length > 8) throw ToolCustomError("over-limit", SchemaValue.Record(listOf(SchemaValue.S32(8), SchemaValue.Str("too long"))))
    return key
}

data class Limit(val max: Int, val reason: String)

@Tool(name = "kt-upper", description = "Uppercases stdin", stdin = true, stdout = true, stderr = true)
fun ktUpper(mode: String, io: ToolStreams): Int {
    var total = 0
    while (true) {
        val chunk = io.stdin?.read() ?: break
        total += chunk.size
        io.stdout?.write(chunk.decodeToString().uppercase().encodeToByteArray())
    }
    io.stderr?.write("done:$total".encodeToByteArray())
    return total
}

@Agent(mount = "/ktools/{name}", description = "Calls Kotlin-provided tools through ToolRpc")
class KtToolsCaller(val name: String) : BaseAgent() {
    private fun record(vararg fields: Pair<String, String>) = TypedSchemaValue(
        "record<${fields.joinToString(",") { "${it.first}:string" }}>",
        SchemaValue.Record(fields.map { SchemaValue.Str(it.second) }),
    )

    private fun text(r: ToolInvokeResult): String = when (r) {
        is ToolInvokeResult.Ok -> (r.value.result?.value as? SchemaValue.Str)?.v ?: r.value.result?.value.toString()
        is ToolInvokeResult.Err -> when (val e = r.error) {
            is ToolRpcError.RemoteToolError -> when (val t = e.error) {
                is WireToolError.CustomError -> "custom:${t.name}:${t.payload.value}"
                else -> "tool-error:$t"
            }
            else -> "rpc-error:$e"
        }
    }

    @Endpoint(post = "/describe-rust")
    fun describeRust(tool: String, command: String): String = describeCommand(tool, command)

    @Endpoint(post = "/lookup")
    fun lookup(key: String): String = text(ToolRpc("kt-lookup").invokeAndAwait(emptyList(), record("key" to key)))

    @Endpoint(post = "/upper-n")
    fun upperN(size: String): String {
        val stdin = ByteArray(size.toInt()) { ('a'.code + (it % 26)).toByte() }
        val future = ToolRpc("kt-upper").asyncInvokeAndAwait(
            emptyList(),
            record("mode" to "m"),
            stdin = stdin,
            captureStdout = true,
            captureStderr = true,
        )
        return when (val r = future.get()) {
            is ToolInvokeResult.Ok -> "stdout=${r.value.stdout?.size}|stdoutFailure=${r.value.stdoutFailure?.let { it::class.simpleName }}|stderr=${r.value.stderr?.decodeToString()}|total=${(r.value.result?.value as? SchemaValue.S32)?.v}"
            is ToolInvokeResult.Err -> "failed:${r.error}"
        }
    }

    @Endpoint(post = "/upper-async")
    fun upperAsync(input: String): String {
        val future = ToolRpc("kt-upper").asyncInvokeAndAwait(
            emptyList(),
            record("mode" to "m"),
            stdin = input.encodeToByteArray(),
            captureStdout = true,
            captureStderr = true,
        )
        return when (val r = future.get()) {
            is ToolInvokeResult.Ok -> "${r.value.stdout?.decodeToString()}|${r.value.stderr?.decodeToString()}|${(r.value.result?.value as? SchemaValue.S32)?.v}"
            is ToolInvokeResult.Err -> "failed:${r.error}"
        }
    }

    @Endpoint(post = "/get-all")
    fun getAll(a: String): String {
        val rpc = ToolRpc("kt-lookup")
        val futures = listOf(rpc.asyncInvokeAndAwait(emptyList(), record("key" to a)), rpc.asyncInvokeAndAwait(emptyList(), record("key" to "")))
        return ToolFutureInvokeResult.getAll(futures).joinToString(",") { text(it) }
    }

    @Endpoint(post = "/fire")
    fun fire(input: String): String = ToolRpc("kt-upper").invoke(emptyList(), record("mode" to "m"), stdin = input.encodeToByteArray())?.let { "failed:$it" } ?: "admitted"
}

internal fun describeCommand(tool: String, command: String): String {
    val info = cloud.golem.runtime.ToolHost.describe(tool) ?: return "none"
    val body = info.find(listOf(command))?.body ?: return "no $command command"
    return body.arguments.joinToString(";") { a ->
        "${a.kind}:${a.name}:${a.shape}:${a.witType}:short=${a.short?.toChar()}:default=${a.default}:required=${a.required}"
    } + "|formatters=${body.formatters}/${body.defaultFormatter}|constraints=${body.constraints}"
}
