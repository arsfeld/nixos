# ADR 001: Rollback of Caddy-Tailscale Integration

**Date**: 2025-10-15
**Status**: Accepted
**Decision Makers**: System Architecture Team

## Context

We attempted to replace our existing tsnsrv-based Tailscale service routing with a consolidated Caddy-based solution using the official caddy-tailscale plugin. The goal was to reduce resource overhead and simplify our infrastructure by consolidating multiple tsnsrv processes into a single Caddy process with embedded Tailscale support.

### Original Problem

The system was running multiple tsnsrv instances (40+ separate processes), each creating its own Tailscale node and WireGuard tunnel for different services. We hypothesized that consolidating these into a single Caddy process would:

- Reduce memory and CPU overhead from multiple processes
- Simplify service management and configuration
- Reduce WireGuard tunnel overhead
- Provide better integration between HTTP routing and Tailscale networking

## Investigation Findings

After implementing and analyzing the caddy-tailscale solution, we discovered several critical issues:

### 1. **No Resource Reduction**

The caddy-tailscale plugin creates **40+ separate tsnet nodes** inside the Caddy process, each with:
- Its own WireGuard tunnel
- Independent networking stack
- Separate authentication state

This means the resource overhead is identical to (or worse than) running separate tsnsrv processes - we simply moved the overhead from multiple processes to threads/goroutines within a single process.

### 2. **Additional Hop for Funnel**

When using Tailscale Funnel (to expose services publicly), the caddy-tailscale implementation adds an **additional network hop** through the host's tailscaled daemon. This means:

```
Request → Caddy (tsnet node) → Host tailscaled → Internet
```

versus the original tsnsrv approach:

```
Request → tsnsrv (direct funnel) → Internet
```

This extra hop adds latency and complexity without providing any benefit.

### 3. **Complexity Without Benefits**

The caddy-tailscale implementation required:
- Custom Go packaging and vendoring
- Complex Nix build expressions
- Additional OAuth configuration
- Managing plugin compatibility with Caddy versions

All of this complexity provided no measurable benefit over the simpler tsnsrv approach.

## Decision

**We are rolling back the caddy-tailscale implementation and returning to tsnsrv.**

### Rationale

1. **No resource savings**: The primary goal (reducing overhead) was not achieved
2. **Increased latency**: The additional hop for Funnel degrades performance
3. **Unnecessary complexity**: The implementation complexity is not justified by the benefits
4. **Proven stability**: tsnsrv is working reliably and is simpler to maintain

### What We're Keeping

- The existing tsnsrv-based routing architecture
- Caddy for HTTP routing and authentication (without Tailscale integration)
- Current service configuration patterns

## Consequences

### Positive

- ✅ Return to simpler, proven architecture
- ✅ Remove complex build dependencies (custom Go packaging)
- ✅ Eliminate the extra network hop for Funnel
- ✅ Easier maintenance and troubleshooting

### Negative

- ❌ Time invested in implementation is lost
- ❌ Multiple tsnsrv processes remain (but this is acceptable given no better alternative)

## Future Considerations

If we want to reduce resource overhead in the future, we should investigate:

1. **Tailscale's native serve/funnel**: Use Tailscale's built-in HTTP serving instead of separate proxies
2. **Single tsnsrv with routing**: Modify tsnsrv to handle multiple services through one node (would require upstream changes)
3. **Alternative solutions**: Wait for Tailscale or Caddy to provide better integration that actually reduces overhead

## Related Tasks

- task-13: Remove caddy-tailscale implementation (implementation task)
- task-3: Complete migration from tsnsrv to Caddy-based Tailscale plugin (archived)
- task-7: Complete caddy-tailscale migration testing and deployment (archived)
- task-10: Prepare caddy-tailscale for deployment (archived)

## References

- [Caddy Tailscale Plugin](https://github.com/tailscale/caddy-tailscale)
- [tsnsrv Documentation](https://github.com/boinkor-net/tsnsrv)
- Original optimization proposal: `docs/tsnsrv-optimization-proposal.md`
