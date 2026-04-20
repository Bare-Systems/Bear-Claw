#!/usr/bin/env sh

set -eu

REPO="${BARECLAW_REPO:-Bare-Systems/BearClaw}"
VERSION="${BARECLAW_VERSION:-latest}"
INSTALL_DIR="${BARECLAW_INSTALL_DIR:-$HOME/.local/bin}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: install.sh [--dir <install-dir>] [--version <tag>] [--dry-run]

Environment:
  BARECLAW_INSTALL_DIR  Override the install directory
  BARECLAW_VERSION      Override the release tag (default: latest)
  BARECLAW_REPO         Override the GitHub repo (default: Bare-Systems/BearClaw)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      shift
      [ "$#" -gt 0 ] || {
        echo "missing value for --dir" >&2
        exit 1
      }
      INSTALL_DIR="$1"
      ;;
    --version)
      shift
      [ "$#" -gt 0 ] || {
        echo "missing value for --version" >&2
        exit 1
      }
      VERSION="$1"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

detect_platform() {
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os/$arch" in
    Linux/x86_64|Linux/amd64)
      printf '%s\n' "linux-x86_64"
      ;;
    Linux/arm64|Linux/aarch64)
      printf '%s\n' "linux-aarch64"
      ;;
    Linux/*)
      echo "unsupported architecture: $arch" >&2
      exit 1
      ;;
    *)
      echo "unsupported operating system: $os" >&2
      exit 1
      ;;
  esac
}

download_url_for() {
  platform="$1"
  asset="bareclaw-${platform}.tar.gz"
  if [ "$VERSION" = "latest" ]; then
    printf 'https://github.com/%s/releases/latest/download/%s\n' "$REPO" "$asset"
  else
    printf 'https://github.com/%s/releases/download/%s/%s\n' "$REPO" "$VERSION" "$asset"
  fi
}

download_file() {
  url="$1"
  out="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$out" "$url"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
    return
  fi

  echo "curl or wget is required to download BearClaw" >&2
  exit 1
}

install_binary() {
  src="$1"
  dst="$2"

  if command -v install >/dev/null 2>&1; then
    install -m 0755 "$src" "$dst"
    return
  fi

  cp "$src" "$dst"
  chmod 0755 "$dst"
}

platform="$(detect_platform)"
asset_url="$(download_url_for "$platform")"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'install_dir=%s\n' "$INSTALL_DIR"
  printf 'download_url=%s\n' "$asset_url"
  exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

archive_path="$tmpdir/bareclaw.tar.gz"
download_file "$asset_url" "$archive_path"
tar -xzf "$archive_path" -C "$tmpdir"

mkdir -p "$INSTALL_DIR"
install_binary "$tmpdir/bareclaw" "$INSTALL_DIR/bareclaw"

printf 'Installed bareclaw to %s/bareclaw\n' "$INSTALL_DIR"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    printf 'Add %s to PATH to invoke bareclaw directly.\n' "$INSTALL_DIR"
    ;;
esac
