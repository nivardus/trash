# Deploying Trash to DigitalOcean

This directory runs the whole app on a single DigitalOcean droplet behind
[Caddy](https://caddyserver.com), which terminates TLS with an automatic Let's
Encrypt certificate for `trash.place`. Both the web client and the game server
live on that one hostname:

```
browser
  ├─ GET https://trash.place/…   ->  Caddy :443 (TLS)  ->  trash-web :80    (static HTML5 client)
  └─ wss://trash.place/ws        ->  Caddy :443 (TLS)  ->  trash-server :9000 (Godot server, ws)
```

Both images are built by CI and published to GHCR:

- `ghcr.io/nivardus/trash` — the dedicated server
- `ghcr.io/nivardus/trash-web` — the static web client (Caddy serving the export)

## 1. Create the droplet

- Create a basic droplet (the smallest shared-CPU size is plenty for now).
- Point DNS at it: create an **A record** for `trash.place` → the droplet's
  public IPv4 (and an **AAAA** record for its IPv6 if you enabled it).
- Wait for DNS to propagate before starting Caddy, otherwise the Let's Encrypt
  challenge will fail. Check with `dig +short trash.place`.

## 2. Install Docker

SSH into the droplet and install Docker Engine + the compose plugin:

```bash
curl -fsSL https://get.docker.com | sh
```

Open the firewall for web traffic (if you use `ufw`):

```bash
ufw allow 80/tcp
ufw allow 443/tcp
```

You do **not** need to open 9000 or 80-internal — those stay on Docker's
private network.

## 3. Copy this deploy directory to the droplet

From your machine:

```bash
ssh root@trash.place 'mkdir -p /opt/trash'
scp -r deploy/. root@trash.place:/opt/trash
```

Then on the droplet:

```bash
cd /opt/trash
cp .env.example .env    # SERVER_DOMAIN is already set to trash.place
```

## 4. (Only if the GHCR images are private) log in to the registry

If the packages are **public**, skip this. If they're private, authenticate
with a GitHub personal access token that has the `read:packages` scope:

```bash
echo <TOKEN> | docker login ghcr.io -u nivardus --password-stdin
```

## 5. Start it

```bash
docker compose pull
docker compose up -d
```

Caddy fetches a certificate for `trash.place` on first boot. Watch the logs:

```bash
docker compose logs -f
```

You should see the Godot server print `Dedicated server listening on port 9000`
and Caddy report a certificate obtained for `trash.place`.

## 6. Verify

Open `https://trash.place` in a browser — the Godot client loads, and hitting
**Join** connects to `wss://trash.place/ws` automatically (see `PROD_URL` in
`client/network/network_manager.gd`).

## Updating to a new build

CI publishes fresh `:latest` images for both the server and the web client on
every push to `main`. To roll them out:

```bash
cd /opt/trash
docker compose pull
docker compose up -d
```

To pin a specific release instead of `latest`, set `IMAGE_TAG=v0.1.0` in `.env`
(any tag produced by the release workflow) and re-run the two commands above.

### Optional: auto-update

To pull new images automatically without SSHing in, add
[Watchtower](https://containrrr.dev/watchtower/) to `docker-compose.yml`, or add
a deploy step to CI that runs the two commands above over SSH.

## Note: GitHub Pages is no longer used

The `Build` workflow no longer deploys to Pages. If Pages was enabled for this
repo, disable it in **Settings → Pages** (set Source to *None*) so the old site
stops serving, and remove any `trash.place` custom-domain / `CNAME` config that
pointed at Pages — DNS for `trash.place` now points at the droplet instead.
