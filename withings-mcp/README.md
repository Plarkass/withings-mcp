# Withings MCP — Docker deployment

Docker deployment of a Withings MCP server, modeled on
[Taxuspt/garmin_mcp](https://github.com/Taxuspt/garmin_mcp): self-contained image,
OAuth tokens persisted in a volume, local data cache, and HTTP exposure for remote
MCP clients (Claude Code, Claude Desktop, Home Assistant, etc.).

## Chosen implementation

Among the four candidate implementations,
[**partymola/withings-mcp**](https://github.com/partymola/withings-mcp) is the one used:

| Implementation | Language | Transport | Why not? |
|---|---|---|---|
| **partymola/withings-mcp** ✅ | Python 3.13 | stdio | Closest to garmin_mcp: incremental SQLite cache, automatic token refresh, 8 tools (body, sleep, activity, workouts, ECG, trends), zero dependencies beyond `mcp` |
| [gchallen/withings-mcp](https://github.com/gchallen/withings-mcp) | TypeScript/Bun | stdio | Limited coverage (weight/body composition), tokens stored in `.env` |
| [davidmosiah/withings-mcp](https://github.com/davidmosiah/withings-mcp) | TypeScript/Node | stdio | No Docker support, `~/.withings-mcp` config poorly suited to containers |
| [akutishevsky/withings-mcp](https://github.com/akutishevsky/withings-mcp) | TypeScript/Bun | HTTP | Requires Supabase + encryption secret: too heavy for personal use |

Since the server is stdio-only, the image adds
[`mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) to expose it over the network:

- **Streamable HTTP**: `http://<host>:8586/mcp`
- **SSE**: `http://<host>:8586/sse`
- **Healthcheck**: `http://<host>:8586/status`

As `withings-mcp` is not yet published on PyPI, the Dockerfile installs it from
GitHub at a **pinned commit** (`f250123`) for a reproducible build.

> Note: `withings-mcp` pins `mcp==2.0.0` while `mcp-proxy` requires `mcp<2`.
> The image therefore installs them in two isolated venvs (`/opt/withings`,
> `/opt/proxy`), with mcp-proxy spawning withings-mcp as a subprocess — no shared
> dependencies.

## Prerequisites

1. A Withings developer account: https://developer.withings.com/dashboard
2. Create an application with:
   - **Callback URL**: `http://localhost:8585`
   - **Scopes**: `user.info,user.metrics,user.activity`
3. Note the *Client ID* and *Client Secret*.

## Getting started

```bash
cd withings-mcp
cp .env.example .env        # optional: port, TZ, sync depth

# 1. Build the image
docker compose build

# 2. OAuth setup (one time only, interactive)
docker compose run --rm auth
```

The `auth` step prompts for the Client ID/Secret, prints the Withings authorization
URL to open in your browser, then captures the callback on `localhost:8585` and saves
the tokens to `./config/` (mounted into the container). The refresh token is valid
for 1 year and renews itself automatically with use.

> **Remote (headless) server**: the callback must reach `localhost:8585` on the
> machine running the container. From your workstation, open an SSH tunnel before
> clicking the authorization URL:
> ```bash
> ssh -L 8585:localhost:8585 user@server
> ```

```bash
# 3. Initial cache population (30 days by default, see WITHINGS_SYNC_DAYS)
docker compose run --rm sync

# 4. Start the MCP server
docker compose up -d
docker compose ps    # the healthcheck should report "healthy"
```

## Connecting MCP clients

**Claude Code** (HTTP transport):

```bash
claude mcp add -s user --transport http withings http://<host>:8586/mcp
```

**Claude Desktop / SSE clients** — `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "withings": {
      "url": "http://<host>:8586/sse"
    }
  }
}
```

**Pure stdio alternative** (without the HTTP proxy, like garmin_mcp locally):

```json
{
  "mcpServers": {
    "withings": {
      "command": "docker",
      "args": [
        "run", "-i", "--rm",
        "-v", "/path/to/withings-mcp/config:/config",
        "-v", "/path/to/withings-mcp/data:/data",
        "withings-mcp:latest",
        "withings-mcp"
      ]
    }
  }
}
```

## Scheduled sync

The query tools re-sync on their own when the cache is stale, but a regular sync
keeps responses instant. Example cron entry on the Docker host:

```cron
0 6 * * * cd /path/to/deploy/withings-mcp && docker compose run --rm sync >> /var/log/withings-sync.log 2>&1
```

(A Dockhand schedule or a Home Assistant automation works just as well.)

## Exposed tools

| Tool | Description | Source |
|---|---|---|
| `withings_sync` | Syncs the Withings API into the local cache | API → SQLite |
| `withings_get_body` | Body composition (weight, fat, muscle, bone, BP, SpO2) | Cache |
| `withings_get_sleep` | Sleep summaries, or detailed phases with `detail=True` | Cache / API |
| `withings_get_activity` | Daily steps, distance, calories, active time | Cache |
| `withings_get_workouts` | Workout sessions (type, duration, HR) | Cache |
| `withings_get_heart` | ECG recordings and AFib detection | API (always) |
| `withings_get_devices` | Connected devices and battery level | API (always) |
| `withings_trends` | Period averages, trends, comparisons | Cache |

## Layout and data

```
withings-mcp/
├── Dockerfile            # image: withings-mcp (pinned commit) + mcp-proxy
├── docker-compose.yml    # services: withings-mcp (server), auth, sync (one-shot)
├── .env.example
├── config/               # withings_client.json + withings_tokens.json (gitignored)
└── data/                 # withings.db, SQLite cache (gitignored)
```

OAuth secrets and the health database stay on the host, excluded from git by the
`.gitignore`. Back up `config/` if you want to avoid redoing the OAuth flow after
a reinstall.

> ⚠️ Port 8586 has **no authentication**: anyone who can reach it can read your
> health data. Only expose it on a trusted network (LAN, VPN, internal Docker
> network) — never directly on the Internet.
