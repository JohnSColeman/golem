package contractprobe

import cloud.golem.BaseAgent
import cloud.golem.Datetime
import cloud.golem.annotations.Agent
import cloud.golem.annotations.Endpoint
import cloud.golem.annotations.FileMapping
import cloud.golem.annotations.Header
import cloud.golem.annotations.ResponseHeader
import cloud.golem.config.Config
import cloud.golem.annotations.HttpHandler
import cloud.golem.annotations.HttpRouter
import cloud.golem.annotations.OpenApiProvider
import cloud.golem.http.HttpHeader
import cloud.golem.http.HttpRequest
import cloud.golem.http.HttpResponse
import cloud.golem.streams.AgentStream
import cloud.golem.streams.DurableStreams
import cloud.golem.runtime.Either
import cloud.golem.runtime.Guards
import cloud.golem.runtime.HostApi
import cloud.golem.runtime.Operation
import cloud.golem.runtime.SchemaValue
import cloud.golem.runtime.Transactions
import cloud.golem.runtime.TypedSchemaValue
import cloud.golem.runtime.host.AttributeValue
import cloud.golem.runtime.host.ContextApi
import cloud.golem.runtime.host.DurabilityApi
import cloud.golem.runtime.host.DurableFunctionType
import cloud.golem.runtime.host.GetOplog
import cloud.golem.runtime.host.NamedPolicy
import cloud.golem.runtime.host.Policy
import cloud.golem.runtime.host.RetryApi
import cloud.golem.runtime.host.SecretApi
import cloud.golem.runtime.host.SecretRevealException
import cloud.golem.runtime.host.namedPolicy
import cloud.golem.runtime.host.setRetryPolicy
import cloud.golem.Uuid
import cloud.golem.permissions.Permissions
import cloud.golem.runtime.AgentReflection
import cloud.golem.runtime.MakeAgentIdResult
import cloud.golem.runtime.Promises
import cloud.golem.runtime.RpcResult
import cloud.golem.runtime.ToolHost
import cloud.golem.runtime.WasmRpc
import cloud.golem.runtime.host.PostgresConnection
import cloud.golem.runtime.host.QuotaToken
import cloud.golem.runtime.ToolRpc
import cloud.golem.runtime.ToolRpcException
import cloud.golem.runtime.ToolInvokeResult
import cloud.golem.runtime.Webhooks
import cloud.golem.runtime.WebhookException
import cloud.golem.annotations.Languages
import cloud.golem.permissions.Bounds
import cloud.golem.permissions.Lifespan
import cloud.golem.permissions.PermissionCard
import cloud.golem.permissions.PolymorphicPermissionCard
import cloud.golem.runtime.wasi.Blobstore
import cloud.golem.runtime.wasi.Bucket
import cloud.golem.runtime.wasi.Config as WasiConfig
import cloud.golem.runtime.wasi.Environment
import cloud.golem.runtime.wasi.FileSystemErrorCode
import cloud.golem.runtime.wasi.Filesystem
import cloud.golem.runtime.wasi.HttpErrorCode
import cloud.golem.runtime.wasi.HttpHeader as WasiHttpHeader
import cloud.golem.runtime.wasi.HttpOutgoingClient
import cloud.golem.runtime.wasi.HttpOutgoingRequest
import cloud.golem.runtime.wasi.Logging
import cloud.golem.schema.UnstructuredText
import cloud.golem.websocket.WebSocketConnection
import cloud.golem.websocket.WebSocketException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds

/**
 * Contract-test probe agent. Each @Endpoint exercises one SDK capability's host boundary and
 * returns a String verdict: "OK <detail>" on a clean round-trip, "FAIL <detail>" on a handled
 * mismatch. An unhandled host trap aborts the invoke (the driver classifies that separately).
 * Scope is contract-only: prove the call crossed the boundary and returned the expected shape,
 * NOT that the value is functionally correct.
 */
@Agent(mount = "/probe/{id}", description = "Contract-test probe agent")
class ContractProbeAgent(val id: String) : BaseAgent() {

    // --- Capability 1: Agent model / BaseAgent identity ---
    @Endpoint(get = "/agent-model")
    fun probeAgentModel(): String {
        val aid = agentId
        return if (aid.isNotEmpty()) "OK agentId=$aid type=$agentType name=$agentName"
        else "FAIL empty agentId"
    }

    // --- HTTP gateway coverage (one endpoint reachable over the HTTP API) ---
    @Endpoint(post = "/http-echo")
    fun httpEcho(): String = "OK http id=$id"

    // Header and query bindings (1.6.0, phase 4.11): the gateway must bind `?q=` to a parameter
    // and the named header to its @Header parameter.
    @Endpoint(get = "/bound?q={query}")
    fun httpBound(query: String, @Header("X-Tenant") tenant: String): String = "OK bound q=$query tenant=$tenant"

    // --- Capability 2: Type mapping (Kotlin <-> WIT / schema values) ---

    // Return-direction (lower): one value touching every mapped type family.
    @Endpoint(get = "/return-all-types")
    fun returnAllTypes(): AllTypes = AllTypes(
        i8 = -8, i16 = -16, i32 = -32, i64 = -64L,
        u8 = 8u, u16 = 16u, u32 = 32u, u64 = 64uL,
        f32 = 1.5f, f64 = 2.5, flag = true, text = "hello",
        opt = 7, nums = listOf(1, 2, 3), color = Color.GREEN,
        shape = Shape.Circle(3.0), pair = Pair(9, "nine"),
        dict = mapOf("k" to 1), res = Either.Right(42), ts = Datetime(1000L, 0),
    )

    // Lift-direction (host -> guest) for the types with unambiguous CLI literals.
    @Endpoint(post = "/echo-record")
    fun echoRecord(p: Pt): String = "OK ${p.x},${p.y}"

    @Endpoint(post = "/echo-list")
    fun echoList(xs: List<Int>): String = "OK size=${xs.size}"

    @Endpoint(post = "/echo-opt")
    fun echoOpt(o: Int?): String = "OK ${o ?: -1}"

    // --- Capability 3: Host API (read-only host imports) ---
    @Endpoint(get = "/host-api")
    fun probeHostApi(): String {
        val meta = HostApi.getSelfMetadata()
        val parsed = HostApi.parseAgentId(meta.agentId.agentId)
        val types = HostApi.getAllAgentTypes() // may be empty -> still OK
        val key = HostApi.generateIdempotencyKey()
        return "OK metaId=${meta.agentId.agentId} parsed=${parsed::class.simpleName} " +
            "types=${types.size} key=${key.highBits}"
    }

