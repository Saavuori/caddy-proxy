#!/bin/bash
# Add a service to the Caddy proxy: writes the Caddyfile route and the portal
# card in one go. Caddy runs with --watch, so the route goes live on its own —
# no restart, no manual editing of index.html.
set -euo pipefail

CADDYFILE="${CADDYFILE:-Caddyfile}"
SERVICES_FILE="${SERVICES_FILE:-services.json}"
PALETTE=("#3b82f6" "#10b981" "#06b6d4" "#84cc16" "#f59e0b" "#a855f7" "#ec4899" "#ef4444")

usage() {
    cat <<'EOF'
Usage: ./add-service.sh --path <url-path> --upstream <host:port> --name <title> [options]

Required:
  --path <url-path>       Path segment to serve the app under, e.g. "myapp"
                          -> https://your-domain/myapp/
  --upstream <host:port>  Where Caddy proxies to. Bridge containers use their
                          container name (my-app:3000); host-mode containers use
                          host.docker.internal:8080.
  --name <title>          Card title on the portal, e.g. "My App"

Options:
  --description <text>    Card body text.
  --category <text>       Small uppercase label under the title.
  --badge <text>          Status pill label (defaults to --name).
  --icon <emoji>          Card icon (default: 🧩).
  --accent <#hex>         Card accent colour (default: next colour in palette).
  --no-portal             Add the Caddy route only, no portal card.
  --dry-run               Print what would change and exit.
  -h, --help              Show this help.

Example:
  ./add-service.sh \
    --path solarflow --upstream solar-collector:3000 --name "SolarFlow" \
    --category "PV Monitor" --icon ☀️ --accent "#f59e0b" \
    --description "Collects inverter output and exports it to InfluxDB."
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

PATH_SEGMENT=""
UPSTREAM=""
NAME=""
DESCRIPTION=""
CATEGORY=""
BADGE=""
ICON=""
ACCENT=""
ADD_PORTAL=1
DRY_RUN=0

while [ $# -gt 0 ]; do
    # Without this, a value-taking flag left dangling at the end of the line
    # makes `shift 2` fail and `set -e` end the script without a word.
    case "$1" in
        --path|--upstream|--name|--description|--category|--badge|--icon|--accent)
            [ $# -ge 2 ] || { usage >&2; die "$1 needs a value"; } ;;
    esac
    case "$1" in
        --path)        PATH_SEGMENT="${2:-}"; shift 2 ;;
        --upstream)    UPSTREAM="${2:-}"; shift 2 ;;
        --name)        NAME="${2:-}"; shift 2 ;;
        --description) DESCRIPTION="${2:-}"; shift 2 ;;
        --category)    CATEGORY="${2:-}"; shift 2 ;;
        --badge)       BADGE="${2:-}"; shift 2 ;;
        --icon)        ICON="${2:-}"; shift 2 ;;
        --accent)      ACCENT="${2:-}"; shift 2 ;;
        --no-portal)   ADD_PORTAL=0; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage >&2; die "unknown argument '$1'" ;;
    esac
done

[ -n "$PATH_SEGMENT" ] || { usage >&2; die "--path is required"; }
[ -n "$UPSTREAM" ] || { usage >&2; die "--upstream is required"; }
[ -n "$NAME" ] || { usage >&2; die "--name is required"; }

# Normalise "/myapp/" -> "myapp"
PATH_SEGMENT="${PATH_SEGMENT#/}"
PATH_SEGMENT="${PATH_SEGMENT%/}"
case "$PATH_SEGMENT" in
    *[!a-z0-9._/-]*) die "--path must be lowercase letters, digits, '.', '_', '-' or '/' (got '$PATH_SEGMENT')" ;;
esac
[ -n "$PATH_SEGMENT" ] || die "--path cannot be empty"

case "$UPSTREAM" in
    *:*) ;;
    *) die "--upstream must be host:port (got '$UPSTREAM')" ;;
esac

[ -f "$CADDYFILE" ] || die "$CADDYFILE not found. Run this from your caddy-proxy directory, or set CADDYFILE=/path/to/Caddyfile."

# Fixed strings, so a '.' in the segment is not a regex wildcard. The second
# form is the older `/seg*` matcher that existing Caddyfiles still carry.
if grep -qF -e "handle_path /${PATH_SEGMENT}/*" -e "handle_path /${PATH_SEGMENT}*" "$CADDYFILE"; then
    die "/${PATH_SEGMENT} is already routed in $CADDYFILE. Remove it first, or pick another --path."
fi

ROUTE_BLOCK=$(printf '\n    redir /%s /%s/\n    handle_path /%s/* {\n        reverse_proxy %s\n    }\n' \
    "$PATH_SEGMENT" "$PATH_SEGMENT" "$PATH_SEGMENT" "$UPSTREAM")

# Prefer the managed-routes end marker; fall back to the last `handle {` block
# (the portal fallback), which must stay last for path matching to work.
INSERT_LINE=$(grep -n '# <<< caddy-proxy:routes' "$CADDYFILE" | head -1 | cut -d: -f1 || true)
if [ -z "$INSERT_LINE" ]; then
    INSERT_LINE=$(grep -n '^[[:space:]]*handle[[:space:]]*{[[:space:]]*$' "$CADDYFILE" | tail -1 | cut -d: -f1 || true)
fi
[ -n "$INSERT_LINE" ] || die "could not find an insertion point in $CADDYFILE (no '# <<< caddy-proxy:routes' marker and no fallback 'handle {' block). Add the marker lines from Caddyfile.example, or edit by hand."

