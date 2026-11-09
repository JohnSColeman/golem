package bridge_provider

import cloud.golem.BaseAgent
import cloud.golem.Principal
import cloud.golem.annotations.Agent
import cloud.golem.annotations.Description
import cloud.golem.annotations.Endpoint
import cloud.golem.runtime.Either

data class Point(val x: Int, val y: Int)

enum class Color { RED, GREEN, BLUE }

sealed class Shape {
    data class Circle(val radius: Double) : Shape()

    data class Rect(val width: Int, val height: Int) : Shape()

    object Empty : Shape()
}

@Agent(mount = "/calculators/{label}", description = "A calculator that other components call through a generated client")
class Calculator(val label: String) : BaseAgent() {
    private var total = 0

    @Description("add")
    @Endpoint(post = "/add")
    fun add(a: Int, b: Int): Int = a + b

    @Description("accumulate")
    @Endpoint(post = "/accumulate")
    fun accumulate(by: Int): Int {
        total += by
        return total
    }

    @Description("move")
    @Endpoint(post = "/move")
    fun move(p: Point, dx: Int, dy: Int): Point = Point(p.x + dx, p.y + dy)

    @Description("describe")
    @Endpoint(post = "/describe")
    fun describe(shape: Shape, color: Color?): String = when (shape) {
        is Shape.Circle -> "circle(${shape.radius})"
        is Shape.Rect -> "rect(${shape.width}x${shape.height})"
        Shape.Empty -> "empty"
    } + (color?.let { "/$it" } ?: "")

    @Description("stats")
    @Endpoint(post = "/stats")
    fun stats(values: List<Int>): Map<String, Int> = mapOf("count" to values.size, "sum" to values.sum())

    @Description("safeDivide")
    @Endpoint(post = "/safeDivide")
    fun safeDivide(a: Int, b: Int): Either<String, Int> = if (b == 0) Either.Left("division by zero") else Either.Right(a / b)

    @Description("wide")
    @Endpoint(post = "/wide")
    fun wide(small: UByte, big: ULong, ratio: Float): String = "$small/$big/$ratio"

    @Description("nothing")
    @Endpoint(post = "/nothing")
    fun nothing() {
        total = 0
    }

    @Description("label")
    @Endpoint(post = "/label")
    fun label(): String = label

    @Description("caller")
    @Endpoint(post = "/caller")
    fun caller(): String = when (val p = principal) {
        is Principal.Agent -> "agent:${p.agentId}:${p.componentId.highBits != 0uL || p.componentId.lowBits != 0uL}"
        else -> "other"
    }
}