    // --- Capability 4: Oplog (get-oplog resource + entry decode) ---
    @Endpoint(get = "/oplog")
    fun probeOplog(): String {
        val meta = HostApi.getSelfMetadata()
        val oplog = GetOplog(meta.agentId, 0L)
        var count = 0
        val kinds = mutableSetOf<String>()
        try {
            while (true) {
                val batch = oplog.getNext() ?: break
                count += batch.size
                batch.forEach { kinds.add(it::class.simpleName ?: "?") }
            }
        } finally {
            oplog.close()
        }
        // A live agent always has at least a Create entry; if decode traps this never returns.
        return if (count > 0) "OK entries=$count kinds=${kinds.size}" else "FAIL empty oplog"
    }

    // --- Capability 5: Retry + Retry DSL (policy-tree marshalling) ---
    @Endpoint(get = "/retry")
    fun probeRetry(): String {
        val policy = NamedPolicy("probe-policy", Policy.exponential(100.milliseconds, 2.0).maxRetries(5))
        RetryApi.setRetryPolicy(policy) // lower the tree to the host
        val readBack = RetryApi.namedPolicy("probe-policy") // lift it back
        return if (readBack != null && readBack.name == "probe-policy") {
            "OK policy round-tripped: ${readBack.name}"
        } else {
            "FAIL policy not found after set"
        }
    }

    // --- Capability 6: Transactions (saga; infallible resolves the `saga` retry policy via the host) ---
    @Endpoint(get = "/transactions")
    fun probeTransactions(): String {
        val noop = Operation<Int, Int, String>({ Either.Right(it + 1) }, { _, _ -> Either.Right(Unit) })
        val result = Transactions.infallibleTransaction<Int, String> { tx -> tx.execute(noop, 41) }
        return if (result == Either.Right(42)) "OK saga committed, result=42" else "FAIL unexpected result=$result"
    }

    // --- Capability 7: Guards (retry-policy guards; persistence/idempotence/atomic/Checkpoint were removed in 1.6.0) ---
    @Endpoint(get = "/guards")
    fun probeGuards(): String {
        val policy = NamedPolicy("probe-guard", Policy.CountBox(2u, Policy.periodic(10.milliseconds)))
        val inside = Guards.withRetryPolicy(policy) { RetryApi.getRetryPolicyByName("probe-guard") != null }
        val outside = RetryApi.getRetryPolicyByName("probe-guard") == null
        return if (inside && outside) "OK retry-policy guard scoped" else "FAIL inside=$inside outside=$outside"
    }

    // --- Capability 8: Secrets (reveal error-path; no provisioning available) ---
    @Endpoint(get = "/secrets")
    fun probeSecrets(): String = try {
        // 0 is not a live secret handle. A wired boundary either lifts a SecretError (caught here)
        // or the host rejects the handle as a trap (invoke exits non-zero -> driver classifies it).
        SecretApi.reveal(0, "string")
        "FAIL reveal(0) returned a value instead of erroring"
    } catch (e: SecretRevealException) {
        "OK SecretError lifted: ${e.error::class.simpleName}"
    }

    // --- Capability 9: Context / tracing (span + invocation-context resources) ---
    @Endpoint(get = "/context")
    fun probeContext(): String {
        val span = ContextApi.startSpan("probe-span")
        span.setAttribute("probe.key", AttributeValue.StringValue("probe.value"))
        val ctx = ContextApi.currentContext()
        val trace = ctx.traceId()
        ctx.close()
        span.close()
        return "OK span+context ran, traceId=${if (trace.isNotEmpty()) "present" else "empty"}"
    }

    // --- Capability 10: Durability (custom durable invocation: live record; replay is out of scope) ---
    @Endpoint(get = "/durability")
    fun probeDurability(): String {
        val response = DurabilityApi.durable(
            "probe",
            "durability",
            DurableFunctionType.ReadRemote,
            TypedSchemaValue("string", SchemaValue.Str("req")),
        ) { TypedSchemaValue("s32", SchemaValue.S32(7)) }
        val value = (response.value as? SchemaValue.S32)?.v
        return if (value == 7) "OK custom durable invocation recorded, response=7" else "FAIL response=$response"
    }

    // --- Capability 11: RPC (golem:agent/host wasm-rpc, self-call) ---
    @Endpoint(get = "/rpc")
    fun probeRpc(): String {
        val target = when (val made = HostApi.makeAgentId("ContractProbeAgent", SchemaValue.Record(listOf(SchemaValue.Str("rpc-target"))))) {
            is MakeAgentIdResult.Ok -> made.agentId
            is MakeAgentIdResult.Err -> return "FAIL make-agent-id: ${made.error}"
        }
        return WasmRpc("ContractProbeAgent", SchemaValue.Record(listOf(SchemaValue.Str("rpc-target")))).use { rpc ->
            when (val r = rpc.invokeAndAwait("probeAgentModel", SchemaValue.Record(emptyList()), "string")) {
                is RpcResult.Ok -> "OK self-rpc returned ${(r.value as? SchemaValue.Str)?.v?.take(24)} target=$target"
                is RpcResult.Err -> "FAIL rpc error: ${r.error}"
            }
        }
    }

    // --- Capability 12: Agent reflection (the host registry, lifted back into typed info) ---
    @Endpoint(get = "/reflection")
    fun probeReflection(): String {
        val self = AgentReflection.agentType("ContractProbeAgent") ?: return "FAIL own agent type not in the registry"
        val named = self.method("probeReflection") ?: return "FAIL own method not reflected"
        return "OK reflected ctor=${self.constructorParameters.size} methods=${self.methods.size} found=${named.name}"
    }

    // --- Capability 13: Tools (the host's registry, scoped to this agent type) ---
    // The registry provisions seven built-in tools, but access is bound per agent type, and this
    // app's manifest declares no tool dependencies -- so the agent sees exactly the default set:
    // `bash` alone (golem-common's DEFAULT_TOOLS). Assert that, not merely "non-empty", or a
    // decoding bug that drops entries would pass unnoticed.
    @Endpoint(get = "/tools")
    fun probeTools(): String {
        val all = ToolHost.getAllTools()
        val names = all.map { it.lookupName }.sorted()
        if (names != listOf("bash")) return "FAIL expected the default grant [bash], got $names"
        val described = ToolHost.describe("bash") ?: return "FAIL bash has no described interface"
        return "OK tools=${all.size} default-grant=$names commands=${described.commands.size}"
    }

