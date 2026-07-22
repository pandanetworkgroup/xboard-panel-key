#!/usr/bin/env bash
#
# Xboard panel-side cert-fingerprint deployment / rollback script
# Repo:  https://github.com/pandanetworkgroup/xboard-panel-key
#
# This script must be run ON THE PANEL HOST (the machine that runs the xboard
# docker container). It needs:
#   * root (or sudo) for docker access
#   * docker CLI available on PATH
#   * the xboard container running (auto-detected or override with --container)
#   * internet access to raw.githubusercontent.com / api.github.com (unless --bundle is given)
#
# The script auto-detects:
#   * the Xboard docker container name (scans all running containers)
#   * the app root directory inside the container (/www/app, /var/www/html, etc.)
#   * the docker-compose project directory on the host
#
# Use --detect to only scan and print the environment without deploying.
#
# ----------------------------------------------------------------------------
# Common usage
# ----------------------------------------------------------------------------
#
# 1) One-line deploy (recommended):
#
#    curl -fsSL https://raw.githubusercontent.com/pandanetworkgroup/xboard-panel-key/main/install-panel.sh \
#      | sudo bash -s --
#
# 2) Interactive deploy (download first):
#
#    curl -fsSL https://raw.githubusercontent.com/pandanetworkgroup/xboard-panel-key/main/install-panel.sh -o install-panel.sh
#    sudo bash install-panel.sh
#
# 3) Detect only (print environment, no changes):
#
#    sudo bash install-panel.sh --detect
#
# 4) Rollback to the pre-deploy backup, AND clear DB cert fields (default):
#
#    sudo bash install-panel.sh --rollback
#
# 5) Rollback but keep DB cert fields intact (nodes will keep using cert pinning):
#
#    sudo bash install-panel.sh --rollback --keep-db
#
# 6) Offline deploy using a local tar.gz bundle:
#
#    sudo bash install-panel.sh --bundle ./cert-deploy-bundle.tar.gz
#
# ----------------------------------------------------------------------------
set -euo pipefail

# ==================== Constants ====================
REPO="pandanetworkgroup/xboard-panel-key"
SCRIPT_VERSION="1.1.0"

# Candidate container names to try (in order) when auto-detecting
DEF_CONTAINER_CANDIDATES=( "xboard-xboard-1" "xboard-1" "xboard" )

# Candidate app roots to probe inside containers
DEF_APP_ROOT_CANDIDATES=( "/www/app" "/var/www/html" "/app" "/var/www/app" )

# Candidate compose directories on the host
DEF_COMPOSE_DIR_CANDIDATES=( "/www/wwwroot/xboard" "/www/wwwroot/178278.xyz" "/root/xboard" "/opt/xboard" "/www/wwwroot" )

# Health-check URL candidates tried in order (first wins).
# Order rationale: most Baota/Nginx-proxied setups return 200 on :80 while
# the bare Caddy in :7001 may return 403 on '/'. Try :80 first.
DEF_HEALTH_URLS=( "http://127.0.0.1/" "http://127.0.0.1:7001/" )

# Where the pre-deploy backup is kept on the host
DEF_BACKUP_DIR="/root/php_pre_cert_deploy"

# Where the bundle is unpacked on the host
DEF_WORK_DIR="/root/cert-deploy-work"

# PHP files (relative to work dir / inside the bundle / inside the container app path)
PHP_FILES=(
    "Protocols/Clash.php"
    "Protocols/ClashMeta.php"
    "Protocols/General.php"
    "Protocols/SingBox.php"
    "Protocols/Stash.php"
    "Protocols/Surfboard.php"
    "Protocols/Surge.php"
    "Services/ServerService.php"
    "Http/Controllers/V2/Admin/Server/MachineController.php"
)
# APP_ROOT is auto-detected at runtime; fallback to /www/app
APP_ROOT="/www/app"
COMPOSE_DIR=""  # auto-detected

