#!/usr/bin/env bash
#
# Xboard panel-side cert-fingerprint deployment / rollback script
# Repo:  https://github.com/pandanetworkgroup/xboard-panel-key
#
# This script must be run ON THE PANEL HOST (the machine that runs the xboard
# docker container). It needs:
#   * root (or sudo) for docker access
#   * docker CLI available on PATH
#   * the xboard container running (default name: xboard-xboard-1)
#   * internet access to raw.githubusercontent.com / api.github.com (unless --bundle is given)
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
# 3) Rollback to the pre-deploy backup, AND clear DB cert fields (default):
#
#    sudo bash install-panel.sh --rollback
#
# 4) Rollback but keep DB cert fields intact (nodes will keep using cert pinning):
#
#    sudo bash install-panel.sh --rollback --keep-db
#
# 5) Offline deploy using a local tar.gz bundle:
#
#    sudo bash install-panel.sh --bundle ./cert-deploy-bundle.tar.gz
#
# ----------------------------------------------------------------------------
set -euo pipefail

# ==================== Constants ====================
REPO="pandanetworkgroup/xboard-panel-key"
SCRIPT_VERSION="1.0.0"

# Default container name (Xboard docker-compose default)
DEF_CONTAINER="xboard-xboard-1"

# Health-check URL candidates tried in order (first wins)
DEF_HEALTH_URLS=( "http://127.0.0.1:7001/" "http://127.0.0.1/" )

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
)
APP_ROOT="/www/app"

# ==================== Logging ====================
if [ -t 2 ]; then
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_OFF=$'\033[0m'
else
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_OFF=''
fi
log()  { printf '%s[install]%s %s\n' "$C_GREEN"  "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n'    "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s[error]%s %s\n'   "$C_RED"    "$C_OFF" "$*" >&2; exit 1; }

# ==================== Args ====================
MODE="deploy"          # deploy | rollback
CONTAINER="$DEF_CONTAINER"
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
Xboard panel-side cert-fingerprint installer (deploy / rollback)

One-line deploy (recommended):
  curl -fsSL https://raw.githubusercontent.com/pandanetworkgroup/xboard-panel-key/main/install-panel.sh \
    | sudo bash -s -

Interactive deploy:
  sudo bash install-panel.sh

Rollback (default also clears DB cert fields):
  sudo bash install-panel.sh --rollback [--keep-db]

Offline deploy with a local bundle:
  sudo bash install-panel.sh --bundle ./cert-deploy-bundle.tar.gz

Args:
  --rollback               rollback to the pre-deploy backup (default also clears DB)
  --keep-db                rollback only, keep cert_fingerprint / cert_pem in DB
  --container NAME         xboard docker container name (default: xboard-xboard-1)
  --backup-dir DIR         host backup dir (default: /root/php_pre_cert_deploy)
  --work-dir DIR           host working dir for unpack (default: /root/cert-deploy-work)
  --health-url URL         health-check URL (repeatable; default: http://127.0.0.1:7001/ , http://127.0.0.1/)
  --bundle PATH            use a local tar.gz bundle instead of downloading from GitHub
  --release-tag TAG        github release tag to fetch (default: latest)
  --force-rebackup         re-take a backup even if one already exists
  --skip-selftest          skip the final HTTP self-test
  -h, --help               show this help
USAGE_EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rollback)        MODE="rollback"; shift ;;
        --keep-db)         KEEP_DB=1; shift ;;
        --container)       CONTAINER="$2"; shift 2 ;;
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

# Verify the container exists and is running
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q '^true$'; then
    die "container '$CONTAINER' is not running. pass --container NAME to override."
fi
log "container: $CONTAINER  (state: running)"

# Verify the container app layout looks like Xboard
if ! docker exec "$CONTAINER" test -d "$APP_ROOT/Protocols" 2>/dev/null; then
    die "container '$CONTAINER' does not have $APP_ROOT/Protocols/. is this an Xboard container?"
fi

# ==================== Helpers ====================

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
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null | wc -l)" -gt 0 ] && [ $FORCE_REBACKUP -eq 0 ]; then
        log "backup already exists at $BACKUP_DIR -> keep it (use --force-rebackup to redo)"
    else
        log "taking backup of current PHP files -> $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
        rm -rf "$BACKUP_DIR"/*
        # Copy Protocols dir flat into backup (filenames are unique)
        for rel in "${PHP_FILES[@]}"; do
            local name
            name=$(basename "$rel")
            if ! docker cp "$CONTAINER:$APP_ROOT/$rel" "$BACKUP_DIR/$name" 2>/dev/null; then
                die "failed to backup $rel from container"
            fi
        done
        log "backup ok: $(ls -1 "$BACKUP_DIR" | wc -l) files"
    fi

    # ---- Step 4: copy new PHP files into the container ----
    log "deploying 8 PHP files into $CONTAINER:$APP_ROOT"
    for rel in "${PHP_FILES[@]}"; do
        docker cp "$WORK_DIR/$rel" "$CONTAINER:$APP_ROOT/$rel"
    done

    # ---- Step 5: strip BOM defensively (idempotent) ----
    log "stripping UTF-8 BOM defensively (idempotent)"
    for rel in "${PHP_FILES[@]}"; do
        strip_bom_in_container "$APP_ROOT/$rel"
    done

    # ---- Step 6: php -l syntax check ----
    log "running php -l on all 8 files"
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
    n=$(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] || die "backup dir $BACKUP_DIR is empty. nothing to roll back to."
    log "backup files: $n"

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

# Restore PHP files from $BACKUP_DIR into the container
restore_from_backup() {
    log "restoring PHP files from $BACKUP_DIR"
    for rel in "${PHP_FILES[@]}"; do
        local name
        name=$(basename "$rel")
        if [ ! -f "$BACKUP_DIR/$name" ]; then
            warn "missing in backup: $name -> skip"
            continue
        fi
        docker cp "$BACKUP_DIR/$name" "$CONTAINER:$APP_ROOT/$rel"
    done

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
log "backup:    $BACKUP_DIR"

case "$MODE" in
    deploy)   do_deploy   ;;
    rollback) do_rollback ;;
    *)        die "internal error: unknown mode '$MODE'" ;;
esac

echo
log "============ done ============"
if [ "$MODE" = "deploy" ]; then
    log "next: wait 60-90s for node websockets to republish cert_fingerprint / cert_pem"
    log "verify: docker exec $CONTAINER php /www/artisan tinker --execute='use App\\Models\\Server; echo Server::whereNotNull(\"cert_fingerprint\")->count();'"
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