    // --- Capability 14: WASI key-value ---
    /**
     * The `*-async` key-value variants, which move a value over a `stream<u8>` instead of one contiguous
     * buffer. Covers both directions and a value larger than one stream chunk, because a single-chunk value
     * would not show a partial transfer being resumed.
     */
    @Endpoint(get = "/key-value-stream")
    fun probeKeyValueStreaming(): String {
        val bucket = when (val b = Bucket.open("probe-stream")) {
            is Either.Right -> b.value
            is Either.Left -> return "FAIL open: ${b.value.message}"
        }
        try {
            // Past the 64 KiB chunk, so the write loop and the read loop both iterate.
            val large = ByteArray(150_000) { (it % 251).toByte() }
            when (val set = bucket.setStreaming("streamed", large)) {
                is Either.Left -> return "FAIL setStreaming: ${set.value.message}"
                is Either.Right -> Unit
            }

            // Read it back both ways: the bytes must not depend on how they were transferred.
            val streamed = (bucket.getStreaming("streamed") as? Either.Right)?.value
                ?: return "FAIL getStreaming returned no value"
            val contiguous = (bucket.get("streamed") as? Either.Right)?.value
                ?: return "FAIL get returned no value"
            if (!streamed.contentEquals(large)) return "FAIL streamed read differs at ${streamed.size} bytes"
            if (!contiguous.contentEquals(large)) return "FAIL a streamed write is not readable contiguously"

            // And a value written contiguously must be readable as a stream.
            val small = byteArrayOf(7, 7, 7)
            bucket.set("contiguous", small)
            val smallStreamed = (bucket.getStreaming("contiguous") as? Either.Right)?.value
            if (smallStreamed == null || !smallStreamed.contentEquals(small)) {
                return "FAIL a contiguous write is not readable as a stream: ${smallStreamed?.toList()}"
            }

            // An absent key must read as null, not as an empty value.
            val absent = bucket.getStreaming("no-such-key")
            if (absent !is Either.Right || absent.value != null) return "FAIL an absent key streamed ${absent}"

            bucket.delete("streamed")
            bucket.delete("contiguous")
            return "OK streamed ${large.size} bytes both ways, matched contiguous, absent key read null"
        } finally {
            bucket.close()
        }
    }

    @Endpoint(get = "/keyvalue")
    fun probeKeyValue(): String {
        val bucket = when (val b = Bucket.open("probe")) {
            is Either.Right -> b.value
            is Either.Left -> return "FAIL open: ${b.value.message}"
        }
        try {
            val key = "contract-probe"
            val body = byteArrayOf(1, 2, 3)
            when (val set = bucket.set(key, body)) {
                is Either.Left -> return "FAIL set: ${set.value.message}"
                is Either.Right -> Unit
            }
            val read = (bucket.get(key) as? Either.Right)?.value
            val exists = (bucket.exists(key) as? Either.Right)?.value
            bucket.delete(key)
            val gone = (bucket.exists(key) as? Either.Right)?.value
            return if (read?.toList() == body.toList() && exists == true && gone == false) {
                "OK key-value round-tripped ${read.size} bytes"
            } else {
                "FAIL read=${read?.toList()} exists=$exists gone=$gone"
            }
        } finally {
            bucket.close()
        }
    }

    // --- Capability 15: WASI blobstore ---
    @Endpoint(get = "/blobstore")
    fun probeBlobstore(): String {
        val container = when (val c = Blobstore.createContainer("probe")) {
            is Either.Right -> c.value
            is Either.Left -> return "FAIL createContainer: ${c.value}"
        }
        try {
            val body = "contract".encodeToByteArray()
            when (val w = container.writeData("obj", body)) {
                is Either.Left -> return "FAIL writeData: ${w.value}"
                is Either.Right -> Unit
            }
            val read = (container.getData("obj", 0, (body.size - 1).toLong()) as? Either.Right)?.value
            val names = (container.listObjects() as? Either.Right)?.value
            container.deleteObject("obj")
            return if (read?.decodeToString() == "contract" && names?.contains("obj") == true) {
                "OK blobstore round-tripped, objects=${names.size}"
            } else {
                "FAIL read=${read?.decodeToString()} names=$names"
            }
        } finally {
            container.close()
        }
    }

    // --- Capability 16: RDBMS. Contract-only: no database is provisioned here, so a connect to a
    // bogus address must come back as a typed DbError rather than trapping the agent. ---
    @Endpoint(get = "/rdbms")
    fun probeRdbms(): String = when (val c = PostgresConnection.open("postgres://127.0.0.1:1/nonexistent")) {
        is Either.Left -> "OK postgres refused cleanly: ${c.value::class.simpleName}"
        is Either.Right -> {
            c.value.close()
            "OK postgres open returned a connection (open does not dial eagerly)"
        }
    }

    // --- Capability 17: WASI environment, config and logging ---
    @Endpoint(get = "/wasi")
    fun probeWasi(): String {
        val env = Environment.getEnvironment()
        val args = Environment.getArguments()
        val config = WasiConfig.getAll()
        Logging.info("contract probe reached the logging import", "golem.probe")
        return when (config) {
            is Either.Right -> "OK env=${env.size} args=${args.size} config=${config.value.size} logging=sent"
            is Either.Left -> "FAIL config: ${config.value}"
        }
    }

    // --- Capability 18: Permission cards (the wallet is empty unless the deployment grants any;
    // the contract is that the imports marshal and return a typed view) ---
    @Endpoint(get = "/permissions")
    fun probePermissions(): String {
        val wallet = Permissions.wallet()
        val version = Permissions.selfVersion()
        wallet.forEach { it.card.release() }
        return "OK wallet=${wallet.size} selfVersion=present(${version.toString().isNotEmpty()})"
    }

    // --- Capability 19: Promises (create -> complete -> await, all within one invocation) ---
    @Endpoint(get = "/promises")
    fun probePromises(): String {
        val id = Promises.create()
        val completed = Promises.complete(id, "done".encodeToByteArray())
        val payload = Promises.await(id).decodeToString()
        return if (completed && payload == "done") "OK promise completed and awaited" else "FAIL completed=$completed payload=$payload"
    }

