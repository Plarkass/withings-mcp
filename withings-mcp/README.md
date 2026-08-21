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

- **Streamable HTTP**: `http://127.0.0.1:8586/mcp`
- **SSE**: `http://127.0.0.1:8586/sse`
- **Healthcheck**: `http://127.0.0.1:8586/status`

The port is published on loopback only by default — see [Configuration](#configuration).

As `withings-mcp` is not yet published on PyPI, the Dockerfile installs it from
GitHub at a **pinned commit** (`f250123`) for a reproducible build.

> Note: `withings-mcp` pins `mcp==2.0.0`. `mcp-proxy` 0.12.0 declares only
> `mcp>=1.17.0`, but it fails at import against 2.x (`cannot import name
> 'request_ctx' from mcp.server.lowlevel.server`) — a real incompatibility its
> metadata does not express. The image therefore installs them in two isolated
> venvs (`/opt/withings`, `/opt/proxy`), with mcp-proxy spawning withings-mcp as a
> subprocess — no shared dependencies.

## Prerequisites

1. A Withings developer account: https://developer.withings.com/dashboard
2. Create an application with:
   - **Callback URL**: `http://localhost:8585`
   - **Scopes**: `user.info,user.metrics,user.activity`
3. Note the *Client ID* and *Client Secret*.

## Getting started

```bash
cd withings-mcp
cp .env.example .env        # optional: bind address, port, TZ, sync depth

# The container runs as uid 10001, so the bind-mounted directories must be
# writable by it.
mkdir -p config data && sudo chown -R 10001:10001 config data

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
# 3. Initial cache population, with the server still stopped
#    (30 days by default, see WITHINGS_SYNC_DAYS)
docker compose run --rm sync

# 4. Start the MCP server
docker compose up -d
docker compose ps    # the healthcheck should report "healthy"
```

## Connecting MCP clients

**Claude Code** (HTTP transport), on the Docker host itself:

```bash
claude mcp add -s user --transport http withings http://127.0.0.1:8586/mcp
```

From another machine, forward the port rather than publishing it:

```bash
ssh -L 8586:127.0.0.1:8586 user@server
```

**Claude Desktop / SSE clients** — `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "withings": {
      "url": "http://127.0.0.1:8586/sse"
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

## Keeping the cache fresh

**Do not schedule `docker compose run --rm sync` against a running server.** The
query tools already auto-sync when their data is stale, in the server's own
process, so a scheduled sync buys nothing — and it actively breaks things:

Withings rotates the refresh token on every use, and upstream caches tokens in
module-level state that it reads once and never re-reads
([`auth.py`](https://github.com/partymola/withings-mcp/blob/main/src/withings_mcp/auth.py)).
A separate `sync` container rotating the token on disk therefore leaves the
long-running server holding a token Withings has already invalidated. Every tool
call then fails with `Token refresh failed. Run: withings-mcp auth`, and
`restart: unless-stopped` cannot recover it because the process never exits.

The two processes also open the same SQLite file, which upstream opens without WAL
and with the default 5-second busy timeout, so overlapping access can surface as
`database is locked`.

If you do want a scheduled sync, restart the server immediately afterwards so it
re-reads the rotated token:

```cron
0 6 * * * cd /path/to/withings-mcp && docker compose run --rm sync && docker compose restart withings-mcp
```

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `WITHINGS_MCP_BIND` | `127.0.0.1` | Host address the port is published on |
| `WITHINGS_MCP_PORT` | `8586` | Host port |
| `WITHINGS_SYNC_DAYS` | `30` | History depth for the one-shot `sync` |
| `TZ` | `Europe/Paris` | Container timezone |

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

> ⚠️ mcp-proxy has **no authentication** — no token, no bearer, nothing. Anyone who
> can reach port 8586 can read your weight, sleep, blood pressure and ECG history.
> That is why it is bound to `127.0.0.1` by default. If you set
> `WITHINGS_MCP_BIND=0.0.0.0`, remember that Docker inserts its port rules ahead of
> ufw/firewalld, so a host firewall will *not* protect it — put a VPN or an
> authenticating reverse proxy in front instead.
