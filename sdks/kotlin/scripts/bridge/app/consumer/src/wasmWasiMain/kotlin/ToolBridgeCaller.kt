package bridge_consumer

import cloud.golem.BaseAgent
import cloud.golem.annotations.Agent
import cloud.golem.annotations.Description
import cloud.golem.annotations.Endpoint
import cloud.golem.runtime.Either
import cloud.golem.runtime.ToolInvokeError
import golem.bridge.client.arg_probe_tool.ArgProbeClient
import golem.bridge.client.git_probe_tool.GitProbeClient
import golem.bridge.client.stream_probe_tool.StreamProbeClient

private fun <T> unwrap(result: Either<ToolInvokeError<Nothing>, T>): T = when (result) {
    is Either.Right -> result.value
    is Either.Left -> error("tool call failed: ${result.value}")
}

@Agent(mount = "/tool-callers/{run}", description = "Calls Rust tools through their generated clients")
class ToolBridgeCaller(val run: String) : BaseAgent() {
    @Description("search")
    @Endpoint(post = "/search")
    fun search(pattern: String): String = ArgProbeClient.newClient().use {
        unwrap(it.search(pattern, listOf("x", "y"), 3, 5, listOf("a", "b"), true, 2u))
    }

    @Description("searchDefaults")
    @Endpoint(post = "/search-defaults")
    fun searchDefaults(pattern: String): String = ArgProbeClient.newClient().use {
        unwrap(it.search(pattern, emptyList(), null, 2, emptyList(), false, 0u))
    }

    @Description("gitAdd")
    @Endpoint(post = "/git-add")
    fun gitAdd(name: String): String = GitProbeClient.newClient().use {
        unwrap(it.remote("d1", true).add(name, "https://example.invalid/repo"))
    }

    @Description("gitList")
    @Endpoint(post = "/git-list")
    fun gitList(): String = GitProbeClient.newClient().use { unwrap(it.remote(null, false).list()) }

    @Description("upper")
    @Endpoint(post = "/upper")
    fun upper(text: String): String = StreamProbeClient.newClient().use {
        val result = unwrap(it.upper(text.encodeToByteArray()))
        "${result.stdout?.decodeToString()}|${result.value}"
    }
}