    // --- Capability 20: WebSocket client. Contract-only: a connect to a closed port must raise a
    // typed WebSocketException rather than trapping. ---
    @Endpoint(get = "/websocket")
    fun probeWebsocket(): String = try {
        WebSocketConnection.connect("ws://127.0.0.1:1/").close()
        "OK websocket connected unexpectedly"
    } catch (e: WebSocketException) {
        "OK websocket refused cleanly: ${e.error::class.simpleName}"
    }

    /**
     * Relays a stream argument to a stream result, element by element. The producer body runs after
     * `task.return`, so it reads the argument and writes the result from the same post-return job.
     */
    @Endpoint(post = "/relay")
    fun relayStream(input: AgentStream<Int>): AgentStream<Int> = AgentStream.produce("s32") { sink ->
        while (true) {
            val v = input.next() ?: break
            if (!sink.write(v)) break
        }
        input.close()
    }

    // --- Stream edge cases (38-42) -----------------------------------------------------------

    /** How many elements [countingStream] managed to write before its reader went away. */
    private var written = 0

    @Endpoint(get = "/written")
    fun writtenCount(): Int = written

    /** Writes up to [n] elements, recording how many were accepted. */
    @Endpoint(post = "/counting")
    fun countingStream(n: Int): AgentStream<Int> = AgentStream.produce("s32") { sink ->
        for (i in 1..n) {
            if (!sink.write(i)) break
            written = i
        }
    }

    /** An empty stream: the reader must see the end at once, not block. */
    @Endpoint(get = "/empty-stream")
    fun emptyStream(): AgentStream<Int> = AgentStream.of(emptyList())

    /** Writes one element and then fails. The stream WIT carries no error channel, so the reader sees an ordinary end. */
    @Endpoint(get = "/throwing-stream")
    fun throwingStream(): AgentStream<Int> = AgentStream.produce("s32") { sink ->
        sink.write(7)
        error("the producer failed deliberately")
    }

    /**
     * The raw schema corners inside `option` and `result`. Registering this method proves the type nodes lower;
     * returning the values proves the lift and lower cross the boundary in a nested position.
     */
    @Endpoint(get = "/nested-corners")
    fun probeNestedCorners(): NestedCorners = NestedCorners(
        maybeNote = UnstructuredText.Inline("nested", "en"),
        maybeBlob = byteArrayOf(9, 8, 7),
        noteOrError = Either.Right(UnstructuredText.Inline("in-result", "en")),
        blobOrError = Either.Right(byteArrayOf(1, 2)),
        absentNote = null,
    )

    /** Five elements, so a reader's cap of 3 must refuse and a cap of 5 must admit. */
    @Endpoint(get = "/five-stream")
    fun fiveStream(): AgentStream<Int> = AgentStream.of(listOf(1, 2, 3, 4, 5))

    /** A stream whose element is a record, so the element lift/lower is composite. */
    @Endpoint(get = "/record-stream")
    fun recordStream(): AgentStream<Pt> = AgentStream.of(listOf(Pt(1, 2), Pt(3, 4), Pt(5, 6)))

    private fun relayTarget(id: String) = AgentReflection.dynamicClient("ContractProbeAgent(\"$id\")")

    /**
     * `AgentStream.toList`'s element cap, over a real host-brokered stream. A cap equal to the
     * length admits; one below it refuses. Unit tests cover the arithmetic, but only a live stream
     * shows that refusing mid-read neither traps the agent nor wedges the reader.
     */
    @Endpoint(get = "/stream-cap")
    fun probeStreamItemCap(): String {
        val client = relayTarget("cap-src") ?: return "FAIL no dynamic client"
        fun read(cap: Int): Result<List<Int>> = runCatching {
            when (val r = client.invoke("fiveStream")) {
                is RpcResult.Ok -> (r.value as? SchemaValue.StreamVal)?.let { v ->
                    AgentStream.fromHandle<Int>(v.handle, "s32") { (it as SchemaValue.S32).v }.toList(cap)
                } ?: error("not a stream")
                is RpcResult.Err -> error("rpc: ${r.error}")
            }
        }
        val atLimit = read(5)
        if (atLimit.getOrNull() != listOf(1, 2, 3, 4, 5)) return "FAIL a cap of 5 must admit 5 elements: $atLimit"
        val below = read(3)
        if (below.isSuccess) return "FAIL a cap of 3 admitted ${below.getOrNull()}"
        val why = below.exceptionOrNull()?.message ?: ""
        if (!why.contains("more than 3")) return "FAIL refused for the wrong reason: $why"
        return "OK a cap of 5 read [1, 2, 3, 4, 5]; a cap of 3 was refused ($why)"
    }

    /**
     * `Blobstore.listObjects`'s name cap, over a real container. The cap is checked per batch
     * rather than per name, so only a live listing shows the boundary and that the readable end is
     * still released when the cap refuses.
     */
    @Endpoint(get = "/blob-cap")
    fun probeBlobstoreNameCap(): String {
        val container = when (val c = Blobstore.createContainer("probe-cap")) {
            is Either.Right -> c.value
            is Either.Left -> return "FAIL createContainer: ${c.value}"
        }
        try {
            for (name in listOf("a", "b", "c")) {
                when (val w = container.writeData(name, name.encodeToByteArray())) {
                    is Either.Left -> return "FAIL writeData $name: ${w.value}"
                    is Either.Right -> Unit
                }
            }
            val atLimit = container.listObjects(maxNames = 3)
            if (atLimit !is Either.Right || atLimit.value.size != 3) return "FAIL a cap of 3 must list 3 names: $atLimit"
            val below = container.listObjects(maxNames = 2)
            if (below !is Either.Left) return "FAIL a cap of 2 listed ${(below as? Either.Right)?.value}"
            if (!below.value.contains("more than 2")) return "FAIL refused for the wrong reason: ${below.value}"
            // The readable end was dropped on the refusing path, so a further listing still works.
            val again = container.listObjects(maxNames = 3)
            if (again !is Either.Right || again.value.size != 3) return "FAIL the container was wedged by the refusal: $again"
            return "OK a cap of 3 listed 3 names; a cap of 2 was refused and left the container usable"
        } finally {
            for (name in listOf("a", "b", "c")) container.deleteObject(name)
            container.close()
        }
    }

