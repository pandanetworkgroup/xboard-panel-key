# xboard-panel-key

Server-side (panel-side) **cert-fingerprint / cert-pinning** patch bundle for [Xboard](https://github.com/cedar2025/Xboard).

This repo ships the patched PHP files and a single installer script that
deploys them into a running Xboard docker container, plus a rollback path.

> Pair with the node-side companion repo: <https://github.com/pandanetworkgroup/xboard-node-key>

---

## What this does

Xboard nodes that use self-signed TLS certificates (hysteria2 / tuic / anytls /
vless+TLS / trojan+TLS / vmess+TLS) used to emit `insecure: true` /
`allow_insecure: true` to every client, which silences certificate verification
and exposes users to MITM attacks.

This patch makes the panel inject **certificate pinning** instead:

| Client                                | Pinning field                                          |
| ------------------------------------- | ------------------------------------------------------ |
| sing-box                              | `certificate` + `certificate_public_key_sha256`        |
| Clash Meta / Stash                    | `fingerprint` + `skip-cert-verify:false`               |
| Surge / Surfboard                     | `server-cert-fingerprint-sha256`                       |
| v2rayN                                | `v2rayn://` JSON: `CertSha` + `Cert`                   |
| v2rayNG / general / passwall / ssrplus / sagernet | URI `pcs` / `pinSHA256` params             |
| Clash (original)                      | inline `ca-pem` + `skip-cert-verify:false`             |

The 9 patched files cover **all** subscription routes that Xboard ships, plus
the admin `/server/machine` page so that the "install node" one-liner it shows
points at the patched `xboard-node-key` repo (and uses `server_ws_url` host
as `--panel`).

## Machine page install command (`/server/machine`)

This is the 9th file (`Http/Controllers/V2/Admin/Server/MachineController.php`).

The admin machine page used to show:

```
curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh \
  | sudo bash -s -- --mode machine --panel <app_url> --token <token> --machine-id N
```

After this patch it shows:

```
curl -fsSL https://raw.githubusercontent.com/pandanetworkgroup/xboard-node-key/main/install.sh \
  | sudo bash -s -- --mode machine --panel <server_ws_url host> --token <token> --machine-id N
```

`--panel` derivation priority (handled by `resolveNodePanelUrl()`):

1. `server_ws_url` host  — e.g. `wss://node.example.com/ws` -> `https://node.example.com`
   (preferred: that is the host the node will actually open the WebSocket to)
2. `app_url` setting     — e.g. `https://panel.example.com`
3. current request scheme + host (last-resort fallback)

`--token` and `--machine-id` are unchanged from the upstream implementation.

## Files in this repo

| File                              | Purpose                                                        |
| --------------------------------- | ------------------------------------------------------------- |
| `install-panel.sh`                | Deploy + rollback script (bash, pure-ASCII, runs on the panel host) |
| `README.md`                       | This document                                                 |
| `GUIDE.zh-CN.md`                  | Chinese deployment guide with per-file patch details          |
| Release asset `cert-deploy-bundle.tar.gz` | 9 patched PHP files (BOM-stripped, POSIX paths)        |

### The 9 patched PHP files

| File                              | Role                                                                 |
| --------------------------------- | ------------------------------------------------------------------- |
| `Protocols/General.php`           | UA routing, `computeCertSha256()`, v2rayN format, v2rayNG `pcs`/`pinSHA256`, hysteria2/tuic/anytls cert injection, `buildTuic` cert-pinning fix |
| `Protocols/SingBox.php`           | `applyCertFingerprint()` for sing-box subscriptions                  |
| `Protocols/ClashMeta.php`         | `applyCertFingerprint()` + SPKI sha256 for Clash Meta                |
| `Protocols/Stash.php`             | Same as ClashMeta                                                   |
| `Protocols/Clash.php`             | Inline `ca-pem` + `skip-cert-verify:false` for original Clash       |
| `Protocols/Surge.php`             | `server-cert-fingerprint-sha256` for Surge                           |
| `Protocols/Surfboard.php`         | Same as Surge                                                       |
| `Services/ServerService.php`      | Persist `cert_fingerprint` + `cert_pem` to DB (writes only on change) |
| `Http/Controllers/V2/Admin/Server/MachineController.php` | Rewrites `buildInstallCommand()` to emit the `xboard-node-key` one-liner with `--panel` derived from `server_ws_url` host |

---

## Requirements

The script runs **on the panel host** (the machine that runs the Xboard docker
container). It needs:

- `root` (or `sudo`) for docker access
- `docker` CLI on `PATH`
- The Xboard container running (container name is **auto-detected** since v1.1.0)
- Internet access to `raw.githubusercontent.com` / `api.github.com`
  (unless you pass `--bundle` for offline install)

Before deploying, **make sure the node-side patch has already been deployed**
to every node that should report cert info. Otherwise the DB will not have
`cert_fingerprint` / `cert_pem` and the panel will keep emitting
`insecure: true`.

> <https://github.com/pandanetworkgroup/xboard-node-key>

---

## Quick start (recommended)

### One-line deploy

```bash
curl -fsSL https://raw.githubusercontent.com/pandanetworkgroup/xboard-panel-key/main/install-panel.sh \
  | sudo bash -s -
```

This will:

1. Download `cert-deploy-bundle.tar.gz` from the latest GitHub release
2. Back up the current 9 PHP files from the container to `/root/php_pre_cert_deploy/`
   (only if no backup exists yet)
3. Copy the 9 new PHP files into the container at `/www/app/...`
4. Strip any UTF-8 BOM defensively (idempotent)
5. Run `php -l` on all 9 files — auto-rolls back on syntax error
6. Run `php /www/artisan optimize:clear`
7. `docker restart xboard-xboard-1`
8. HTTP self-test against `http://127.0.0.1:7001/` then `http://127.0.0.1/`
9. Print a verify command for you to run 60-90s later

### Detect only (scan environment, no changes)

```bash
sudo bash install-panel.sh --detect
```

This prints a full environment report (container name, app root, compose dir,
PHP file patch status, backup status, DB cert counts) without making any changes.
Useful for pre-flight checks or troubleshooting.

### Interactive deploy (download first)

```bash
curl -fsSL https://raw.githubusercontent.com/pandanetworkgroup/xboard-panel-key/main/install-panel.sh -o install-panel.sh
sudo bash install-panel.sh
sudo bash install-panel.sh --help
```

### Offline deploy (air-gapped host)

Download the bundle on a machine with internet, copy both files to the panel
host, then run:

```bash
sudo bash install-panel.sh --bundle ./cert-deploy-bundle.tar.gz
```

---

## Rollback

There are two rollback behaviors:

### Default rollback (also clears DB cert fields)

Restores the 8 PHP files from `/root/php_pre_cert_deploy/`, **and** nulls
`cert_fingerprint` + `cert_pem` in the `v2_server` table. Clients will go back
to `insecure: true` immediately on next subscription fetch.

```bash
sudo bash install-panel.sh --rollback
```

### Soft rollback (keep DB cert fields)

Restores the 8 original PHP files, but leaves the cert fields in the DB
untouched. Useful if you only need to revert code changes but want the
node-reported cert data to remain available for inspection.

```bash
sudo bash install-panel.sh --rollback --keep-db
```

> If no `/root/php_pre_cert_deploy/` is found, rollback will refuse to proceed.

---

## Auto-detection (v1.1.0+)

Since v1.1.0, the script automatically detects the Xboard environment:

| Item              | Detection strategy                                                                 |
| ----------------- | ---------------------------------------------------------------------------------- |
| Container name    | Scans all running Docker containers, probes each for `app/Protocols` directory     |
| App root          | Probes `/www/app`, `/var/www/html`, `/app`, `/var/www/app` inside the container    |
| Compose directory | Probes common host paths (`/www/wwwroot/xboard`, etc.) + Docker compose labels      |

All auto-detected values can be overridden with `--container`, `--app-root`,
or `--compose-dir`. Use `--detect` to see what the script finds before deploying.

## CLI reference

```
Xboard panel-side cert-fingerprint installer (deploy / rollback / detect) v1.1.0

Args:
  --detect                 scan and print environment only, no changes
  --rollback               rollback to the pre-deploy backup (default also clears DB)
  --keep-db                rollback only, keep cert_fingerprint / cert_pem in DB
  --container NAME         xboard docker container name (auto-detected if omitted)
  --app-root PATH          app root inside container (auto-detected if omitted)
  --compose-dir DIR        docker-compose directory on host (auto-detected if omitted)
  --backup-dir DIR         host backup dir (default: /root/php_pre_cert_deploy)
  --work-dir DIR           host working dir for unpack (default: /root/cert-deploy-work)
  --health-url URL         health-check URL (repeatable; default: http://127.0.0.1/ , http://127.0.0.1:7001/)
  --bundle PATH            use a local tar.gz bundle instead of downloading from GitHub
  --release-tag TAG        github release tag to fetch (default: latest)
  --force-rebackup         re-take a backup even if one already exists
  --skip-selftest          skip the final HTTP self-test
  -h, --help               show this help
```

### Common overrides

Non-default container name (skip auto-detection):

```bash
sudo bash install-panel.sh --container my-xboard-1
```

Non-default app root inside container:

```bash
sudo bash install-panel.sh --app-root /var/www/html
```

Panel exposed on a non-default port (via Baota/Nginx proxy on 80):

```bash
sudo bash install-panel.sh --health-url http://127.0.0.1/
```

---

## How verification works

After deploy, wait 60-90s for nodes to republish cert info via WebSocket, then
inspect the DB:

```bash
# How many servers currently have cert_fingerprint in DB
docker exec xboard-xboard-1 php /www/artisan tinker --execute \
  'use App\Models\Server; echo "with-cert: " . Server::whereNotNull("cert_fingerprint")->count() . "/total: " . Server::count() . "\n";'
```

Then fetch a subscription with each client User-Agent and grep for the pinning
fields. For example:

```bash
# sing-box: should contain certificate_public_key_sha256
curl -fsSL -A 'sing-box/1.8' 'https://your-panel-domain.com/api/v1/client/subscribe?token=YOUR_TOKEN' | grep certificate_public_key_sha256

# Clash Meta: should contain "fingerprint:" and skip-cert-verify:false
curl -fsSL -A 'clash.meta' 'https://your-panel-domain.com/api/v1/client/subscribe?token=YOUR_TOKEN' | grep -E 'fingerprint:|skip-cert-verify'

# Surge: should contain server-cert-fingerprint-sha256
curl -fsSL -A 'Surge/4' 'https://your-panel-domain.com/api/v1/client/subscribe?token=YOUR_TOKEN' | grep server-cert-fingerprint-sha256
```

---

## Operational notes

### UTF-8 BOM

Windows-edited PHP files often carry a UTF-8 BOM (`EF BB BF`). In PHP this
causes `Fatal error: Namespace declaration statement has to be the very first
statement`. The bundle in this repo is already BOM-free, and the installer also
strips BOM defensively inside the container (idempotent — safe to run on a
file that has no BOM).

### OPcache

`php -l` and `artisan optimize:clear` do **not** clear OPcache. The installer
always `docker restart`s the container so the new bytecode actually takes
effect. Do not skip the restart step.

### Recovery if `php -l` fails

The installer runs `php -l` on all 8 files *after* copying them into the
container. If any file fails the syntax check, the installer **automatically
restores the previous files from `$BACKUP_DIR`**, clears the cache, and exits
with a non-zero code. The container is left in its pre-deploy state.

### Backup retention

The first successful deploy writes `/root/php_pre_cert_deploy/`. Subsequent
deploys keep that backup untouched (so you can always roll back to the
**original** state, not to some intermediate state). Pass `--force-rebackup`
to override this — useful only if your "original" was not actually original.

---

## Release asset

The release asset `cert-deploy-bundle.tar.gz` contains exactly these 9 files
with POSIX-style (forward-slash) paths:

```
Protocols/Clash.php
Protocols/ClashMeta.php
Protocols/General.php
Protocols/SingBox.php
Protocols/Stash.php
Protocols/Surfboard.php
Protocols/Surge.php
Services/ServerService.php
Http/Controllers/V2/Admin/Server/MachineController.php
```

You can repack locally from a checked-out source tree with:

```bash
tar -czf cert-deploy-bundle.tar.gz \
    Protocols/Clash.php \
    Protocols/ClashMeta.php \
    Protocols/General.php \
    Protocols/SingBox.php \
    Protocols/Stash.php \
    Protocols/Surfboard.php \
    Protocols/Surge.php \
    Services/ServerService.php \
    Http/Controllers/V2/Admin/Server/MachineController.php
```

---

## Validated deployment

This bundle has been deployed end-to-end on production Xboard panel hosts
(docker container, Baota+Nginx reverse proxy on :80, Caddy on :7001). The
installer ran cleanly through all 9 stages: detect -> backup -> copy -> BOM
strip -> `php -l` -> `artisan optimize:clear` -> `docker restart` -> HTTP
self-test `http://127.0.0.1/` -> HTTP 200.

Post-deploy file sizes inside the container (for your reference when verifying
your own deploy; absolute sizes may shift slightly with patch revisions):

```
Protocols/Clash.php                                                 13783
Protocols/ClashMeta.php                                             35263
Protocols/General.php                                               40344
Protocols/SingBox.php                                               35982
Protocols/Stash.php                                                 26143
Protocols/Surfboard.php                                              9849
Protocols/Surge.php                                                 14226
Services/ServerService.php                                          16506
Http/Controllers/V2/Admin/Server/MachineController.php              8067
```

The original `MachineController.php` is ~6617 bytes; after the patch it is
8067 bytes (the `resolveNodePanelUrl()` method + rewired
`buildInstallCommand()`). If your post-deploy size on that file is still
~6617, the 9th file did not land.

---

## Companion repo (node-side)

The panel only generates correct subscription output if the panel DB has
`cert_fingerprint` + `cert_pem` for each server. Those fields are populated by
the **node-side** patch (modified `xboard-node` binary that reports cert info
via WebSocket).

Deploy the node-side patch on every node host:

> <https://github.com/pandanetworkgroup/xboard-node-key>

```bash
curl -fsSL https://raw.githubusercontent.com/pandanetworkgroup/xboard-node-key/main/install.sh \
  | sudo bash -s -- --mode machine --panel 'https://your-panel-domain.com' \
                       --token 'machine_token_here' --machine-id 1
```

---

## License

Same as the upstream Xboard project. See the Xboard repo for details.
