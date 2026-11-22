#!/bin/sh
# Install the docker compose CLI plugin inside a WSL distro.
#
# NOTE: Rancher Desktop already provides `docker compose` in its own distro and, with
# WSL integration enabled, in your other distros. Only use this for a distro without
# that integration, or to get a newer compose than Rancher Desktop bundles.
#
# Usage: ./docker-compose_WSL.sh [version]   e.g. ./docker-compose_WSL.sh v2.40.0  (default: latest)
set -eu

case "$(uname -m)" in
    x86_64|amd64)  ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

ASSET="docker-compose-linux-$ARCH"
if [ -n "${1:-}" ]; then
    case "$1" in v*) VERSION="$1" ;; *) VERSION="v$1" ;; esac
    BASE="https://github.com/docker/compose/releases/download/$VERSION"
else
    VERSION=latest
    BASE="https://github.com/docker/compose/releases/latest/download"
fi
echo "Installing docker compose ($VERSION) for $ARCH..."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL -o "$WORK/$ASSET" "$BASE/$ASSET"
curl -fsSL -o "$WORK/$ASSET.sha256" "$BASE/$ASSET.sha256"
(cd "$WORK" && sha256sum -c "$ASSET.sha256")

PLUGIN_DIR="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"
mkdir -p "$PLUGIN_DIR"
install -m 0755 "$WORK/$ASSET" "$PLUGIN_DIR/docker-compose"
docker compose version 2>/dev/null || "$PLUGIN_DIR/docker-compose" version
