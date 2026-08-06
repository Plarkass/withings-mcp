# Withings MCP — déploiement Docker

Déploiement Docker d'un serveur MCP Withings, sur le même modèle que
[Taxuspt/garmin_mcp](https://github.com/Taxuspt/garmin_mcp) : image auto-suffisante,
tokens OAuth persistés dans un volume, cache local des données, et exposition HTTP
pour les clients MCP distants (Claude Code, Claude Desktop, Home Assistant, etc.).

## Implémentation retenue

Parmi les quatre implémentations candidates, c'est
[**partymola/withings-mcp**](https://github.com/partymola/withings-mcp) qui est utilisée :

| Implémentation | Langage | Transport | Pourquoi pas ? |
|---|---|---|---|
| **partymola/withings-mcp** ✅ | Python 3.13 | stdio | La plus proche de garmin_mcp : cache SQLite incrémental, refresh automatique des tokens, 8 outils (corps, sommeil, activité, workouts, ECG, tendances), zéro dépendance hors `mcp` |
| [gchallen/withings-mcp](https://github.com/gchallen/withings-mcp) | TypeScript/Bun | stdio | Couverture limitée (poids/composition corporelle), tokens stockés dans `.env` |
| [davidmosiah/withings-mcp](https://github.com/davidmosiah/withings-mcp) | TypeScript/Node | stdio | Pas de support Docker, config sous `~/.withings-mcp` peu adaptée au conteneur |
| [akutishevsky/withings-mcp](https://github.com/akutishevsky/withings-mcp) | TypeScript/Bun | HTTP | Nécessite Supabase + secret de chiffrement : trop lourd pour un usage perso |

Le serveur étant stdio-only, l'image ajoute
[`mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) pour l'exposer en réseau :

- **Streamable HTTP** : `http://<hôte>:8586/mcp`
- **SSE** : `http://<hôte>:8586/sse`
- **Healthcheck** : `http://<hôte>:8586/status`

`withings-mcp` n'étant pas encore publié sur PyPI, le Dockerfile l'installe depuis
GitHub avec un **commit épinglé** (`f250123`) pour un build reproductible.

> Note : `withings-mcp` épingle `mcp==2.0.0` alors que `mcp-proxy` exige `mcp<2`.
> L'image les installe donc dans deux venvs isolés (`/opt/withings`, `/opt/proxy`),
> mcp-proxy lançant withings-mcp en sous-processus — aucune dépendance partagée.

## Prérequis

1. Un compte développeur Withings : https://developer.withings.com/dashboard
2. Créer une application avec :
   - **Callback URL** : `http://localhost:8585`
   - **Scopes** : `user.info,user.metrics,user.activity`
3. Noter le *Client ID* et le *Client Secret*.

## Mise en route

```bash
cd withings-mcp
cp .env.example .env        # optionnel : port, TZ, profondeur de sync

# 1. Construire l'image
docker compose build

# 2. Authentification OAuth (une seule fois, interactif)
docker compose run --rm auth
```

L'étape `auth` demande le Client ID/Secret, affiche l'URL d'autorisation Withings à
ouvrir dans le navigateur, puis capture le callback sur `localhost:8585` et sauvegarde
les tokens dans `./config/` (montés dans le conteneur). Le refresh token est valable
1 an et se renouvelle automatiquement à l'usage.

> **Serveur distant (headless)** : le callback doit atteindre `localhost:8585` de la
> machine où tourne le conteneur. Depuis votre poste, ouvrez un tunnel SSH avant de
> cliquer sur l'URL d'autorisation :
> ```bash
> ssh -L 8585:localhost:8585 utilisateur@serveur
> ```

```bash
# 3. Premier remplissage du cache (30 jours par défaut, cf. WITHINGS_SYNC_DAYS)
docker compose run --rm sync

# 4. Démarrer le serveur MCP
docker compose up -d
docker compose ps    # le healthcheck doit passer "healthy"
```

## Connexion des clients MCP

**Claude Code** (transport HTTP) :

```bash
claude mcp add -s user --transport http withings http://<hôte>:8586/mcp
```

**Claude Desktop / clients SSE** — `claude_desktop_config.json` :

```json
{
  "mcpServers": {
    "withings": {
      "url": "http://<hôte>:8586/sse"
    }
  }
}
```

**Alternative stdio pure** (sans le proxy HTTP, comme garmin_mcp en local) :

```json
{
  "mcpServers": {
    "withings": {
      "command": "docker",
      "args": [
        "run", "-i", "--rm",
        "-v", "/chemin/vers/withings-mcp/config:/config",
        "-v", "/chemin/vers/withings-mcp/data:/data",
        "withings-mcp:latest",
        "withings-mcp"
      ]
    }
  }
}
```

## Synchronisation planifiée

Les outils de lecture resynchronisent d'eux-mêmes quand le cache est périmé, mais une
sync régulière garde les réponses instantanées. Exemple cron sur l'hôte Docker :

```cron
0 6 * * * cd /chemin/vers/deploy/withings-mcp && docker compose run --rm sync >> /var/log/withings-sync.log 2>&1
```

(Équivalent possible via un *schedule* Dockhand ou une automatisation Home Assistant.)

## Outils exposés

| Outil | Description | Source |
|---|---|---|
| `withings_sync` | Synchronise l'API Withings vers le cache local | API → SQLite |
| `withings_get_body` | Composition corporelle (poids, masse grasse, muscle, os, tension, SpO2) | Cache |
| `withings_get_sleep` | Résumés de sommeil, ou phases détaillées avec `detail=True` | Cache / API |
| `withings_get_activity` | Pas, distance, calories, temps actif par jour | Cache |
| `withings_get_workouts` | Séances d'entraînement (type, durée, FC) | Cache |
| `withings_get_heart` | Enregistrements ECG et détection AFib | API (toujours) |
| `withings_get_devices` | Appareils connectés et niveau de batterie | API (toujours) |
| `withings_trends` | Moyennes par période, tendances, comparaisons | Cache |

## Arborescence et données

```
withings-mcp/
├── Dockerfile            # image : withings-mcp (commit épinglé) + mcp-proxy
├── docker-compose.yml    # services : withings-mcp (serveur), auth, sync (one-shot)
├── .env.example
├── config/               # withings_client.json + withings_tokens.json (gitignoré)
└── data/                 # withings.db, cache SQLite (gitignoré)
```

Les secrets OAuth et la base de données de santé restent sur l'hôte, exclus de git
par le `.gitignore`. Sauvegardez `config/` si vous voulez éviter de refaire l'OAuth
après une réinstallation.

> ⚠️ Le port 8586 n'a **aucune authentification** : quiconque y accède peut lire vos
> données de santé. Ne l'exposez que sur un réseau de confiance (LAN, VPN, réseau
> Docker interne) — jamais directement sur Internet.
