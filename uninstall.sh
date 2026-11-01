#!/usr/bin/env bash
set -euo pipefail
if [[ "${EUID}" -ne 0 ]]; then echo "Run this uninstaller as root: sudo ./uninstall.sh" >&2; exit 1; fi
systemctl disable --now minttorrent.service 2>/dev/null || true
rm -f /etc/systemd/system/minttorrent.service
systemctl daemon-reload
if [[ -L /usr/local/bin/minttorrent && "$(readlink -f -- /usr/local/bin/minttorrent)" == /opt/MintTorrent/bin/minttorrent ]]; then rm -f /usr/local/bin/minttorrent; fi
rm -rf /opt/MintTorrent
echo "Removed MintTorrent binaries and service. qBittorrent profile and downloads under /var/lib/minttorrent were preserved."
