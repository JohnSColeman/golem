package fixtures.single

import cloud.golem.Principal
import cloud.golem.annotations.ToolDefinition
import cloud.golem.annotations.ToolError
import cloud.golem.annotations.ToolErrorKind
import cloud.golem.annotations.ToolMiddleware
import cloud.golem.runtime.Either

sealed class EchoError {
    @ToolError(kind = ToolErrorKind.RUNTIME, exitCode = 1)
    data class Rejected(val message: String) : EchoError()

    @ToolError(kind = ToolErrorKind.USAGE, exitCode = 2)
    object Gone : EchoError()

    @ToolError(kind = ToolErrorKind.RUNTIME, exitCode = 3)
    class Empty : EchoError()
}

@ToolDefinition(name = "single-echo", version = "1.0.0")
interface SingleEcho {
    fun echo(value: String): Either<EchoError, String>
    fun count(itemList: List<String>): Int
    fun whoAmI(label: String, principal: Principal?): String
    fun reset(): Unit
    fun reports(): SingleReports
}

@ToolDefinition(name = "single-reports", version = "1.0.0")
interface SingleReports {
    fun low(threshold: Int): Either<EchoError, List<String>>
}

@ToolMiddleware(name = "single-audit")
class SingleAudit : SingleEchoMiddleware() {
    override fun echo(underlying: SingleEchoUnderlying, value: String) = underlying.echo(value)

    override fun whoAmI(underlying: SingleEchoUnderlying, label: String, principal: Principal?) = underlying.whoAmI(label)

    override fun reportsLow(underlying: SingleEchoUnderlying, threshold: Int) = underlying.reports().low(threshold)
}
