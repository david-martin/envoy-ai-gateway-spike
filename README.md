# Spike: Using 'aigw' for MCP features behind Istio

## Approach

* Install Istio locally in a simple Kubernetes setup.
* Deploy the standalone aigw binary as a service.
* Configure Istio routing so /mcp/* traffic is sent to the aigw service.
* Add one or more MCP servers to aigw (local and/or external).
* Test MCP interactions through the Istio gateway using MCP Inspector or Claude.
* Note what works and where it breaks — protocol, auth w/ kuadrant, notifications, etc.

## Outcomes

* Determine feasibility of using aigw behind Istio for MCP gateway functionality.
    * In particular, can kuadrant AuthPolicy be used similar to existing kagenti/mcp-gateway auth examples.
* Gain a clearer understanding of Envoy AI Gateway’s architecture and integration points.
    * What pieces are potentially reusable at the envoy layer
* Identify key limitations and potential gaps (e.g., missing features or lifecycle management & control plane needs) for Istio compatibility.
    * What does kagenti/mcp-gateway do/have that this doesn’t, and vice versa?
