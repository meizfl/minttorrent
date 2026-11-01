#!/usr/bin/env bash
set -Eeuo pipefail

VERIFY_ONLY=0
ARCHIVE_ARG=""
while (($#)); do
  case "$1" in
    --verify-only) VERIFY_ONLY=1; shift ;;
    --bundle)
      (($# >= 2)) || { echo "--bundle requires an archive path" >&2; exit 2; }
      [[ -z "$ARCHIVE_ARG" ]] || { echo "Specify only one bundle" >&2; exit 2; }
      ARCHIVE_ARG="$2"
      shift 2
      ;;
    *)
      [[ -z "$ARCHIVE_ARG" ]] || { echo "Unexpected argument: $1" >&2; exit 2; }
      ARCHIVE_ARG="$1"
      shift
      ;;
  esac
done
[[ -n "$ARCHIVE_ARG" ]] || { echo "Usage: minttorrent update --bundle ARCHIVE [--verify-only]" >&2; exit 2; }

ARCHIVE="$(realpath -- "$ARCHIVE_ARG")"
CHECKSUM_FILE="${ARCHIVE}.sha256"
APP_DIR="${MINTTORRENT_APP_DIR:-/opt/MintTorrent}"
SERVICE_FILE="${MINTTORRENT_SERVICE_FILE:-/etc/systemd/system/minttorrent.service}"
START_TIMEOUT="${MINTTORRENT_UPDATE_START_TIMEOUT:-30}"
[[ "$START_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "Update start timeout must be a positive integer" >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || { echo "Bundle not found: $ARCHIVE" >&2; exit 1; }
[[ -f "$CHECKSUM_FILE" ]] || { echo "Checksum manifest not found: $CHECKSUM_FILE" >&2; exit 1; }

read -r expected_checksum _ < "$CHECKSUM_FILE"
[[ "$expected_checksum" =~ ^[[:xdigit:]]{64}$ ]] || { echo "Invalid SHA-256 manifest" >&2; exit 1; }
actual_checksum="$(sha256sum -- "$ARCHIVE" | awk '{print $1}')"
[[ "${actual_checksum,,}" == "${expected_checksum,,}" ]] || {
  echo "Bundle SHA-256 does not match its manifest" >&2
  exit 1
}

mapfile -t members < <(tar -tzf "$ARCHIVE")
((${#members[@]} > 0)) || { echo "Bundle archive is empty" >&2; exit 1; }
top_level=""
for member in "${members[@]}"; do
  [[ "$member" != /* && "/$member/" != */../* ]] || { echo "Unsafe archive path: $member" >&2; exit 1; }
  [[ "$member" =~ ^(MintTorrent-[A-Za-z0-9._+-]+)(/.*)?$ ]] || {
    echo "Unexpected archive path: $member" >&2
    exit 1
  }
  root="${BASH_REMATCH[1]}"
  if [[ -z "$top_level" ]]; then
    top_level="$root"
  elif [[ "$top_level" != "$root" ]]; then
    echo "Bundle contains multiple top-level directories" >&2
    exit 1
  fi
done
while IFS= read -r archive_type; do
  [[ "$archive_type" =~ ^[-dl]$ ]] || { echo "Unsupported file type in bundle archive: $archive_type" >&2; exit 1; }
done < <(tar -tvzf "$ARCHIVE" | awk '{print substr($0, 1, 1)}')
while IFS= read -r link_target; do
  [[ "$link_target" =~ ^[A-Za-z0-9._+-]+$ ]] || {
    echo "Unsafe symbolic-link target in bundle archive: $link_target" >&2
    exit 1
  }
done < <(tar -tvzf "$ARCHIVE" | awk '$1 ~ /^l/ {sub(/^.* -> /, ""); print}')

if ((VERIFY_ONLY)); then
  echo "Bundle SHA-256 and archive layout are valid: $ARCHIVE"
  exit 0
fi
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run the updater as root: sudo minttorrent update --bundle PATH" >&2
  exit 1
fi
[[ -x "$APP_DIR/bin/minttorrent" ]] || { echo "MintTorrent is not installed in $APP_DIR" >&2; exit 1; }
[[ -f "$SERVICE_FILE" ]] || { echo "Installed systemd unit not found: $SERVICE_FILE" >&2; exit 1; }

APP_PARENT="$(dirname -- "$APP_DIR")"
WORK_DIR="$(mktemp -d "$APP_PARENT/.minttorrent-update.XXXXXX")"
BACKUP_DIR="$APP_PARENT/.minttorrent-rollback.$$"
UNIT_BACKUP="$WORK_DIR/minttorrent.service.previous"
UPDATED=0
COMMITTED=0
SERVICE_STOPPED=0
UNIT_EXISTED=0

rollback() {
  local exit_code=$?
  trap - EXIT
  if ((UPDATED && !COMMITTED)); then
    systemctl stop minttorrent.service >/dev/null 2>&1 || true
    rm -rf -- "$APP_DIR"
    if [[ -d "$BACKUP_DIR" ]]; then mv -- "$BACKUP_DIR" "$APP_DIR"; fi
    if ((UNIT_EXISTED)); then
      install -m 0644 "$UNIT_BACKUP" "$SERVICE_FILE"
    else
      rm -f -- "$SERVICE_FILE"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl start minttorrent.service >/dev/null 2>&1 || true
    echo "Update failed; previous MintTorrent version was restored." >&2
  elif ((SERVICE_STOPPED && !COMMITTED)); then
    systemctl start minttorrent.service >/dev/null 2>&1 || true
  fi
  rm -rf -- "$WORK_DIR"
  exit "$exit_code"
}
trap rollback EXIT

tar -xzf "$ARCHIVE" -C "$WORK_DIR"
STAGED_DIR="$WORK_DIR/$top_level"
[[ -x "$STAGED_DIR/bin/minttorrent" && -x "$STAGED_DIR/bin/qbittorrent-nox" \
   && -x "$STAGED_DIR/bin/minttorrent-cli" ]] || {
  echo "Bundle is missing its MintTorrent launcher, CLI, or C++ qBittorrent binary" >&2
  exit 1
}
[[ -d "$STAGED_DIR/lib" && -f "$STAGED_DIR/webui/qbittorrent/private/index.html" ]] || {
  echo "Bundle is missing native libraries or WebUI assets" >&2
  exit 1
}
[[ -f "$STAGED_DIR/systemd/minttorrent.service" ]] || { echo "Bundle is missing the systemd unit" >&2; exit 1; }
MINTTORRENT_PROFILE="$WORK_DIR/profile-check" "$STAGED_DIR/bin/minttorrent" --version >/dev/null

if [[ -f "$SERVICE_FILE" ]]; then
  cp -a "$SERVICE_FILE" "$UNIT_BACKUP"
  UNIT_EXISTED=1
fi
systemctl stop minttorrent.service
SERVICE_STOPPED=1
mv -- "$APP_DIR" "$BACKUP_DIR"
UPDATED=1
mv -- "$STAGED_DIR" "$APP_DIR"
chown -R root:root "$APP_DIR"
install -m 0644 "$APP_DIR/systemd/minttorrent.service" "$SERVICE_FILE"
systemctl daemon-reload
systemctl start minttorrent.service

for ((attempt = 0; attempt < START_TIMEOUT; ++attempt)); do
  if systemctl is-active --quiet minttorrent.service; then
    COMMITTED=1
    rm -rf -- "$BACKUP_DIR"
    echo "MintTorrent update installed and service is active. Configuration and torrent data were preserved."
    exit 0
  fi
  sleep 1
done
echo "MintTorrent did not become active after update" >&2
exit 1