    @Endpoint(get = "/empty-stream-read")
    fun probeEmptyStream(): String {
        val client = relayTarget("empty-src") ?: return "FAIL no dynamic client"
        return when (val r = client.invoke("emptyStream")) {
            is RpcResult.Ok -> {
                val back = (r.value as? SchemaValue.StreamVal)?.let { v ->
                    AgentStream.fromHandle<Int>(v.handle, "s32") { (it as SchemaValue.S32).v }.toList(8)
                }
                if (back == emptyList<Int>()) "OK an empty stream ends at once" else "FAIL read $back"
            }
            is RpcResult.Err -> "FAIL rpc: ${r.error}"
        }
    }

    @Endpoint(get = "/abandon-read")
    fun probeAbandonedReader(): String {
        val id = "abandon-src"
        val client = relayTarget(id) ?: return "FAIL no dynamic client"
        val handle = when (val r = client.invoke("countingStream", listOf(SchemaValue.S32(5000)))) {
            is RpcResult.Ok -> (r.value as? SchemaValue.StreamVal)?.handle ?: return "FAIL no stream back"
            is RpcResult.Err -> return "FAIL rpc: ${r.error}"
        }
        val stream = AgentStream.fromHandle<Int>(handle, "s32") { (it as SchemaValue.S32).v }
        val first = stream.next()
        stream.close() // the reader goes away long before the end
        val wrote = when (val r = relayTarget(id)!!.invoke("writtenCount")) {
            is RpcResult.Ok -> (r.value as? SchemaValue.S32)?.v ?: -1
            is RpcResult.Err -> return "FAIL writtenCount: ${r.error}"
        }
        return if (first == 1 && wrote in 1..4999) {
            "OK the producer stopped at $wrote of 5000 once the reader closed"
        } else {
            "FAIL first=$first wrote=$wrote (expected the producer to stop early)"
        }
    }

    @Endpoint(get = "/throwing-read")
    fun probeThrowingProducer(): String {
        val client = relayTarget("throwing-src") ?: return "FAIL no dynamic client"
        return when (val r = client.invoke("throwingStream")) {
            is RpcResult.Ok -> {
                val back = (r.value as? SchemaValue.StreamVal)?.let { v ->
                    AgentStream.fromHandle<Int>(v.handle, "s32") { (it as SchemaValue.S32).v }.toList(8)
                }
                // Pins today's behaviour: the failure is logged and the stream simply ends, so the reader
                // cannot tell truncation from completion. The writable end has one intrinsic and no errored
                // variant, and the element type carries no error case, so there is nowhere to report it.
                if (back == listOf(7)) "OK a failed producer truncates silently, read $back" else "FAIL read $back"
            }
            is RpcResult.Err -> "FAIL rpc: ${r.error}"
        }
    }

    @Endpoint(get = "/record-stream-read")
    fun probeRecordStream(): String {
        val client = relayTarget("record-src") ?: return "FAIL no dynamic client"
        return when (val r = client.invoke("recordStream")) {
            is RpcResult.Ok -> {
                val back = (r.value as? SchemaValue.StreamVal)?.let { v ->
                    AgentStream.fromHandle<Pt>(v.handle, "record<x:s32,y:s32>") { value ->
                        val f = (value as SchemaValue.Record).fields
                        Pt((f[0] as SchemaValue.S32).v, (f[1] as SchemaValue.S32).v)
                    }.toList(8)
                }
                if (back == listOf(Pt(1, 2), Pt(3, 4), Pt(5, 6))) "OK a record-element stream round-tripped ${back.size} elements" else "FAIL read $back"
            }
            is RpcResult.Err -> "FAIL rpc: ${r.error}"
        }
    }

    /** Two duplex RPCs in flight at once from one caller, each with a stream argument and result. */
    @Endpoint(get = "/concurrent-duplex")
    fun probeConcurrentDuplex(): String {
        fun rpc() = WasmRpc("ContractProbeAgent", SchemaValue.Record(listOf(SchemaValue.Str("conc-${'$'}{kotlin.random.Random.nextInt()}"))))
        val a = rpc()
        val b = rpc()
        try {
            val argA = AgentStream.of(listOf(1, 2, 3)).intoSchemaValue { SchemaValue.S32(it) }
            val argB = AgentStream.of(listOf(4, 5, 6)).intoSchemaValue { SchemaValue.S32(it) }
            val fa = a.asyncInvokeAndAwait("relayStream", SchemaValue.Record(listOf(argA)), "stream<s32>")
            val fb = b.asyncInvokeAndAwait("relayStream", SchemaValue.Record(listOf(argB)), "stream<s32>")
            try {
                fun read(r: RpcResult): List<Int>? = (r as? RpcResult.Ok)?.value?.let { v ->
                    (v as? SchemaValue.StreamVal)?.let { sv ->
                        AgentStream.fromHandle<Int>(sv.handle, "s32") { (it as SchemaValue.S32).v }.toList(16)
                    }
                }
                val backA = read(fa.get())
                val backB = read(fb.get())
                return if (backA == listOf(1, 2, 3) && backB == listOf(4, 5, 6)) {
                    "OK two duplex calls in flight relayed $backA and $backB"
                } else {
                    "FAIL a=$backA b=$backB"
                }
            } finally {
                fa.close()
                fb.close()
            }
        } finally {
            a.close()
            b.close()
        }
    }

    /**
     * A relay that **writes before it reads**. `relayStream` alternates strictly read-then-write, which
     * always drains an element and so keeps the caller's producer moving; that discipline may be the only
     * reason it does not deadlock. Here the producer emits a prologue element first, while the caller is
     * still producing its argument and therefore not yet reading. If neither side's write can complete
     * without the other reading, this is the shape that blocks both at once.
     */
    @Endpoint(post = "/relay-write-first")
    fun relayWriteFirst(input: AgentStream<Int>): AgentStream<Int> = AgentStream.produce("s32") { sink ->
        if (sink.write(-1)) {
            while (true) {
                val v = input.next() ?: break
                if (!sink.write(v)) break
            }
        }
        input.close()
    }

