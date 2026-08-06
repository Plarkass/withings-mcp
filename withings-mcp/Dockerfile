# Serveur MCP Withings (partymola/withings-mcp) exposé en HTTP/SSE via mcp-proxy,
# sur le modèle du déploiement Docker de Taxuspt/garmin_mcp.
FROM python:3.13-slim

# withings-mcp épingle mcp==2.0.0 alors que mcp-proxy 0.12.0 exige mcp<2 :
# les deux vivent dans des venvs isolés, mcp-proxy lançant withings-mcp en
# sous-processus via le PATH (aucune dépendance Python partagée).
ENV PYTHONUNBUFFERED=1 \
    WITHINGS_MCP_CONFIG_DIR=/config \
    WITHINGS_MCP_DB_PATH=/data/withings.db \
    PATH="/opt/withings/bin:/opt/proxy/bin:${PATH}"

# withings-mcp n'est pas publié sur PyPI : installation depuis GitHub, commit épinglé.
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

# Mode serveur HTTP par défaut ; les services one-shot (auth, sync) du compose
# remplacent cette commande par "withings-mcp auth" / "withings-mcp sync".
CMD ["mcp-proxy", "--host", "0.0.0.0", "--port", "8586", "--pass-environment", "withings-mcp"]
