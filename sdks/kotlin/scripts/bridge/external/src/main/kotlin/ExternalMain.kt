import golem.bridge.client.calculator.CalculatorClient
import golem.bridge.client.calculator.Circle
import golem.bridge.client.calculator.DescribeInColor
import golem.bridge.client.calculator.DescribeInShape
import golem.bridge.client.calculator.MoveInP
import golem.bridge.client.calculator.Rect
import golem.bridge.runtime.Datetime
import golem.bridge.runtime.Either
import golem.bridge.runtime.GolemServer
import java.time.Instant

/** Calls the deployed `Calculator` agent from outside Golem through the generated external client and prints one `name=value` line per check. */
fun main(args: Array<String>) {
    val run = args[0]
    CalculatorClient.configure(GolemServer.Local, "bridge", "local")
    val calc = CalculatorClient.get("ext-$run")

    println("add=${calc.add(3, 4)}")
    println("accumulate=${calc.accumulate(5)},${calc.accumulate(6)}")
    println("move=${calc.move(MoveInP(10, 20), 1, 2)}")
    println(
        "describe=" + listOf(
            calc.describe(DescribeInShape.Circle(Circle(2.5)), DescribeInColor.BLUE),
            calc.describe(DescribeInShape.Rect(Rect(2, 3)), null),
            calc.describe(DescribeInShape.Empty, DescribeInColor.RED),
        ).joinToString(","),
    )
    println("stats=${calc.stats(listOf(1, 2, 3))}")
    println(
        "safeDivide=" + listOf(calc.safeDivide(10, 2), calc.safeDivide(1, 0)).joinToString(",") {
            when (it) {
                is Either.Left -> "left:${it.value}"
                is Either.Right -> "right:${it.value}"
            }
        },
    )
    println("wide=${calc.wide(7u, 18446744073709551615uL, 1.5f)}")
    println("asyncAdd=${calc.addAsync(20, 22).get()}")
    println("label=${calc.label()}")
    println("agentId=${calc.agentId.agentId}")
    calc.nothingTrigger()
    println("trigger=ok")
    calc.nothingScheduleAt(Datetime.fromInstant(Instant.now().plusSeconds(3600)))
    println("schedule=ok")
    val phantom = CalculatorClient.newPhantom("ext-$run")
    println("phantomLabel=${phantom.label()}")
    println("phantomDistinct=${phantom.agentId.agentId != calc.agentId.agentId}")
}
