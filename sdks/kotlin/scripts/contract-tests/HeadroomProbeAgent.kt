package example_counter

import cloud.golem.BaseAgent
import cloud.golem.annotations.Agent
import cloud.golem.annotations.Description
import cloud.golem.annotations.Endpoint
import cloud.golem.wasm.alloc

/**
 * The agent of `native-headroom-tests.sh`. It reports where the SDK's arena starts, which is the arena headroom the component was built
 * with, and prints a string of a given size through the Kotlin standard library, the one operation whose memory comes from the headroom.
 */
@Agent(mount = "/headroom/{name}", description = "Arena headroom probe agent")
class HeadroomProbeAgent(val name: String) : BaseAgent() {
    @Description("The address the arena allocator hands out next: the headroom, plus the few bytes this call's input took")
    @Endpoint(post = "/arena-start")
    fun arenaStart(): String = "OK arena at ${alloc(0, 1)}"

    @Description("println of a string of kib KiB")
    @Endpoint(post = "/print/{kib}")
    fun printKiB(kib: Int): String {
        println(" ".repeat(kib * 1024))
        return "OK printed $kib KiB"
    }
}