    /** Write-first duplex: same call shape as [probeDuplexStream], against [relayWriteFirst]. */
    @Endpoint(get = "/duplex-write-first")
    fun probeDuplexWriteFirst(): String {
        val client = AgentReflection.dynamicClient("ContractProbeAgent(\"relay-wf-target\")")
            ?: return "FAIL no dynamic client"
        val sent = (1..2000).toList()
        val out = AgentStream.of(sent).intoSchemaValue { SchemaValue.S32(it) }
        return when (val r = client.invoke("relayWriteFirst", listOf(out))) {
            is RpcResult.Ok -> {
                val back = (r.value as? SchemaValue.StreamVal)?.let { v ->
                    AgentStream.fromHandle<Int>(v.handle, "s32") { (it as SchemaValue.S32).v }.toList(4096)
                }
                val expected = listOf(-1) + sent
                if (back == expected) "OK write-first relayed ${back.size} elements (prologue first)" else "FAIL relayed ${back?.size} elements, head=${back?.take(3)}"
            }
            is RpcResult.Err -> "FAIL rpc: ${r.error}"
        }
    }

    /**
     * Guest-to-guest stream-in **and** stream-out over RPC. The caller produces into the argument
     * stream while reading the result stream; `invokeAndAwait` runs the argument producer to
     * completion before awaiting the result, so with a relaying callee this is the documented
     * deadlock: each side blocks on a write the other will not read. Here to be reproduced, not
     * yet to pass.
     */
    @Endpoint(get = "/duplex")
    fun probeDuplexStream(): String {
        val client = AgentReflection.dynamicClient("ContractProbeAgent(\"relay-target\")")
            ?: return "FAIL no dynamic client"
        // 3 elements may fit a host-side buffer, which would hide a mutual block. 2000 cannot:
        // if the relay only works because the host absorbs a write without a reader, this fails.
        val sent = (1..2000).toList()
        val out = AgentStream.of(sent).intoSchemaValue { SchemaValue.S32(it) }
        return when (val r = client.invoke("relayStream", listOf(out))) {
            is RpcResult.Ok -> {
                val back = (r.value as? SchemaValue.StreamVal)?.let { v ->
                    AgentStream.fromHandle<Int>(v.handle, "s32") { (it as SchemaValue.S32).v }.toList(4096)
                }
                if (back == sent) "OK duplex relayed ${back.size} elements, sum=${back.sum()}" else "FAIL relayed ${back?.size} elements"
            }
            is RpcResult.Err -> "FAIL rpc: ${r.error}"
        }
    }

    // --- Capability 34: External durable streams. The peer's URL comes in as a parameter so the
    // driver can pass the port it started its stub peer on. Reads the opening batch, then appends
    // one message and closes -- the driver checks what the peer actually received. ---
    @Endpoint(post = "/durable-stream")
    fun probeDurableStream(url: String): String {
        val read = DurableStreams.json(url).use { it.toList(maxItems = 16) }
        val writer = DurableStreams.jsonWriter(url)
        val receipt = writer.append(listOf("\"probe\""), close = true)
        writer.dispose()
        return if (read.size == 3 && read[1] == "9007199254740993") {
            "OK durable stream read ${read.size} messages, appended seq=${receipt.sequence} closed=${receipt.closed}"
        } else {
            "FAIL read back $read"
        }
    }

    // --- Capability 27: ToolRpc against the granted `bash` tool. Contract-only in both
    // directions: a successful invocation would need bash's own input schema, so an input it
    // rejects still proves the path that matters here -- create, invoke, and lift a typed
    // `tool-rpc-error` rather than trapping. ---
    @Endpoint(get = "/tool-call")
    fun probeToolCall(): String = try {
        val rpc = ToolRpc("bash")
        val input = TypedSchemaValue("record<command:string>", SchemaValue.Record(listOf(SchemaValue.Str("echo contract"))))
        when (val outcome = rpc.invokeAndAwait(listOf(), input)) {
            is ToolInvokeResult.Ok -> "OK tool invoked, result=${outcome.value.result != null}"
            is ToolInvokeResult.Err -> "OK tool refused cleanly: ${outcome.error::class.simpleName}"
        }
    } catch (e: ToolRpcException) {
        "OK tool-rpc refused cleanly: ${e.error::class.simpleName}"
    }

    // --- Capability 28: Permission card operations on a card from the wallet: inspect, derive a
    // bounded child, then revoke it. The wallet's own card is left alone. ---
    @Endpoint(get = "/card-ops")
    fun probeCardOps(): String {
        val wallet = Permissions.wallet()
        if (wallet.isEmpty()) return "OK wallet is empty: no card to operate on"
        val card = wallet.first().card
        val view = when (val v = card.inspect()) {
            is Either.Right -> v.value
            is Either.Left -> { wallet.forEach { it.card.release() }; return "OK inspect refused cleanly: ${v.value::class.simpleName}" }
        }
        val derived = (card as? PolymorphicPermissionCard)?.derive(Bounds.empty, Lifespan.iso8601("PT1H"))
            ?: (card as? PermissionCard)?.derive(Bounds.empty, Lifespan.iso8601("PT1H"))
        val detail = when (derived) {
            null -> "no derive on ${card::class.simpleName}"
            is Either.Right -> {
                val revoked = derived.value.revoke()
                "derived+${if (revoked is Either.Right) "revoked" else "revoke-refused"}"
            }
            is Either.Left -> "derive refused: ${derived.value::class.simpleName}"
        }
        wallet.forEach { it.card.release() }
        return "OK card inspected (grants=${view.upperPositive.size}+${view.lowerPositive.size}) $detail"
    }

    // --- Capability 29: Dynamic invocation through the reflected registry. ---
    @Endpoint(get = "/dynamic-client")
    fun probeDynamicClient(): String {
        val client = AgentReflection.dynamicClient("ContractProbeAgent(\"dyn-target\")")
            ?: return "FAIL no dynamic client for the probe agent type"
        return when (val r = client.invoke("probeAgentModel")) {
            is RpcResult.Ok -> "OK dynamic invoke returned ${(r.value as? SchemaValue.Str)?.v?.take(20)}"
            is RpcResult.Err -> "FAIL dynamic invoke: ${r.error}"
        }
    }

    // --- Capability 30: Webhook creation for a promise (creating the URL needs no HTTP traffic). ---
    @Endpoint(get = "/webhook")
    fun probeWebhook(): String = try {
        val url = Webhooks.create(Promises.create())
        if (url.isNotEmpty()) "OK webhook url issued (${url.length} chars)" else "FAIL empty webhook url"
    } catch (e: WebhookException) {
        "OK webhook refused cleanly: ${e.message?.take(40)}"
    }

