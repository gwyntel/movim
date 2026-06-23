# Streamlined XMPP + Movim VPS Deployment

This deployment keeps HTTPS and XMPP separate and standards-based:

- One VPS: `45.43.92.85`, also reachable on Tailscale as `100.73.30.13`.
- Docker Compose orchestrates all services on one bridge network.
- Caddy terminates HTTP/TLS on ports `80` and `443` only.
- XMPP is exposed on dedicated TCP ports and is not multiplexed with HTTPS:
  - hemlock / `xmpp.gwyn.tel`: c2s `5222`, s2s `5269`
  - grimmverse / `grimmverse.stupidhimbo.com`: c2s `5223`, s2s `5270`
- Each instance has its own Movim container, PostgreSQL container, and official ejabberd container.
- The Movim image is built from the repository `Containerfile`, which bundles nginx, PHP-FPM, and the Movim daemon through s6-overlay.

## Files

- `docker-compose.yml`: full two-instance deployment.
- `.env`: local secrets and domain overrides. Create this file on the VPS; do not commit it.

## DNS records

Create or update these records at your DNS provider.

### Web and XMPP host records

```text
xmpp.gwyn.tel.                    A     45.43.92.85
grimmverse.stupidhimbo.com.       A     45.43.92.85
```

If you use IPv6 on the VPS, add matching `AAAA` records and publish the IPv6 ports in the firewall too.

### XMPP SRV records

For hemlock:

```text
_xmpp-client._tcp.xmpp.gwyn.tel.       SRV  10 10 5222 xmpp.gwyn.tel.
_xmpps-client._tcp.xmpp.gwyn.tel.      SRV  10 10 5222 xmpp.gwyn.tel.
_xmpp-server._tcp.xmpp.gwyn.tel.       SRV  10 10 5269 xmpp.gwyn.tel.
```

For grimmverse, because it intentionally uses non-default public XMPP ports:

```text
_xmpp-client._tcp.grimmverse.stupidhimbo.com.   SRV  10 10 5223 grimmverse.stupidhimbo.com.
_xmpps-client._tcp.grimmverse.stupidhimbo.com.  SRV  10 10 5223 grimmverse.stupidhimbo.com.
_xmpp-server._tcp.grimmverse.stupidhimbo.com.   SRV  10 10 5270 grimmverse.stupidhimbo.com.
```

Notes:

- Port `5222` is normally STARTTLS c2s. The `_xmpps-client` SRV label is commonly used for DirectTLS clients; only keep that record if your ejabberd listener is configured for DirectTLS on that port.
- Public s2s federation normally expects TCP `5269`; SRV records allow a non-default s2s port like `5270`, but some remote servers or diagnostics may assume `5269`.
- If users should log in as `user@gwyn.tel` rather than `user@xmpp.gwyn.tel`, configure ejabberd virtual hosts and matching SRV records for `gwyn.tel`. The compose defaults use the hostnames provided in the prompt.

## Firewall

Allow only the required public ports on the VPS:

```sh
sudo nft add rule inet filter input tcp dport {80,443,5222,5223,5269,5270} accept
sudo nft add rule inet filter input udp dport 443 accept
```

Adjust those commands to match your existing nftables table/chain names and policy. UDP `443` is optional but enables HTTP/3 in Caddy.

For Tailscale-only administration, keep SSH bound to or firewalled for `tailscale0` as desired.

## Create `.env`

From the repository root on the VPS, create `/home/hermes/projects/movim/.env`:

```sh
cat > .env <<'EOF'
CADDY_EMAIL=admin@example.com

HEMLOCK_WEB_DOMAIN=xmpp.gwyn.tel
HEMLOCK_XMPP_DOMAIN=xmpp.gwyn.tel
HEMLOCK_APP_URL=https://xmpp.gwyn.tel
HEMLOCK_POSTGRES_USER=movim
HEMLOCK_POSTGRES_DB=movim
HEMLOCK_POSTGRES_PASSWORD=replace-with-generated-secret
HEMLOCK_EJABBERD_ADMIN_JID=admin@xmpp.gwyn.tel
HEMLOCK_EJABBERD_ADMIN_PASSWORD=replace-with-generated-secret
HEMLOCK_ERLANG_COOKIE=replace-with-generated-secret
HEMLOCK_DAEMON_DEBUG=false
HEMLOCK_DAEMON_VERBOSE=false

GRIMMVERSE_WEB_DOMAIN=grimmverse.stupidhimbo.com
GRIMMVERSE_XMPP_DOMAIN=grimmverse.stupidhimbo.com
GRIMMVERSE_APP_URL=https://grimmverse.stupidhimbo.com
GRIMMVERSE_POSTGRES_USER=movim
GRIMMVERSE_POSTGRES_DB=movim
GRIMMVERSE_POSTGRES_PASSWORD=replace-with-generated-secret
GRIMMVERSE_EJABBERD_ADMIN_JID=admin@grimmverse.stupidhimbo.com
GRIMMVERSE_EJABBERD_ADMIN_PASSWORD=replace-with-generated-secret
GRIMMVERSE_ERLANG_COOKIE=replace-with-generated-secret
GRIMMVERSE_DAEMON_DEBUG=false
GRIMMVERSE_DAEMON_VERBOSE=false
EOF
chmod 600 .env
```

Generate strong values:

```sh
openssl rand -base64 32   # PostgreSQL passwords
openssl rand -base64 32   # ejabberd admin passwords
openssl rand -hex 32      # Erlang cookies
```

