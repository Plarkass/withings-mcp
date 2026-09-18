#!/bin/sh
# Print a version banner, then hand over to the real command.
#
# The banner goes to stderr on purpose: this image also runs as a stdio MCP
# server, where stdout carries the JSON-RPC frames and anything else on it
# corrupts the session. `docker logs` captures stderr just the same.
set -e

pkg_version() {
    "$1" -c "from importlib.metadata import version; print(version('$2'))" 2>/dev/null \
        || echo "unknown"
}

{
    printf 'withings-mcp deployment %s\n' \
        "$(cat /etc/withings-mcp/deploy-version 2>/dev/null || echo unknown)"
    printf '  withings-mcp  %s\n' "$(pkg_version /opt/withings/bin/python withings-mcp)"
    printf '  mcp-proxy     %s\n' "$(pkg_version /opt/proxy/bin/python mcp-proxy)"
    printf '  mcp           %s (server) / %s (proxy)\n' \
        "$(pkg_version /opt/withings/bin/python mcp)" \
        "$(pkg_version /opt/proxy/bin/python mcp)"
} >&2

exec "$@"
