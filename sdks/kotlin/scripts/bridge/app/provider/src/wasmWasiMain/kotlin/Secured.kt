package bridge_provider

import cloud.golem.BaseAgent
import cloud.golem.Principal
import cloud.golem.annotations.Agent
import cloud.golem.annotations.Description
import cloud.golem.annotations.Endpoint

private fun describe(principal: Principal): String = when (principal) {
    is Principal.Oidc -> "oidc:${principal.sub}:${principal.email}"
    Principal.Anonymous -> "anonymous"
    else -> "other"
}

/** Serves one open endpoint and one that requires authentication, to check that the host enforces `auth = true` per request. */
@Agent(mount = "/secured/{name}", description = "An agent with an open and an authenticated endpoint")
class Secured(val name: String) : BaseAgent() {
    @Description("open")
    @Endpoint(get = "/open")
    fun open(): String = "open:${describe(principal)}"

    @Description("me")
    @Endpoint(get = "/me", auth = true)
    fun me(): String = "me:${describe(principal)}"
}