PY_BIN=""
if [ "$ADD_PORTAL" = "1" ]; then
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import json" >/dev/null 2>&1; then
            PY_BIN="$candidate"
            break
        fi
    done
    [ -n "$PY_BIN" ] || die "python3 is required to update $SERVICES_FILE. Install it, or re-run with --no-portal and add the card by hand."
    [ -n "$ICON" ] || ICON="🧩"
    [ -n "$BADGE" ] || BADGE="$NAME"
    if [ -z "$ACCENT" ]; then
        COUNT=0
        if [ -f "$SERVICES_FILE" ]; then
            COUNT=$(grep -c '"path"' "$SERVICES_FILE" || true)
        fi
        ACCENT="${PALETTE[$((COUNT % ${#PALETTE[@]}))]}"
    fi
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "==> Would add to $CADDYFILE (before line $INSERT_LINE):"
    printf '%s\n' "$ROUTE_BLOCK"
    if [ "$ADD_PORTAL" = "1" ]; then
        echo "==> Would add to $SERVICES_FILE: $NAME -> /${PATH_SEGMENT}/ (accent $ACCENT, icon $ICON)"
    fi
    exit 0
fi

TMPDIR_WORK=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_WORK"; }
trap cleanup EXIT

cp "$CADDYFILE" "$TMPDIR_WORK/Caddyfile.backup"
{
    head -n "$((INSERT_LINE - 1))" "$CADDYFILE"
    printf '%s\n' "$ROUTE_BLOCK"
    tail -n +"$INSERT_LINE" "$CADDYFILE"
} > "$TMPDIR_WORK/Caddyfile.new"
# Write in place (not mv): the file is bind-mounted into the container by inode.
cat "$TMPDIR_WORK/Caddyfile.new" > "$CADDYFILE"
echo "==> Added route /${PATH_SEGMENT}/ -> ${UPSTREAM} in $CADDYFILE"

restore_caddyfile() {
    cat "$TMPDIR_WORK/Caddyfile.backup" > "$CADDYFILE"
    echo "==> Reverted $CADDYFILE"
}

# Validate before letting --watch pick the change up.
caddy_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'caddy-proxy'
}

validate_caddyfile() {
    if caddy_running; then
        docker exec -i caddy-proxy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    else
        local abs
        abs="$(cd "$(dirname "$CADDYFILE")" && pwd)/$(basename "$CADDYFILE")"
        docker run --rm -v "${abs}:/etc/caddy/Caddyfile:ro" caddy:2-alpine \
            caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    fi
}

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "==> Validating Caddyfile..."
    if ! validate_caddyfile >/dev/null 2>"$TMPDIR_WORK/validate.err"; then
        cat "$TMPDIR_WORK/validate.err" >&2
        restore_caddyfile
        die "Caddyfile validation failed, nothing was changed."
    fi
else
    echo "==> Docker not reachable, skipping Caddyfile validation."
fi

if [ "$ADD_PORTAL" = "1" ]; then
    [ -f "$SERVICES_FILE" ] || echo '{"services": []}' > "$SERVICES_FILE"
    cp "$SERVICES_FILE" "$TMPDIR_WORK/services.backup"

    if ! SVC_IN="$SERVICES_FILE" \
         SVC_OUT="$TMPDIR_WORK/services.new" \
         SVC_NAME="$NAME" \
         SVC_BADGE="$BADGE" \
         SVC_CATEGORY="$CATEGORY" \
         SVC_ICON="$ICON" \
         SVC_ACCENT="$ACCENT" \
         SVC_PATH_SEGMENT="$PATH_SEGMENT" \
         SVC_DESCRIPTION="$DESCRIPTION" \
         "$PY_BIN" - <<'PY'
import json, os, sys

src, dst = os.environ["SVC_IN"], os.environ["SVC_OUT"]
try:
    with open(src, encoding="utf-8") as fh:
        data = json.load(fh)
except (ValueError, OSError) as exc:
    sys.exit("could not parse %s: %s" % (src, exc))

services = data.get("services", []) if isinstance(data, dict) else data
if not isinstance(services, list):
    sys.exit("%s: 'services' must be a list" % src)

entry = {
    "name": os.environ["SVC_NAME"],
    "badge": os.environ["SVC_BADGE"],
    "category": os.environ["SVC_CATEGORY"],
    "icon": os.environ["SVC_ICON"],
    "accent": os.environ["SVC_ACCENT"],
    # Built here rather than passed in with slashes, which some shells rewrite.
    "path": "/%s/" % os.environ["SVC_PATH_SEGMENT"].strip("/"),
    "description": os.environ["SVC_DESCRIPTION"],
}
entry = {k: v for k, v in entry.items() if v != ""}

services = [s for s in services if not (isinstance(s, dict) and s.get("path") == entry["path"])]
services.append(entry)

if isinstance(data, dict):
    data["services"] = services
else:
    data = services

with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
    then
        restore_caddyfile
        die "failed to update $SERVICES_FILE, nothing was changed."
    fi

    cat "$TMPDIR_WORK/services.new" > "$SERVICES_FILE"
    echo "==> Added portal card '$NAME' to $SERVICES_FILE"
fi

echo ""
if caddy_running; then
    echo "==> Done. Caddy is running with --watch and will reload within a couple of seconds."
    echo "    Watch it happen:  docker compose logs -f caddy"
else
    echo "==> Done. Start the proxy to pick it up:  docker compose up -d"
fi
echo "    New service URL:  /${PATH_SEGMENT}/"
