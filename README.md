# Caddy Proxy for Raspberry Pi Services

This repository contains a containerized reverse proxy setup using **Caddy** to route multiple web applications (running in Docker or host mode) on a Raspberry Pi using subpath-based routing under a single dynamic DNS (DDNS) domain.

![Portal Preview](assets/portal_preview.png)

Features:
* **Automatic HTTPS**: Requests and automatically renews SSL/TLS certificates via Let's Encrypt / ZeroSSL.
* **Basic Authentication**: Password protection globally enforced across all proxied services.
* **Simplified Access**: Access all your services under a single domain (e.g., `https://your-domain.com/helendatacollector/`, `https://your-domain.com/eleniadatacollector/`, `https://your-domain.com/ruuvigateway/`, `https://your-domain.com/fingridflow/`).
* **Live config reload**: Caddy runs with `--watch`, so Caddyfile changes take effect within seconds — no restart, no dropped connections.
* **Self-updating portal**: The landing page renders from `services.json`, and one command (`./add-service.sh`) writes both the route and the card.

---

## Architecture

* **Caddy** runs in a Docker container connected to a shared bridge network `web-proxy` and exposes ports `80` (HTTP validation) and `443` (HTTPS).
* **Helen Flow Data Collector** runs in bridge mode on the same `web-proxy` network and is accessed via Caddy routing (`helen-collector:3000`).
* **EleniaFlow Data Collector** runs in bridge mode on the same `web-proxy` network and is accessed via Caddy routing (`elenia-collector:3000`).
* **RuuviGateway** runs in `host` mode (for BLE/Bluetooth functionality) and is accessed by Caddy routing to the host gateway (`host.docker.internal:8080`).
* **FingridFlow Open Data Collector** runs in bridge mode on the same `web-proxy` network and is accessed via Caddy routing (`fingrid-collector:3000`).

Because Caddy reaches bridge containers **by container name on the `web-proxy`
network**, each app's internal port can stay `3000` no matter how many of them
you run — nothing has to be unique except the container name and the URL path.
Published host ports are only needed if you also want to reach an app directly
on the LAN, and those *do* have to be unique.

### Files

| File | Purpose | Overwritten by the installer? |
| --- | --- | --- |
| `docker-compose.yml` | Caddy container definition | yes |
| `Caddyfile` | Your live routing config (domain, auth hash, routes) | no |
| `Caddyfile.example` | Template for the above | yes |
| `index.html` | Portal page — renders cards from `services.json` | yes |
| `services.json` | Your portal card list | no |
| `add-service.sh` | Adds a route + portal card in one command | yes |

---

## Installation

Run this single command on your Raspberry Pi to download the installer, set up the directory, and configure the shared Docker network:

```bash
curl -fsSL https://raw.githubusercontent.com/Saavuori/caddy-proxy/main/install.sh | bash
```

This will install Caddy proxy files into a `./caddy-proxy` directory and create the `web-proxy` external Docker network automatically. Re-running it updates `docker-compose.yml`, `index.html`, and `add-service.sh` while leaving your `Caddyfile` and `services.json` untouched.

---

## Configuration

To finish deployment, configure the proxy settings:

### 1. Configure the Caddyfile
If you installed via the curl script, `Caddyfile` is already created from the template. Otherwise, if you cloned this repository, copy the example template:

```bash
cp Caddyfile.example Caddyfile
```

Open `Caddyfile` and configure your settings:

1. **Email Address**: Replace `your-email@example.com` with your email to receive Let's Encrypt certificate notifications.
2. **Domain name**: Replace `your-ddns-domain.tplinkdns.com` with your actual dynamic DNS domain.
3. **Basic Authentication Hash**:
   Generate a secure bcrypt password hash for Caddy using the following command (replace `YOUR_PASSWORD` with a secure password):
   ```bash
   docker run --rm caddy caddy hash-password --plaintext "YOUR_PASSWORD"
   ```
   Copy the generated hash and replace `YOUR_GENERATED_BCRYPT_HASH_HERE` under the `basic_auth` block in `Caddyfile`.

---

## Adding a New Project

Once the proxy is up, adding a project takes one command — no file editing and no restart:

```bash
./add-service.sh --path solarflow --upstream solar-collector:3000 --name "SolarFlow" --category "PV Monitor" --icon "☀️" --description "Collects inverter output and exports it to InfluxDB."
```

That single command:

1. Appends the `redir` + `handle_path` route to your `Caddyfile` (inside the `# >>> caddy-proxy:routes` markers).
2. Validates the result with `caddy validate`, reverting everything if the config is broken.
3. Adds the portal card to `services.json`, deriving the whole card palette from one accent colour.

Caddy's `--watch` picks the new Caddyfile up within a couple of seconds and reloads gracefully, and the portal page re-reads `services.json` every 60 seconds — so an already-open browser tab grows the new card on its own.

Useful flags:

| Flag | Meaning |
| --- | --- |
| `--path` | URL segment, e.g. `solarflow` → `https://your-domain/solarflow/` |
| `--upstream` | `container-name:3000` for bridge containers, `host.docker.internal:8080` for host mode |
| `--name` | Card title |
| `--description`, `--category`, `--badge`, `--icon`, `--accent` | Card cosmetics (sensible defaults if omitted) |
| `--no-portal` | Add the route only, skip the portal card |
| `--dry-run` | Show what would change and exit |

Re-running with an existing `--path` is refused so you don't silently duplicate a route. To remove a service, delete its `redir`/`handle_path` block from the `Caddyfile` and its entry from `services.json` — both changes are picked up automatically.

Editing the files by hand still works exactly as before; the script is just a shortcut. The portal hides any card whose path returns 404, so a `services.json` entry without a matching route stays invisible instead of showing a dead link.

---

## Connecting Your Services

### Bridge Containers (e.g. Helen Flow, EleniaFlow, FingridFlow)
For containers running in bridge mode on the same machine, modify their `docker-compose.yml` to connect to Caddy's network and declare it as external.

Example `docker-compose.yml` block:
```yaml
services:
  elenia-collector:
    image: ghcr.io/saavuori/elenia-data-collector:latest
    container_name: elenia-collector   # this is what Caddy proxies to
    restart: unless-stopped
    # ports:                           # Optional — omit to restrict access to proxy-only.
    #   - "3001:3000"                  # If you do publish, pick a free host port:
    #                                  # 3000 and 8080 are often already taken.
    networks:
      - web-proxy
    # ...

networks:
  web-proxy:
    external: true
```

Dropping the `ports:` block entirely is the tidiest option once an app is
behind the proxy — it keeps the service off the LAN and sidesteps host port
collisions with anything else on the Pi (Zigbee2MQTT, RuuviGateway, and so on).

### Host Mode Containers (e.g. RuuviGateway)
For containers running in host network mode (`network_mode: "host"`), they bind directly to a port on the host (e.g., `:8080`). Caddy accesses them via the `host-gateway` bridge defined in `docker-compose.yml` (`host.docker.internal:8080`). No network changes are required for host mode containers.

---

## Deployment

1. Start the proxy stack:
   ```bash
   docker compose up -d
   ```
2. Caddy will automatically request SSL/TLS certificates and serve the web UI at `https://your-domain.com`.
3. Check status and logs (config reloads show up here as `reloading config` entries):
   ```bash
   docker compose logs -f
   ```

A restart is only needed when `docker-compose.yml` itself changes. Route changes, portal cards, and new projects all apply live.
