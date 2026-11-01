#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${MINTTORRENT_INSTALL_TEST_SANDBOX:-}" != 1 || ${EUID} -ne 0 \
      || ( ! -e /.dockerenv && ! -e /run/.containerenv ) ]]; then
  echo "This test must run as root inside a disposable Podman/Docker container with MINTTORRENT_INSTALL_TEST_SANDBOX=1" >&2
  exit 2
fi

BUNDLE_DIR="$(cd -- "${1:?usage: test-install-lifecycle-container.sh BUNDLE_DIR}" && pwd)"
if getent passwd minttorrent >/dev/null; then
  echo "Refusing to use a container that already has the minttorrent account" >&2
  exit 1
fi
for path in /opt/MintTorrent /etc/minttorrent /etc/systemd/system/minttorrent.service \
            /usr/local/bin/minttorrent /var/lib/minttorrent /var/log/minttorrent \
            /run/systemd/system; do
  [[ ! -e "$path" && ! -L "$path" ]] || {
    echo "Refusing to overwrite pre-existing test path: $path" >&2
    exit 1
  }
done

WORK_DIR="$(mktemp -d /tmp/minttorrent-install-test.XXXXXX)"
FAKE_BIN="$WORK_DIR/bin"
SYSTEMCTL_LOG="$WORK_DIR/systemctl.log"
mkdir -p "$FAKE_BIN" /run/systemd/system
cat > "$FAKE_BIN/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MINTTORRENT_TEST_SYSTEMCTL_LOG"
exit 0
SYSTEMCTL
chmod 0755 "$FAKE_BIN/systemctl"
export MINTTORRENT_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG"
export PATH="$FAKE_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

cleanup() {
  local status=$?
  if [[ -e /opt/MintTorrent || -e /etc/systemd/system/minttorrent.service \
        || -L /usr/local/bin/minttorrent ]]; then
    "$BUNDLE_DIR/uninstall.sh" >/dev/null 2>&1 || true
  fi
  rm -rf -- /opt/MintTorrent /etc/minttorrent /etc/systemd/system/minttorrent.service \
    /usr/local/bin/minttorrent /var/lib/minttorrent /var/log/minttorrent \
    /run/systemd/system "$WORK_DIR"
  if getent passwd minttorrent >/dev/null; then userdel minttorrent; fi
  exit "$status"
}
trap cleanup EXIT

"$BUNDLE_DIR/install.sh" --enable-and-start
[[ -x /opt/MintTorrent/bin/minttorrent && -x /opt/MintTorrent/bin/qbittorrent-nox ]]
[[ "$(readlink -f /usr/local/bin/minttorrent)" == /opt/MintTorrent/bin/minttorrent ]]
[[ "$(stat -c '%U:%G:%a' /var/lib/minttorrent/profile)" == minttorrent:minttorrent:750 ]]
[[ "$(stat -c '%U:%G:%a' /etc/minttorrent/config.toml)" == root:minttorrent:640 ]]
getent passwd minttorrent >/dev/null
grep -qx 'enable minttorrent.service' "$SYSTEMCTL_LOG"
grep -qx 'start minttorrent.service' "$SYSTEMCTL_LOG"

printf '\n# install lifecycle preservation sentinel\n' >> /etc/minttorrent/config.toml
printf 'keep this user data\n' > /var/lib/minttorrent/profile/keep-me
"$BUNDLE_DIR/install.sh" --no-enable
grep -q 'install lifecycle preservation sentinel' /etc/minttorrent/config.toml

"$BUNDLE_DIR/uninstall.sh"
[[ ! -e /opt/MintTorrent && ! -e /etc/systemd/system/minttorrent.service ]]
[[ ! -L /usr/local/bin/minttorrent ]]
[[ -s /var/lib/minttorrent/profile/keep-me ]]
grep -q 'install lifecycle preservation sentinel' /etc/minttorrent/config.toml
grep -qx 'disable --now minttorrent.service' "$SYSTEMCTL_LOG"

echo "PASS: isolated install, enable/start routing, config preservation, uninstall, and user-data preservation."
