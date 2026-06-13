#!/bin/bash
set -e

REPO="Saavuori/caddy-proxy"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
INSTALL_DIR="${1:-caddy-proxy}"

echo "==> Installing caddy-proxy into ./${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "==> Downloading docker-compose.yml..."
curl -fsSL "${BASE_URL}/docker-compose.yml" -o docker-compose.yml

echo "==> Downloading Caddyfile..."
curl -fsSL "${BASE_URL}/Caddyfile" -o Caddyfile

echo "==> Checking docker network 'web-proxy'..."
if ! docker network inspect web-proxy >/dev/null 2>&1; then
  echo "==> Creating 'web-proxy' external docker network..."
  docker network create web-proxy
else
  echo "==> 'web-proxy' docker network already exists, skipping."
fi

echo ""
echo "==> Done! Next steps:"
echo "  1. Generate your secure bcrypt hash for Caddy basic auth:"
echo "     docker run --rm caddy caddy hash-password --plaintext \"your-secure-password\""
echo "  2. Edit Caddyfile to add your domain, email, and password hash:"
echo "     nano Caddyfile"
echo "  3. Start the proxy: "
echo "     docker compose up -d"
