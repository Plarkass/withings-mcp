# Withings MCP server (partymola/withings-mcp) exposed over HTTP/SSE via mcp-proxy,
# modeled on the Docker deployment of Taxuspt/garmin_mcp.
#
# Base image pinned by digest (python:3.13-slim as of 2026-08-10) so rebuilds are
# reproducible. Bump it deliberately to pick up base-image security updates.
FROM python:3.13-slim@sha256:ffb752e139c0a19692a43af8d8523b274222dd68eebad5d583b45c2201c6e30a

# withings-mcp 0.8.0 pins mcp==2.1.1. mcp-proxy 0.12.0 declares only mcp>=1.17.0,
# but it breaks at import against 2.x ("cannot import name 'request_ctx' from
# mcp.server.lowlevel.server") — a real runtime incompatibility that the metadata
# does not express. Hence two isolated venvs, with mcp-proxy spawning withings-mcp
# as a subprocess via PATH: no shared Python dependencies.
ENV PYTHONUNBUFFERED=1 \
    WITHINGS_MCP_CONFIG_DIR=/config \
    WITHINGS_MCP_DB_PATH=/data/withings.db \
    PATH="/opt/withings/bin:/opt/proxy/bin:${PATH}"

# Both packages come from PyPI, pinned to an exact version for reproducible builds.
RUN python -m venv /opt/withings \
    && /opt/withings/bin/pip install --no-cache-dir "withings-mcp==0.8.0" \
    && python -m venv /opt/proxy \
    && /opt/proxy/bin/pip install --no-cache-dir "mcp-proxy==0.12.0" "mcp==1.29.0"

# Version banner on startup, written to stderr so it never lands in the stdio
# JSON-RPC stream. VERSION is the deployment's own number, read at runtime, so no
# build argument is needed — a stack manager that builds without --build-arg
# still reports it correctly. Copied after the installs to keep them cached.
COPY VERSION /etc/withings-mcp/deploy-version
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

# Run unprivileged: /config holds the client secret and a year-long refresh token.
# Host-side bind mounts must be owned by this uid (see README).
RUN useradd --system --uid 10001 --create-home withings \
    && mkdir -p /config /data \
    && chown -R 10001:10001 /config /data

VOLUME ["/config", "/data"]

USER withings

EXPOSE 8586

# The entrypoint prints the banner and then execs the command below, so the
# version is logged for every mode — server, auth and sync alike.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# HTTP server mode by default; the one-shot compose services (auth, sync)
# override this command with "withings-mcp auth" / "withings-mcp sync".
CMD ["mcp-proxy", "--host", "0.0.0.0", "--port", "8586", "--pass-environment", "withings-mcp"]
