# Withings MCP server (partymola/withings-mcp) exposed over HTTP/SSE via mcp-proxy,
# modeled on the Docker deployment of Taxuspt/garmin_mcp.
FROM python:3.13-slim

# withings-mcp pins mcp==2.0.0 while mcp-proxy 0.12.0 requires mcp<2:
# each lives in its own isolated venv, with mcp-proxy spawning withings-mcp
# as a subprocess via PATH (no shared Python dependencies).
ENV PYTHONUNBUFFERED=1 \
    WITHINGS_MCP_CONFIG_DIR=/config \
    WITHINGS_MCP_DB_PATH=/data/withings.db \
    PATH="/opt/withings/bin:/opt/proxy/bin:${PATH}"

# withings-mcp is not published on PyPI: install from GitHub at a pinned commit.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && python -m venv /opt/withings \
    && /opt/withings/bin/pip install --no-cache-dir \
        "withings-mcp @ git+https://github.com/partymola/withings-mcp.git@f250123f32eac3423bff2895425918c5f2af4d4a" \
    && python -m venv /opt/proxy \
    && /opt/proxy/bin/pip install --no-cache-dir "mcp-proxy==0.12.0" "mcp==1.29.0" \
    && apt-get purge -y git \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

VOLUME ["/config", "/data"]

EXPOSE 8586

# HTTP server mode by default; the one-shot compose services (auth, sync)
# override this command with "withings-mcp auth" / "withings-mcp sync".
CMD ["mcp-proxy", "--host", "0.0.0.0", "--port", "8586", "--pass-environment", "withings-mcp"]