# ==================== Logging ====================
if [ -t 2 ]; then
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_OFF=$'\033[0m'
else
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_OFF=''
fi
log()  { printf '%s[install]%s %s\n' "$C_GREEN"  "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n'    "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s[error]%s %s\n'   "$C_RED"    "$C_OFF" "$*" >&2; exit 1; }
hr()   { printf '%s---%s\n' "$C_YELLOW" "$C_OFF"; }

# ==================== Args ====================
MODE="deploy"          # deploy | rollback | detect
CONTAINER=""            # auto-detected if empty
BACKUP_DIR="$DEF_BACKUP_DIR"
WORK_DIR="$DEF_WORK_DIR"
HEALTH_URLS=( "${DEF_HEALTH_URLS[@]}" )
BUNDLE_PATH=""         # local tar.gz path (--bundle)
RELEASE_TAG="latest"   # github release tag
KEEP_DB=0
FORCE_REBACKUP=0
SKIP_SELFTEST=0

usage() {
    cat <<'USAGE_EOF'
Xboard panel-side cert-fingerprint installer (deploy / rollback / detect) v1.1.0

One-line deploy (recommended):
  curl -fsSL https://raw.githubusercontent.com/pandanetworkgroup/xboard-panel-key/main/install-panel.sh \
    | sudo bash -s -

Detect only (scan environment, no changes):
  sudo bash install-panel.sh --detect

Interactive deploy:
  sudo bash install-panel.sh

Rollback (default also clears DB cert fields):
  sudo bash install-panel.sh --rollback [--keep-db]

Offline deploy with a local bundle:
  sudo bash install-panel.sh --bundle ./cert-deploy-bundle.tar.gz

Deploys 9 PHP files:
  8 cert-pinning patch files (Protocols/* + Services/ServerService.php)
  1 admin MachineController.php -> renders the xboard-node-key one-liner on the
  /server/machine page, using server_ws_url host as --panel

Auto-detection:
  If --container is not given, the script scans all running Docker containers
  and picks the first one whose filesystem contains an app/Protocols directory.
  The app root (/www/app, /var/www/html, etc.) is auto-detected by probing
  candidate paths inside the container.
  The docker-compose directory on the host is detected by searching common
  paths for docker-compose.yml.

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
USAGE_EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --detect)          MODE="detect"; shift ;;
        --rollback)        MODE="rollback"; shift ;;
        --keep-db)         KEEP_DB=1; shift ;;
        --container)       CONTAINER="$2"; shift 2 ;;
        --app-root)        APP_ROOT="$2"; shift 2 ;;
        --compose-dir)     COMPOSE_DIR="$2"; shift 2 ;;
        --backup-dir)      BACKUP_DIR="$2"; shift 2 ;;
        --work-dir)        WORK_DIR="$2"; shift 2 ;;
        --health-url)      HEALTH_URLS+=( "$2" ); shift 2 ;;
        --bundle)          BUNDLE_PATH="$2"; shift 2 ;;
        --release-tag)     RELEASE_TAG="$2"; shift 2 ;;
        --force-rebackup)  FORCE_REBACKUP=1; shift ;;
        --skip-selftest)   SKIP_SELFTEST=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; break ;;
        *)                 die "unknown arg: $1 (use --help for usage)" ;;
    esac
done

# ==================== Root check ====================
[ "$(id -u)" -eq 0 ] || die "please run as root (or with sudo)"

# ==================== Tools check ====================
command -v docker >/dev/null 2>&1 || die "docker CLI not found. install docker first."
command -v curl   >/dev/null 2>&1 || die "curl not found. install curl first."
command -v tar    >/dev/null 2>&1 || die "tar not found. install tar first."

# ==================== Auto-detection ====================

# Detect the Xboard docker container by scanning running containers.
# Strategy:
#   1. If --container was given, use it directly.
#   2. Try well-known names (xboard-xboard-1, xboard-1, xboard).
#   3. Scan ALL running containers and probe each for app/Protocols.
detect_container() {
    # If user specified --container, verify it
    if [ -n "$CONTAINER" ]; then
        if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q '^true$'; then
            die "container '$CONTAINER' (from --container) is not running."
        fi
        log "container: $CONTAINER (from --container, state: running)"
        return 0
    fi

    log "auto-detecting Xboard container..."

    # Step 1: try well-known names
    for name in "${DEF_CONTAINER_CANDIDATES[@]}"; do
        if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q '^true$'; then
            log "  candidate: $name (running)"
            CONTAINER="$name"
            # Verify it looks like Xboard by probing app roots
            if detect_app_root "$CONTAINER" 2>/dev/null; then
                log "  -> confirmed: $CONTAINER (app root: $APP_ROOT)"
                return 0
            fi
            log "  -> $name running but no app/Protocols found, keep scanning"
            CONTAINER=""
        fi
    done

    # Step 2: scan all running containers
    local all_containers
    all_containers=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
    [ -n "$all_containers" ] || die "no running docker containers found."

    local found=0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        log "  scanning: $name"
        if detect_app_root "$name" 2>/dev/null; then
            CONTAINER="$name"
            found=1
            log "  -> confirmed: $CONTAINER (app root: $APP_ROOT)"
            break
        fi
    done <<< "$all_containers"

    [ "$found" -eq 1 ] || die "could not auto-detect Xboard container. pass --container NAME to override."
}

# Detect the app root directory inside a container by probing candidate paths.
# Sets APP_ROOT on success. Returns 0 if found, 1 otherwise.
detect_app_root() {
    local c="$1"
    for root in "${DEF_APP_ROOT_CANDIDATES[@]}"; do
        if docker exec "$c" test -d "$root/Protocols" 2>/dev/null; then
            # Extra sanity: check for artisan (Xboard uses Laravel)
            if docker exec "$c" test -f "$(dirname "$root")/artisan" 2>/dev/null \
               || docker exec "$c" test -f "$root/../artisan" 2>/dev/null \
               || docker exec "$c" test -f "$root/artisan" 2>/dev/null; then
                APP_ROOT="$root"
                return 0
            fi
            # Even without artisan, Protocols dir is a strong enough signal
            APP_ROOT="$root"
            return 0
        fi
    done
    return 1
}

# Detect the docker-compose directory on the host.
# Sets COMPOSE_DIR on success.
detect_compose_dir() {
    [ -n "$COMPOSE_DIR" ] && return 0

    for dir in "${DEF_COMPOSE_DIR_CANDIDATES[@]}"; do
        if [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/docker-compose.yaml" ]; then
            COMPOSE_DIR="$dir"
            return 0
        fi
    done

    # Fallback: inspect the container's compose label
    if [ -n "$CONTAINER" ]; then
        local compose_project
        compose_project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CONTAINER" 2>/dev/null || true)
        if [ -n "$compose_project" ] && [ -d "$compose_project" ]; then
            COMPOSE_DIR="$compose_project"
            return 0
        fi
    fi

    return 1
}

# Print a full environment report (used by --detect and at deploy start).
print_environment() {
    echo
    hr
    echo " Xboard Environment Report"
    hr
    echo "  Container:     $CONTAINER"
    echo "  App Root:      $APP_ROOT"
    echo "  Compose Dir:   ${COMPOSE_DIR:-<not found>}"
    echo "  Backup Dir:    $BACKUP_DIR"
    echo "  Work Dir:      $WORK_DIR"
    echo "  Health URLs:   ${HEALTH_URLS[*]}"
    echo
    echo "  Container status:"
    docker inspect -f '    State: {{.State.Status}}
    Image:  {{.Config.Image}}
    Ports:  {{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}} {{end}}{{end}}' "$CONTAINER" 2>/dev/null || true
    echo
    echo "  PHP files in container:"
    for rel in "${PHP_FILES[@]}"; do
        local name
        name=$(basename "$rel")
        local cpath="$APP_ROOT/$rel"
        if docker exec "$CONTAINER" test -f "$cpath" 2>/dev/null; then
            local size
            size=$(docker exec "$CONTAINER" stat -c '%s' "$cpath" 2>/dev/null || echo "?")
            local patched="no"
            if docker exec "$CONTAINER" grep -qE 'cert_fingerprint|computeCertSha256|applyCertFingerprint|buildV2rayNFormat' "$cpath" 2>/dev/null; then
                patched="YES"
            fi
            printf '    %-50s %6s bytes  patched=%s\n' "$rel" "$size" "$patched"
        else
            printf '    %-50s MISSING\n' "$rel"
        fi
    done
    echo
    echo "  Backup files:"
    if [ -d "$BACKUP_DIR" ]; then
        for rel in "${PHP_FILES[@]}"; do
            local name
            name=$(basename "$rel")
            if [ -f "$BACKUP_DIR/$name" ]; then
                printf '    %-50s OK\n' "$name"
            else
                printf '    %-50s -\n' "$name"
            fi
        done
    else
        echo "    (no backup directory)"
    fi
    echo
    echo "  DB cert status:"
    docker exec "$CONTAINER" php /www/artisan tinker --execute='
        use App\Models\Server;
        $t = Server::count();
        $c = Server::whereNotNull("cert_fingerprint")->count();
        echo "    total=$t with_cert=$c without=" . ($t - $c) . "\n";
    ' 2>/dev/null || echo "    (tinker failed)"
    echo
    hr
}

# ==================== Run detection ====================
detect_container
detect_compose_dir || true

# Verify the container looks like Xboard
if ! docker exec "$CONTAINER" test -d "$APP_ROOT/Protocols" 2>/dev/null; then
    die "container '$CONTAINER' does not have $APP_ROOT/Protocols/. is this an Xboard container?"
fi
log "container: $CONTAINER  (app root: $APP_ROOT, state: running)"

# --detect mode: print environment and exit
if [ "$MODE" = "detect" ]; then
    print_environment
    log "detect mode: no changes made. use without --detect to deploy."
    exit 0
fi

# ==================== Helpers ====================

# Locate a backup file by basename. Supports both layouts:
#   flat:   $BACKUP_DIR/<name>            (created by this script)
#   nested: $BACKUP_DIR/Protocols/<name>  (created by manual docker cp of whole dirs)
#           $BACKUP_DIR/Services/<name>
find_backup_file() {
    local name="$1"  # e.g. Clash.php or ServerService.php
    if [ -f "$BACKUP_DIR/$name" ]; then
        echo "$BACKUP_DIR/$name"
        return 0
    fi
    if [ "$name" = "ServerService.php" ] && [ -f "$BACKUP_DIR/Services/$name" ]; then
        echo "$BACKUP_DIR/Services/$name"
        return 0
    fi
    if [ -f "$BACKUP_DIR/Protocols/$name" ]; then
        echo "$BACKUP_DIR/Protocols/$name"
        return 0
    fi
    return 1
}

# Return the number of backup files actually present (flat or nested).
count_backup_files() {
    local n=0
    for rel in "${PHP_FILES[@]}"; do
        local name
        name=$(basename "$rel")
        if find_backup_file "$name" >/dev/null 2>&1; then
            n=$((n+1))
        fi
    done
    echo "$n"
}

# Strip UTF-8 BOM (EF BB BF) from a file inside the container, if present.
strip_bom_in_container() {
    local cpath="$1"
    # sed 1s/^...//  on the BOM bytes. We use a literal escape so busybox sed also works.
    docker exec "$CONTAINER" sh -c "head -c 3 '$cpath' | od -An -tx1 2>/dev/null | tr -d ' \n' | grep -q '^efbbbf' && sed -i '1s/^\xEF\xBB\xBF//' '$cpath' || true"
}

# Run php -l on a file inside the container; returns nonzero on syntax error.
php_lint_in_container() {
    local cpath="$1"
    docker exec "$CONTAINER" php -l "$cpath" 2>&1 | grep -q 'No syntax errors detected'
}

# ==================== Deploy branch ====================
do_deploy() {
    log "mode: deploy"

    # ---- Step 1: obtain the bundle ----
    mkdir -p "$WORK_DIR"
    rm -rf "$WORK_DIR"/*

    local bundle_file=""
    if [ -n "$BUNDLE_PATH" ]; then
        [ -f "$BUNDLE_PATH" ] || die "--bundle file not found: $BUNDLE_PATH"
        bundle_file="$BUNDLE_PATH"
        log "using local bundle: $bundle_file"
    else
        bundle_file="$WORK_DIR/cert-deploy-bundle.tar.gz"
        log "querying release tag: $RELEASE_TAG"
        local rel_api=""
        if [ "$RELEASE_TAG" = "latest" ]; then
            rel_api="https://api.github.com/repos/${REPO}/releases/latest"
        else
            rel_api="https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}"
        fi
        local rel_json
        rel_json=$(curl -fsSL "$rel_api" 2>/dev/null || true)
        [ -n "$rel_json" ] || die "cannot fetch release info from $rel_api"

        local asset_url
        asset_url=$(echo "$rel_json" | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' \
                    | grep -E 'cert-deploy-bundle\.tar\.gz' | head -1 \
                    | sed -E 's/.*"([^"]+)"$/\1/')
        [ -n "$asset_url" ] || die "no cert-deploy-bundle.tar.gz asset found in release '$RELEASE_TAG' of $REPO."

        log "downloading: $asset_url"
        curl -fL -o "$bundle_file" "$asset_url"
        log "bundle size: $(wc -c < "$bundle_file") bytes"
    fi

    # ---- Step 2: unpack ----
    log "unpacking bundle to $WORK_DIR"
    tar -xzf "$bundle_file" -C "$WORK_DIR"

    # Sanity-check the layout
    local missing=0
    for rel in "${PHP_FILES[@]}"; do
        if [ ! -f "$WORK_DIR/$rel" ]; then
            warn "missing in bundle: $rel"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "bundle is incomplete. refusing to deploy."

    # ---- Step 3: take a backup of the current PHP files (once) ----
    # A backup is considered valid if at least one PHP file is findable (flat or nested).
    local existing_n
    existing_n=$(count_backup_files)
    if [ "$existing_n" -gt 0 ] && [ $FORCE_REBACKUP -eq 0 ]; then
        log "backup already exists at $BACKUP_DIR ($existing_n/8 files findable) -> keep it (use --force-rebackup to redo)"
    else
        log "taking backup of current PHP files -> $BACKUP_DIR (flat layout)"
        mkdir -p "$BACKUP_DIR"
        if [ $FORCE_REBACKUP -eq 1 ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
            # Wipe only flat files we own; leave any nested dirs alone for safety
            for rel in "${PHP_FILES[@]}"; do
                name=$(basename "$rel")
                [ -f "$BACKUP_DIR/$name" ] && rm -f "$BACKUP_DIR/$name"
            done
        fi
        # Copy each PHP file flat into backup (filenames are unique across Protocols+Services)
        for rel in "${PHP_FILES[@]}"; do
            local name
            name=$(basename "$rel")
            if ! docker cp "$CONTAINER:$APP_ROOT/$rel" "$BACKUP_DIR/$name" 2>/dev/null; then
                die "failed to backup $rel from container"
            fi
        done
        log "backup ok: 9 files in flat layout"
    fi

    # ---- Step 4: copy new PHP files into the container ----
    log "deploying 9 PHP files into $CONTAINER:$APP_ROOT"
    for rel in "${PHP_FILES[@]}"; do
        docker cp "$WORK_DIR/$rel" "$CONTAINER:$APP_ROOT/$rel"
    done

    # ---- Step 5: strip BOM defensively (idempotent) ----
    log "stripping UTF-8 BOM defensively (idempotent)"
    for rel in "${PHP_FILES[@]}"; do
        strip_bom_in_container "$APP_ROOT/$rel"
    done

    # ---- Step 6: php -l syntax check ----
    log "running php -l on all 9 files"
    local lint_fail=0
    for rel in "${PHP_FILES[@]}"; do
        if php_lint_in_container "$APP_ROOT/$rel"; then
            log "  OK: $rel"
        else
            warn "  FAIL: $rel"
            docker exec "$CONTAINER" php -l "$APP_ROOT/$rel" 2>&1 | sed 's/^/      /' >&2 || true
            lint_fail=1
        fi
    done
    if [ "$lint_fail" -ne 0 ]; then
        warn "syntax check failed -> auto-rolling back from $BACKUP_DIR"
        restore_from_backup
        die "deploy aborted: php -l failed. container has been rolled back."
    fi

    # ---- Step 7: clear Laravel cache + restart container ----
    log "clearing Laravel cache (artisan optimize:clear)"
    docker exec "$CONTAINER" php /www/artisan optimize:clear 2>&1 | sed 's/^/  /' || true

    log "restarting container: $CONTAINER"
    docker restart "$CONTAINER" >/dev/null
    sleep 4

    # ---- Step 8: HTTP self-test ----
    do_selftest
}

# ==================== Rollback branch ====================
do_rollback() {
    log "mode: rollback"
    [ -d "$BACKUP_DIR" ] || die "no backup dir at $BACKUP_DIR. nothing to roll back to."
    local n
    n=$(count_backup_files)
    [ "$n" -gt 0 ] || die "backup dir $BACKUP_DIR has no findable PHP files (flat or nested). nothing to roll back to."
    log "backup files findable: $n/8"

    restore_from_backup

    # Optional DB cleanup
    if [ $KEEP_DB -eq 1 ]; then
        log "--keep-db given -> leaving cert_fingerprint / cert_pem in DB untouched"
    else
        clear_db_cert_fields
    fi

    # Restart + self-test
    log "restarting container: $CONTAINER"
    docker restart "$CONTAINER" >/dev/null
    sleep 4
    do_selftest
}

# Restore PHP files from $BACKUP_DIR into the container (flat or nested layout)
restore_from_backup() {
    log "restoring PHP files from $BACKUP_DIR"
    local restored=0
    for rel in "${PHP_FILES[@]}"; do
        local name
        name=$(basename "$rel")
        local src
        if src=$(find_backup_file "$name"); then
            docker cp "$src" "$CONTAINER:$APP_ROOT/$rel"
            restored=$((restored+1))
        else
            warn "missing in backup: $name -> skip (container copy left untouched)"
        fi
    done
    if [ "$restored" -eq 0 ]; then
        warn "no backup files were restored. check $BACKUP_DIR layout."
    else
        log "restored $restored/8 files"
    fi

    log "stripping BOM defensively"
    for rel in "${PHP_FILES[@]}"; do
        strip_bom_in_container "$APP_ROOT/$rel"
    done

    log "clearing Laravel cache"
    docker exec "$CONTAINER" php /www/artisan optimize:clear 2>&1 | sed 's/^/  /' || true
}

# Clear cert_fingerprint / cert_pem in v2_server via artisan tinker
clear_db_cert_fields() {
    log "clearing DB cert fields (v2_server.cert_fingerprint / cert_pem)"
    local tinker_script='use App\Models\Server; $n = Server::query()->update(["cert_fingerprint" => null, "cert_pem" => null]); echo "rows affected: " . $n . "\n";'
    docker exec "$CONTAINER" php /www/artisan tinker --execute="$tinker_script" 2>&1 | sed 's/^/  /' || true
}

# Try each health URL in order; success = first 200/302/301
do_selftest() {
    [ $SKIP_SELFTEST -eq 1 ] && { warn "--skip-selftest given -> skip HTTP self-test"; return 0; }

    log "HTTP self-test"
    local code=""
    for url in "${HEALTH_URLS[@]}"; do
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || true)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            log "  $url -> HTTP $code"
            if echo "$code" | grep -qE '^(2|3)'; then
                log "self-test OK"
                return 0
            fi
        else
            warn "  $url -> no response"
        fi
    done
    warn "self-test: no healthy endpoint responded. check container logs: docker logs $CONTAINER --tail 50"
    warn "note: this is a warning, not a fatal error. the deploy itself has completed."
    return 0
}

# ==================== Entry ====================
log "==== Xboard panel cert-fingerprint installer v$SCRIPT_VERSION ===="
log "repo:      https://github.com/$REPO"
log "container: $CONTAINER"
log "app root:  $APP_ROOT"
log "compose:   ${COMPOSE_DIR:-<not found>}"
log "backup:    $BACKUP_DIR"

case "$MODE" in
    detect)   print_environment; log "detect mode: no changes made." ;;
    deploy)   do_deploy   ;;
    rollback) do_rollback ;;
    *)        die "internal error: unknown mode '$MODE'" ;;
esac

echo
log "============ done ============"
if [ "$MODE" = "deploy" ]; then
    log "next: wait 60-90s for node websockets to republish cert_fingerprint / cert_pem"
    log "verify: docker exec $CONTAINER php /www/artisan tinker --execute='use App\Models\Server; echo Server::whereNotNull("cert_fingerprint")->count();'"
    log "machine install cmd uses xboard-node-key repo with server_ws_url host as --panel"
    log "rollback later: sudo bash install-panel.sh --rollback"
elif [ "$MODE" = "rollback" ]; then
    if [ $KEEP_DB -eq 1 ]; then
        log "DB cert fields: KEPT (nodes still use cert pinning until next panel rebuild of subscription)"
    else
        log "DB cert fields: CLEARED (nodes will fall back to insecure:true until node-side is also rolled back)"
    fi
    log "re-deploy later: sudo bash install-panel.sh"
fi
echo