    // --- Capability 31: Unstructured allow-lists. The host validates the language against the
    // schema's allow-list before the call, so reaching the body at all is the contract. ---
    @Endpoint(post = "/allow-list")
    fun probeAllowList(note: @Languages("en", "de") UnstructuredText): String = when (note) {
        is UnstructuredText.Inline -> "OK allow-listed text accepted lang=${note.languageCode}"
        is UnstructuredText.Url -> "OK allow-listed text by url"
    }

    // --- Capability 25: Quota. The resource comes from the environment's resourceDefaults; the
    // contract is that create/reserve/commit marshal and that a missing resource is a typed
    // failure rather than a trap. ---
    @Endpoint(get = "/quota")
    fun probeQuota(): String = try {
        val token = QuotaToken.create("probe-resource", 100)
        when (val reserved = token.reserve(10)) {
            is Either.Right -> {
                reserved.value.commit(10)
                "OK quota reserved and committed"
            }
            is Either.Left -> "OK quota refused cleanly: ${reserved.value::class.simpleName}"
        }
    } catch (e: IllegalStateException) {
        "OK quota refused cleanly: ${e.message?.take(40)}"
    }

    // --- Capability 21: Schema corners added in 1.6.0 (uuid, kotlin Duration, bytes, unstructured).
    // Registering this method already proves the type nodes lower; returning the values proves the
    // value lift/lower crosses the boundary. ---
    @Endpoint(get = "/schema-corners")
    fun probeSchemaCorners(): SchemaCorners = SchemaCorners(
        id = Uuid(0x0123456789abcdefuL, 0xfedcba9876543210uL),
        ttl = 1500.milliseconds,
        blob = byteArrayOf(1, 2, 3, 4),
        note = UnstructuredText.Inline("probe", "en"),
    )

    // --- Capability 47: WASI filesystem (preview 3). Reads an IFS-declared file through the
    // real host boundary, confirms a missing path comes back as a typed error rather than a
    // trap, and writes + reads back a brand-new path under the unconditionally-preopened `/`
    // root (never declared via IFS at all -- confirmed live that the root itself is writable
    // regardless of any individual file's own `permissions:`). ---
    @Endpoint(get = "/filesystem")
    fun probeFilesystem(): String {
        val ifsRead = when (val r = Filesystem.readText("/probe-data/filesystem-probe.txt")) {
            is Either.Left -> return "FAIL ifs read: ${r.value}"
            is Either.Right -> r.value
        }
        if (ifsRead != "filesystem contract probe") return "FAIL ifs content mismatch: $ifsRead"

        val missing = Filesystem.readBytes("/probe-data/does-not-exist.txt")
        if (missing !is Either.Left || missing.value != FileSystemErrorCode.NoEntry) {
            return "FAIL missing path did not come back as NoEntry: $missing"
        }

        val newPath = "/probe-data/brand-new.txt"
        when (val w = Filesystem.writeBytes(newPath, "written by contract probe".encodeToByteArray())) {
            is Either.Left -> return "FAIL write: ${w.value}"
            is Either.Right -> Unit
        }
        val roundTrip = when (val r = Filesystem.readText(newPath)) {
            is Either.Left -> return "FAIL read-back: ${r.value}"
            is Either.Right -> r.value
        }
        return if (roundTrip == "written by contract probe") {
            "OK filesystem ifs+missing+write-new-path all round-tripped"
        } else {
            "FAIL round-trip mismatch: $roundTrip"
        }
    }

    // --- Capability 48: WASI filesystem, a multi-MB round-trip (Review Focus: the full content
    // of both the write and the read side materializes as one GC-heap `ByteArray`, so this is
    // the input class most likely to surprise a caller who expects file I/O to stream). ---
    @Endpoint(post = "/filesystem-large")
    fun probeFilesystemLargeFile(sizeMb: Int): String {
        val size = sizeMb * 1024 * 1024
        val data = ByteArray(size) { (it % 256).toByte() }
        when (val w = Filesystem.writeBytes("/probe-data/large.bin", data)) {
            is Either.Left -> return "FAIL write: ${w.value}"
            is Either.Right -> Unit
        }
        return when (val r = Filesystem.readBytes("/probe-data/large.bin")) {
            is Either.Left -> "FAIL read: ${r.value}"
            is Either.Right -> {
                val matches = r.value.size == data.size && r.value.indices.all { r.value[it] == data[it] }
                if (matches) "OK large-file round-tripped ${r.value.size} bytes" else "FAIL content mismatch"
            }
        }
    }

    // --- Capability 49: WASI outgoing HTTP (preview 3, `wasi:http/client.send`). Sends a real
    // request to a local peer under test control (contract-tests/http-echo-peer.py, started by
    // native-contract-tests.sh), asserting status, a response-header round-trip, and the body --
    // not just that the call returned without trapping. ---
    @Endpoint(post = "/http-send")
    fun probeHttpSend(port: Int): String {
        val request = HttpOutgoingRequest(
            method = "POST",
            url = "http://127.0.0.1:$port/echo",
            headers = listOf(WasiHttpHeader("x-probe-echo", "49")),
            body = "contract probe body".encodeToByteArray(),
        )
        val response = when (val r = HttpOutgoingClient.send(request)) {
            is Either.Left -> return "FAIL send: ${r.value}"
            is Either.Right -> r.value
        }
        if (response.status != 200) return "FAIL status=${response.status}"
        val echoed = response.headers.firstOrNull { it.name.equals("x-probe-echo", ignoreCase = true) }?.value
        if (echoed != "49") return "FAIL missing/wrong echo header: $echoed"
        val bodyText = response.body.decodeToString()
        return if (bodyText == "contract probe body") {
            "OK http send status=200 header+body round-tripped"
        } else {
            "FAIL body mismatch: $bodyText"
        }
    }

