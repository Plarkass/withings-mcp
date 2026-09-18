# withings-mcp — deployment

Deployment of the [**partymola/withings-mcp**](https://github.com/partymola/withings-mcp)
MCP server: your Withings health data (weight and body composition, sleep,
activity, workouts, ECG) exposed to MCP clients such as Claude Code, Claude
Desktop or Home Assistant.

Two ways to run it, documented below:

| | [Local install (pip)](#install-a--local-pip) | [Docker](#install-b--docker) |
|---|---|---|
| Transport | stdio | HTTP + SSE (via `mcp-proxy`) |
| Needs | Python 3.13+ | Docker + Compose |
| Best for | a single machine, a single client | a home server, several clients, always-on |

Both use the same OAuth flow and the same on-disk token files — see
[Authentication](#authentication).

---

## Contents

- [What is in this repo](#what-is-in-this-repo)
- [Prerequisites: register a Withings app](#prerequisites-register-a-withings-app)
- [Install A — local (pip)](#install-a--local-pip)
- [Install B — Docker](#install-b--docker)
- [Authentication](#authentication)
- [Connecting MCP clients](#connecting-mcp-clients)
- [CLI reference](#cli-reference)
- [Exposed tools](#exposed-tools)
- [Configuration](#configuration)
- [Keeping the cache fresh](#keeping-the-cache-fresh)
- [Security](#security)

---

## What is in this repo

```
.
├── Dockerfile            # withings-mcp 0.8.0 + mcp-proxy, two isolated venvs
├── docker-compose.yml    # services: withings-mcp (server), auth, sync (one-shot)
├── .env.example          # bind address, port, TZ, sync depth
├── config/               # withings_client.json + withings_tokens.json (gitignored)
└── data/                 # withings.db, the SQLite cache (gitignored)
```

This repo holds **deployment only**; the server itself lives upstream at
[partymola/withings-mcp](https://github.com/partymola/withings-mcp) and is
published on [PyPI](https://pypi.org/project/withings-mcp/) (GPL-3.0-or-later).

`config/` and `data/` are excluded from git: they hold your OAuth secrets and
your health database.

<details>
<summary>Why this implementation, and why the Docker image carries a proxy</summary>

Among the available Withings MCP servers, `partymola/withings-mcp` is the closest
to the [Taxuspt/garmin_mcp](https://github.com/Taxuspt/garmin_mcp) model that
inspired this deployment: incremental SQLite cache, automatic token refresh, 8
tools, and no dependency beyond `mcp`.

| Implementation | Language | Transport | Why not? |
|---|---|---|---|
| **partymola/withings-mcp** ✅ | Python 3.13+ | stdio | — |
| [gchallen/withings-mcp](https://github.com/gchallen/withings-mcp) | TypeScript/Bun | stdio | Limited coverage (weight/body composition), tokens stored in `.env` |
| [davidmosiah/withings-mcp](https://github.com/davidmosiah/withings-mcp) | TypeScript/Node | stdio | No Docker support, `~/.withings-mcp` config poorly suited to containers |
| [akutishevsky/withings-mcp](https://github.com/akutishevsky/withings-mcp) | TypeScript/Bun | HTTP | Requires Supabase + an encryption secret: too heavy for personal use |

The server speaks stdio only, so the image adds
[`mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) to expose it over the
network. The two are installed in **separate venvs** (`/opt/withings`,
`/opt/proxy`): `withings-mcp` 0.8.0 pins `mcp==2.1.1`, while `mcp-proxy` 0.12.0
declares `mcp>=1.17.0` but breaks at import against 2.x (`cannot import name
'request_ctx' from mcp.server.lowlevel.server`) — a real incompatibility its
metadata does not express. mcp-proxy spawns `withings-mcp` as a subprocess, so
they share no Python dependencies.

</details>

---

## Prerequisites: register a Withings app

Whichever install you pick, you first need your own Withings API application:

1. Sign in at <https://developer.withings.com/dashboard>.
2. Create an application.
3. Set the **callback URL** to exactly `http://localhost:8585`.
4. Request the scopes `user.info,user.metrics,user.activity`.
5. Keep the **Client ID** and **Client Secret** at hand — `withings-mcp auth`
   will ask for them.

---

## Install A — local (pip)

Requires **Python 3.13+** (the package pins `mcp==2.1.1`, which needs 3.13).

```bash
python3.13 -m venv ~/.venvs/withings
~/.venvs/withings/bin/pip install withings-mcp
```

Pick a **fixed working directory** for the credentials and the cache, and point
the two environment variables at it. By default `withings-mcp` writes to
`./config/` and `./withings.db` *relative to the current directory*, so running
`auth` in one place and the server in another silently gives you two unrelated
setups — setting these explicitly avoids the whole class of problem:

```bash
mkdir -p ~/.local/share/withings-mcp
export WITHINGS_MCP_CONFIG_DIR=~/.local/share/withings-mcp/config
export WITHINGS_MCP_DB_PATH=~/.local/share/withings-mcp/withings.db
```

Then authenticate and fill the cache:

```bash
~/.venvs/withings/bin/withings-mcp auth            # see Authentication below
~/.venvs/withings/bin/withings-mcp sync --days 90  # first sync, deeper history
~/.venvs/withings/bin/withings-mcp doctor          # verify the setup
```

Register the server with your client — [Connecting MCP clients](#connecting-mcp-clients).

> `uvx withings-mcp` runs it without installing anything, which is handy for a
> one-off `auth` or `doctor`. For a server an MCP client spawns repeatedly,
> prefer the venv: the path is stable and startup is not gated on a resolver.

---

## Install B — Docker

```bash
cp .env.example .env        # optional: bind address, port, TZ, sync depth

# The container runs as uid 10001, so the bind-mounted directories must be
# writable by it.
mkdir -p config data && sudo chown -R 10001:10001 config data

# 1. Build the image
docker compose build

# 2. OAuth setup (one time only, interactive) — see Authentication below
docker compose run --rm auth

# 3. Initial cache population, with the server still stopped
#    (30 days by default, see WITHINGS_SYNC_DAYS)
docker compose run --rm sync

# 4. Start the MCP server
docker compose up -d
docker compose ps    # the healthcheck should report "healthy"
```

The server is then reachable at:

- **Streamable HTTP**: `http://127.0.0.1:8586/mcp`
- **SSE**: `http://127.0.0.1:8586/sse`
- **Healthcheck**: `http://127.0.0.1:8586/status`

The port is published on **every interface** by default, for deployments that
put a reverse proxy in front. mcp-proxy has no authentication whatsoever, so read
[Security](#security) before leaving it that way — `WITHINGS_MCP_BIND=127.0.0.1`
keeps it on loopback.

---

## Authentication

Withings uses OAuth 2.0 with an authorization code. You never give the server
your Withings password: you approve it once in the browser, and it keeps a
refresh token from then on. The same command does it in both installs:

```bash
# Local (pip)
~/.venvs/withings/bin/withings-mcp auth

# Docker
docker compose run --rm auth
```

### What happens, step by step

1. **Credentials.** It prompts for the *Client ID* and *Client Secret* of the app
   you registered at [developer.withings.com](https://developer.withings.com/dashboard),
   and writes them to `withings_client.json` with mode `0600`. On later runs it
   offers to reuse them instead of asking again.
2. **Authorization URL.** It generates a random `state` (32 bytes, for CSRF
   protection), builds the URL to
   `https://account.withings.com/oauth2_user/authorize2` with your client id, the
   scopes `user.info,user.metrics,user.activity` and the redirect
   `http://localhost:8585`, then opens your browser — and prints the URL as well,
   in case it cannot.
3. **You approve** on the Withings page, with your own Withings account.
4. **Callback.** Withings redirects to `http://localhost:8585/?code=…&state=…`.
   A one-shot HTTP server, started on port 8585 for this purpose, receives it. It
   first checks that the returned `state` matches the one it generated — a
   mismatch is rejected as a possible CSRF attempt — then reads the
   authorization `code`.
5. **Token exchange.** The code is exchanged **immediately, inside the callback
   handler**: Withings authorization codes expire after about 30 seconds, so the
   exchange cannot wait for the little web server to shut down. It POSTs to
   `https://wbsapi.withings.net/v2/oauth2` with `action=requesttoken`,
   `grant_type=authorization_code`, your client id and secret, the code and the
   same redirect URI. (Withings signals errors in a JSON `status` field rather
   than the HTTP status, so a `status` other than `0` is a failure even on a
   200 response.)
6. **Storage.** The response yields an access token, a refresh token, your
   Withings `userid` and a lifetime. They are written to `withings_tokens.json`,
   mode `0600`, with an absolute `expires_at` computed from `expires_in` (3 hours
   by default). The step ends with `Tokens saved. User ID: …`.

The whole exchange waits at most 120 seconds; if you do not approve in time, it
exits with an error and you simply rerun it.

### Where the tokens live

| File | Contents |
|---|---|
| `withings_client.json` | `client_id`, `client_secret` |
| `withings_tokens.json` | `access_token`, `refresh_token`, `userid`, `expires_at` |

Both sit in the directory given by `WITHINGS_MCP_CONFIG_DIR` (default `./config/`
relative to the current directory). Under Docker that is `./config/` on the host,
bind-mounted at `/config`.

Both are `0600` on POSIX — on Windows the mode is ignored and access is governed
by ACLs — and `config/` is excluded by `.gitignore`. **This directory is the
thing to back up**: with it, a reinstall needs no new authorization; without it,
you redo the flow above. Treat it exactly like a password file — the refresh
token alone grants a year of access to your health data.

### Staying authenticated afterwards

The server refreshes on its own; there is nothing to schedule.

- The **access token lasts 3 hours**. Before each API call the server checks
  `expires_at` with a 5-minute safety margin.
- If it has expired, the server posts a `grant_type=refresh_token` request and
  rewrites `withings_tokens.json` with the new pair.
- The **refresh token is valid for a year**, and Withings **rotates it on every
  use** — each refresh returns a new one, replacing the old, which is why only a
  single process may hold these tokens at a time (see
  [Keeping the cache fresh](#keeping-the-cache-fresh)).

### Re-running it

Rerun `withings-mcp auth` whenever you see `Token refresh failed. Run:
withings-mcp auth` — the usual causes are a refresh token unused for a year,
access revoked from your Withings account, or a token file invalidated by a
concurrent `sync`. It reuses your saved Client ID/Secret, so you only reapprove
in the browser. Restart the server afterwards so it drops its in-memory copy of
the old tokens (`docker compose restart withings-mcp`, or restart the MCP client
that spawns the stdio server).

`withings-mcp doctor` reports the paths and credentials actually in use, and what
needs fixing, without making an API call — start there when something looks off.

> **Remote (headless) server**: the callback goes to `localhost:8585` *on the
> machine running the command* — that is why the Docker `auth` service uses
> `network_mode: host`. If the server runs elsewhere, forward the port from your
> workstation before clicking the authorization URL, so that your browser's
> callback reaches the listener on the server:
> ```bash
> ssh -L 8585:localhost:8585 user@server
> ```

---

## Connecting MCP clients

### Local install (stdio)

**Claude Code:**

```bash
claude mcp add -s user withings \
  -e WITHINGS_MCP_CONFIG_DIR=$HOME/.local/share/withings-mcp/config \
  -e WITHINGS_MCP_DB_PATH=$HOME/.local/share/withings-mcp/withings.db \
  -- $HOME/.venvs/withings/bin/withings-mcp
```

**Claude Desktop** — `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "withings": {
      "command": "/home/you/.venvs/withings/bin/withings-mcp",
      "env": {
        "WITHINGS_MCP_CONFIG_DIR": "/home/you/.local/share/withings-mcp/config",
        "WITHINGS_MCP_DB_PATH": "/home/you/.local/share/withings-mcp/withings.db"
      }
    }
  }
}
```

Use absolute paths in both: the client does not run them through your shell, and
`~` is not expanded.

### Docker (HTTP / SSE)

**Claude Code**, on the Docker host itself:

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

**Docker in stdio mode** (the image without the HTTP proxy):

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

---

## CLI reference

```
withings-mcp              Start the MCP server (stdio transport)
withings-mcp auth         Interactive OAuth setup (opens the browser)
withings-mcp sync         Sync data to the local cache (--types, --days)
withings-mcp doctor       Check the setup and report what needs fixing
withings-mcp --version    Print the installed package version
```

```bash
withings-mcp sync                      # all data types, last 30 days
withings-mcp sync --types body,sleep   # a subset
withings-mcp sync --days 90            # deeper history on the first sync
```

Under Docker, `docker compose run --rm auth` and `docker compose run --rm sync`
wrap the first two; any other subcommand runs via
`docker compose run --rm withings-mcp withings-mcp doctor`.

---

## Exposed tools

| Tool | Description | Data source |
|---|---|---|
| `withings_sync` | Syncs the Withings API into the local cache | API → SQLite |
| `withings_get_body` | Body composition (weight, fat %, muscle, bone, BP, SpO2) | Cache (auto-syncs if stale) |
| `withings_get_sleep` | Sleep summaries, or detailed phases with `detail=True` | Cache (summary) / API (detail) |
| `withings_get_activity` | Daily steps, distance, calories, active time | Cache (auto-syncs if stale) |
| `withings_get_workouts` | Workout sessions (type, duration, HR) | Cache (auto-syncs if stale) |
| `withings_get_heart` | ECG recordings and AFib detection | API (always) |
| `withings_get_devices` | Connected devices and battery level | API (always) |
| `withings_trends` | Period averages, trends, comparisons | Cache (auto-syncs if stale) |

Cache-backed tools accept `live=True` to bypass the cache.
`withings_get_sleep(detail=True)` returns minute-by-minute phases, live, up to 7
days per request.

Example prompts: *"Sync my Withings data"*, *"Show my weight for the last 3
months"*, *"Compare my body composition this month vs last month"*, *"What
Withings devices do I have connected?"*

---

## Configuration

**The server itself** (both installs):

| Variable | Default | Purpose |
|---|---|---|
| `WITHINGS_MCP_CONFIG_DIR` | `./config/` | Directory holding the client credentials and tokens |
| `WITHINGS_MCP_DB_PATH` | `./withings.db` | SQLite cache path |

The image sets these to `/config` and `/data/withings.db`.

**The Docker deployment** (`.env`, see `.env.example`):

| Variable | Default | Purpose |
|---|---|---|
| `WITHINGS_MCP_BIND` | `0.0.0.0` | Host address the port is published on |
| `WITHINGS_MCP_PORT` | `8586` | Host port |
| `WITHINGS_MCP_CONFIG_HOST` | `./config` | Host path mounted at `/config` |
| `WITHINGS_MCP_DATA_HOST` | `./data` | Host path mounted at `/data` |
| `WITHINGS_SYNC_DAYS` | `30` | History depth for the one-shot `sync` service |
| `TZ` | `Europe/Paris` | Container timezone |

The two `_HOST` paths default to directories next to the compose file, which is
what a plain `git clone` wants. Set them to absolute paths when a stack manager
owns the deployment directory: Dockhand and Portainer regenerate their stack
directory from the repository on every deploy, and a relative `./config` there
means your tokens and cache live inside that regenerated directory.

---

## Keeping the cache fresh

**Do not schedule a `sync` against a running server.** The query tools already
auto-sync when their data is stale, inside the server's own process, so a
scheduled sync buys nothing — and it actively breaks things:

Withings rotates the refresh token on every use, and upstream caches tokens in
module-level state that it reads once and never re-reads
([`auth.py`](https://github.com/partymola/withings-mcp/blob/main/src/withings_mcp/auth.py)).
A separate `sync` process rotating the token on disk therefore leaves the
long-running server holding a token Withings has already invalidated. Every tool
call then fails with `Token refresh failed. Run: withings-mcp auth`, and under
Docker `restart: unless-stopped` cannot recover it, because the process never
exits.

The two processes also open the same SQLite file, which upstream opens without
WAL and with the default 5-second busy timeout, so overlapping access can surface
as `database is locked`.

If you do want a scheduled sync, restart the server immediately afterwards so it
re-reads the rotated token:

```cron
0 6 * * * cd /path/to/withings-mcp && docker compose run --rm sync && docker compose restart withings-mcp
```

---

## Security

- **Read-only**: no tool modifies anything on Withings' side.
- **Local data**: your health history stays in the local SQLite cache; only
  `withings_get_heart` and `withings_get_devices` always hit the API.
- **Secrets**: `config/` holds the client secret and a year-long refresh token,
  `0600`, gitignored. Back it up like a password file.
- **Container**: runs as uid 10001, unprivileged; base image and both packages
  pinned for reproducible builds.

> ⚠️ **mcp-proxy has no authentication** — no token, no bearer, nothing. Anyone
> who can reach port 8586 can read your weight, sleep, blood pressure and ECG
> history. The default `WITHINGS_MCP_BIND=0.0.0.0` publishes it on every
> interface, so put something in front of it: an authenticating reverse proxy, a
> VPN, or `WITHINGS_MCP_BIND=127.0.0.1` plus an SSH tunnel. A host firewall is
> not that something — Docker inserts its port rules ahead of ufw/firewalld.
>
> A reverse proxy only covers the hostname it serves; the published port stays
> reachable directly on the LAN. To let *only* the proxy reach it, drop the
> `ports:` mapping and attach the container to the proxy's own Docker network
> instead.