The compose file requires these secrets and will fail fast if they are missing.

## Build and start

Use Docker Compose from the repository root:

```sh
docker compose build
docker compose up -d
docker compose ps
```

Or with Podman Compose if that is your standard runtime:

```sh
podman-compose build
podman-compose up -d
podman-compose ps
```

## Caddy configuration

The Caddyfile is embedded in `docker-compose.yml` as a Compose config. It creates two HTTPS virtual hosts:

- `xmpp.gwyn.tel` -> `hemlock-movim:8080`
- `grimmverse.stupidhimbo.com` -> `grimmverse-movim:8080`

Caddy forwards ordinary HTTP/WebSocket traffic to the Movim container. There is no Caddy L4 multiplexing and no reverse proxy hop to ejabberd.

The reverse proxy intentionally preserves normal forwarded headers:

- `Host`
- `X-Real-IP`
- `X-Forwarded-For`
- `X-Forwarded-Proto`
- `X-Forwarded-Host`

Caddy does not strip the browser `Origin` header by default; no `header_up -Origin` rule is used.

If you want a standalone Caddyfile instead of the embedded config, bind mount it over `/etc/caddy/Caddyfile` and remove the `configs:` block from the Caddy service.

## ejabberd configuration

The compose file uses the official ProcessOne image:

```yaml
image: ghcr.io/processone/ejabberd:26.04
```

Persistent volumes are mounted at:

- `/opt/ejabberd/conf`
- `/opt/ejabberd/database`
- `/opt/ejabberd/logs`
- `/opt/ejabberd/upload`

The official image runs as UID/GID `9000:9000`. Named Docker volumes do not need host-side ownership preparation. If you replace them with bind mounts, make the host directories writable by UID/GID `9000:9000`.

The compose file uses the official first-boot admin mechanism:

- `EJABBERD_MACRO_HOST`: XMPP domain used by the generated default config.
- `EJABBERD_MACRO_ADMIN`: admin JID granted ACL privileges.
- `REGISTER_ADMIN_PASSWORD`: password for the first-boot admin account.

On first boot, the official image initializes configuration in the conf volume. Review the generated `ejabberd.yml` for each instance and make sure it matches your policy for:

- `hosts`
- c2s listener TLS mode and certificates
- s2s listener
- registration policy
- admin ACLs
- HTTP upload, BOSH, WebSocket, STUN/TURN discovery, and other modules required by your Movim setup

Example commands to inspect the generated config volumes:

```sh
docker compose exec hemlock-ejabberd bin/ejabberdctl status
docker compose exec grimmverse-ejabberd bin/ejabberdctl status
docker compose exec hemlock-ejabberd sh -lc 'ls -la /opt/ejabberd/conf && sed -n "1,220p" /opt/ejabberd/conf/ejabberd.yml'
```

### TLS certificates for XMPP

Caddy terminates web TLS only. ejabberd still needs certificates for XMPP STARTTLS/DirectTLS. Recommended options:

1. Let ejabberd obtain ACME certificates if you enable its ACME support and expose the needed challenge path/port.
2. Export/copy certificates from an ACME client on the host into the ejabberd conf/certs volume.
3. Use DNS-01 ACME and mount certificates into each ejabberd container.

Do not route XMPP through Caddy HTTPS. Keep XMPP on its dedicated ports.

## Movim configuration

Each Movim container is built from `Containerfile` and receives database and daemon settings through environment variables:

- `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE`
- `DAEMON_URL`, `DAEMON_INTERFACE`, `DAEMON_PORT`
- `APP_URL` / `BASE_URI`

The compose file sets `SSL_MODE=off` because TLS is terminated by Caddy before traffic reaches the Movim container.

Movim data/cache/log volumes are persistent:

- `/var/www/html/cache`
- `/var/www/html/log`
- `/var/www/html/public/cache`
- `/var/www/html/public/images`

The s6 service in the image runs Movim migrations before starting the daemon.

## Validation

Check containers:

```sh
docker compose ps
docker compose logs -f caddy
docker compose logs -f hemlock-movim
docker compose logs -f grimmverse-movim
docker compose logs -f hemlock-ejabberd
docker compose logs -f grimmverse-ejabberd
```

Check web routing and HTTP/2 or HTTP/3 behavior:

```sh
curl -I https://xmpp.gwyn.tel/
curl -I https://grimmverse.stupidhimbo.com/
```

Check public XMPP sockets:

```sh
nc -vz xmpp.gwyn.tel 5222
nc -vz xmpp.gwyn.tel 5269
nc -vz grimmverse.stupidhimbo.com 5223
nc -vz grimmverse.stupidhimbo.com 5270
```

Check SRV records:

```sh
dig +short SRV _xmpp-client._tcp.xmpp.gwyn.tel
dig +short SRV _xmpp-server._tcp.xmpp.gwyn.tel
dig +short SRV _xmpp-client._tcp.grimmverse.stupidhimbo.com
dig +short SRV _xmpp-server._tcp.grimmverse.stupidhimbo.com
```

## Operational notes

- Stop the old VPS Caddy L4 and CT DNAT rules before binding these ports on the VPS.
- Only one process can bind public `80`, `443`, `5222`, `5223`, `5269`, or `5270` at a time.
- Keep `.env` and any ejabberd certificate material out of Git.
- Back up Docker named volumes regularly, especially PostgreSQL and ejabberd data volumes.
- If service-worker or cache bugs persist, clear browser storage for each domain after migration so stale assets from the old topology are removed.