    // --- Capability 50: WASI outgoing HTTP, a multi-MB round-trip (Review Focus: like
    // `probeFilesystemLargeFile`, the full content of both the request write and the response
    // read materializes as one GC-heap `ByteArray` -- there is no streaming body API).
    // A multi-MB outgoing request body hangs `client.send` indefinitely -- a documented,
    // root-caused host defect in vendored wasmtime-wasi-http's GuestBody stream consumption, not
    // in this method or in golem-worker-executor's own code (see Http.kt's own header doc comment
    // and the plan's progress.md, "Task 4" sections, for the full finding). This method itself is
    // unchanged and correct; native-contract-tests.sh runs it through `probe_expect_hang` as a
    // bounded regression probe (a timeout is the current expected outcome) rather than leaving it
    // unregistered, so a regression or a fix is caught automatically on every run. Once the
    // underlying defect is fixed, switch that registration back to a normal `probe` call. ---
    @Endpoint(post = "/http-send-large")
    fun probeHttpSendLargeBody(port: Int, sizeMb: Int): String {
        val size = sizeMb * 1024 * 1024
        val data = ByteArray(size) { (it % 256).toByte() }
        val request = HttpOutgoingRequest(method = "POST", url = "http://127.0.0.1:$port/echo", body = data)
        return when (val r = HttpOutgoingClient.send(request)) {
            is Either.Left -> "FAIL send: ${r.value}"
            is Either.Right -> {
                val body = r.value.body
                val matches = body.size == data.size && body.indices.all { body[it] == data[it] }
                if (matches) "OK large-body round-tripped ${body.size} bytes" else "FAIL content mismatch"
            }
        }
    }

    // --- Capability 51: WASI outgoing HTTP, a refused connection (Review Focus: a connection
    // error must decode to its own `HttpErrorCode` case, not a generic/fallback one -- `port`
    // is one nothing listens on, confirmed by the driver before this probe runs). ---
    @Endpoint(get = "/http-connection-error")
    fun probeHttpConnectionError(port: Int): String {
        val request = HttpOutgoingRequest(method = "GET", url = "http://127.0.0.1:$port/nothing")
        return when (val r = HttpOutgoingClient.send(request)) {
            is Either.Left ->
                if (r.value == HttpErrorCode.ConnectionRefused) {
                    "OK connection-refused decoded correctly"
                } else {
                    "FAIL wrong error code: ${r.value}"
                }
            is Either.Right -> "FAIL unexpected success: status=${r.value.status}"
        }
    }
}

/** The config tree this probe declares; KSP derives one declaration per leaf. */
data class ProbeConfig(val appName: String, val db: ProbeDbConfig, val retries: Int?)

data class ProbeDbConfig(val host: String, val port: Int)

/**
 * Agent config (1.6.0, phase 4.2). The values are provisioned by the deployment, under the
 * component's `agents.ConfigProbeAgent.config` in golem.yaml; a declared-but-unset optional leaf
 * must read back as null.
 */
@Agent(mount = "/config-probe/{id}", description = "Agent config probe")
class ConfigProbeAgent(val id: String, val config: Config<ProbeConfig>) : BaseAgent() {
    @Endpoint(get = "/read")
    fun readConfig(): String {
        val cfg = config.value
        return if (cfg.appName == "probe-app" && cfg.db.host == "db.probe" && cfg.db.port == 5432 && cfg.retries == null) {
            "OK config appName=${cfg.appName} db=${cfg.db.host}:${cfg.db.port} retries=${cfg.retries}"
        } else {
            "FAIL appName=${cfg.appName} db=${cfg.db.host}:${cfg.db.port} retries=${cfg.retries}"
        }
    }
}

/**
 * Static bindings: the router serves a file from its own Initial File System, packaged by the
 * manifest at `agents.ProbeSite.files`. No guest code runs per request.
 */
@HttpRouter(
    typeName = "ProbeSite",
    mount = "/probe-site",
    staticBindings = [FileMapping("/", "/site/index.html")],
    fileResponseHeaders = [ResponseHeader("X-Probe", "static")],
)
class ProbeSiteRouter : BaseAgent()

/**
 * Live files: an ordinary durable agent exposing part of its own filesystem over HTTP, again
 * packaged by the manifest (`agents.ProbeDocsAgent.files`).
 */
@Agent(mount = "/probe-docs/{owner}", exposeFiles = [FileMapping("/latest", "/public/latest.txt")])
class ProbeDocsAgent(val owner: String) : BaseAgent() {
    @Endpoint(post = "/touch")
    fun touch(): String = "OK docs owner=$owner"
}

/** A router whose provider method returns its document from code (no packaged files needed). */
@HttpRouter(typeName = "ProbeApi", mount = "/probe-api")
class ProbeApiRouter : BaseAgent() {
    @OpenApiProvider
    fun describe(): String = """{"openapi":"3.1.0","info":{"title":"probe","version":"1"},"paths":{}}"""
}

/** A custom handler: the response body is produced by guest code, not served from the filesystem. */
@HttpRouter(typeName = "ProbeEcho", mount = "/probe-echo")
class ProbeEchoRouter : BaseAgent() {
    @HttpHandler
    fun serve(request: HttpRequest): HttpResponse = HttpResponse(
        200,
        listOf(HttpHeader.ascii("content-type", "text/plain")),
        AgentStream.of(listOf("OK handler ${request.method} ${request.path}".encodeToByteArray())),
    )
}

enum class Color { RED, GREEN, BLUE }

sealed class Shape {
    data class Circle(val radius: Double) : Shape()
    data class Rect(val w: Int, val h: Int) : Shape()
    object Unknown : Shape()
}

data class Pt(val x: Int, val y: Int)

data class SchemaCorners(
    val id: Uuid,
    val ttl: Duration,
    val blob: ByteArray,
    val note: UnstructuredText,
)

/** The raw schema corners nested inside `option` and `result`, which is where they were recorded as unsupported. */
data class NestedCorners(
    val maybeNote: UnstructuredText?,
    val maybeBlob: ByteArray?,
    val noteOrError: Either<String, UnstructuredText>,
    val blobOrError: Either<String, ByteArray>,
    val absentNote: UnstructuredText?,
)

data class AllTypes(
    val i8: Byte, val i16: Short, val i32: Int, val i64: Long,
    val u8: UByte, val u16: UShort, val u32: UInt, val u64: ULong,
    val f32: Float, val f64: Double, val flag: Boolean, val text: String,
    val opt: Int?, val nums: List<Int>, val color: Color, val shape: Shape,
    val pair: Pair<Int, String>, val dict: Map<String, Int>,
    val res: Either<String, Int>, val ts: Datetime,
)
