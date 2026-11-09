package bridge_consumer

import cloud.golem.BaseAgent
import cloud.golem.annotations.Agent
import cloud.golem.annotations.Description
import cloud.golem.annotations.Endpoint
import cloud.golem.runtime.Either
import golem.bridge.client.calculator.CalculatorClient
import golem.bridge.client.calculator.Circle
import golem.bridge.client.calculator.DescribeInColor
import golem.bridge.client.calculator.DescribeInShape
import golem.bridge.client.calculator.MoveInP
import golem.bridge.client.calculator.Rect

@Agent(mount = "/callers/{run}", description = "Calls the Calculator agent through its generated client")
class BridgeCaller(val run: String) : BaseAgent() {
    private fun calculator() = CalculatorClient.get("calc-$run")

    @Description("add")
    @Endpoint(post = "/add")
    fun add(a: Int, b: Int): String = calculator().use { it.add(a, b).toString() }

    @Description("accumulate")
    @Endpoint(post = "/accumulate")
    fun accumulate(by: Int): String = calculator().use { it.accumulate(by).toString() }

    @Description("move")
    @Endpoint(post = "/move")
    fun move(x: Int, y: Int): String = calculator().use { it.move(MoveInP(x, y), 1, 2).toString() }

    @Description("describe")
    @Endpoint(post = "/describe")
    fun describe(radius: Double): String = calculator().use {
        listOf(
            it.describe(DescribeInShape.Circle(Circle(radius)), DescribeInColor.BLUE),
            it.describe(DescribeInShape.Rect(Rect(2, 3)), null),
            it.describe(DescribeInShape.Empty, DescribeInColor.RED),
        ).joinToString(",")
    }

    @Description("stats")
    @Endpoint(post = "/stats")
    fun stats(): String = calculator().use { it.stats(listOf(1, 2, 3)).toString() }

    @Description("safeDivide")
    @Endpoint(post = "/safeDivide")
    fun safeDivide(a: Int, b: Int): String = calculator().use {
        when (val r = it.safeDivide(a, b)) {
            is Either.Left -> "left:${r.value}"
            is Either.Right -> "right:${r.value}"
        }
    }

    @Description("wide")
    @Endpoint(post = "/wide")
    fun wide(): String = calculator().use { it.wide(7u, 18446744073709551615uL, 1.5f) }

    @Description("asyncAdd")
    @Endpoint(post = "/asyncAdd")
    fun asyncAdd(a: Int, b: Int): String = calculator().use { calc -> calc.addAsync(a, b).use { it.await().toString() } }

    @Description("label")
    @Endpoint(post = "/label")
    fun label(): String = CalculatorClient.getPhantom("calc-$run", cloud.golem.runtime.HostApi.generateIdempotencyKey()).use { it.label() }

    @Description("trigger")
    @Endpoint(post = "/trigger")
    fun trigger(): String = calculator().use {
        it.nothingTrigger()
        "triggered"
    }

    @Description("caller")
    @Endpoint(post = "/caller")
    fun caller(): String = calculator().use { it.caller() }
}
