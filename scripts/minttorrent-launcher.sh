#!/usr/bin/env sh
set -eu

script_path="$0"
while [ -L "$script_path" ]; do
  link_dir="$(CDPATH= cd -- "$(dirname -- "$script_path")" && pwd)"
  link_target="$(readlink -- "$script_path")"
  case "$link_target" in
    /*) script_path="$link_target" ;;
    *) script_path="$link_dir/$link_target" ;;
  esac
done
script_dir="$(CDPATH= cd -- "$(dirname -- "$script_path")" && pwd)"
if [ -r /etc/minttorrent/config.toml ]; then
  default_config=/etc/minttorrent/config.toml
else
  default_config="$script_dir/../config/config.toml"
fi
command_name="${1:-run}"

case "$command_name" in
  start|stop|restart)
    shift
    [ "$#" -eq 0 ] || { echo "Usage: minttorrent $command_name" >&2; exit 2; }
    exec systemctl "$command_name" minttorrent.service
    ;;
  status)
    shift
    [ "$#" -eq 0 ] || { echo "Usage: minttorrent status" >&2; exit 2; }
    exec systemctl --no-pager status minttorrent.service
    ;;
  logs)
    shift
    exec journalctl -u minttorrent.service -f "$@"
    ;;
  update)
    shift
    exec "$script_dir/../update.sh" "$@"
    ;;
  vpn|torrent|config)
    MINTTORRENT_CONFIG="${MINTTORRENT_CONFIG:-$default_config}"
    export MINTTORRENT_CONFIG
    exec "$script_dir/minttorrent-cli" "$@"
    ;;
  help|--help|-h)
    cat <<'HELP'
Usage:
  minttorrent [run] [client options...]
  minttorrent start|stop|restart|status
  minttorrent logs [journalctl options...]
  minttorrent vpn import|connect|disconnect|status ...
  minttorrent torrent add|list ...
  minttorrent config show
  minttorrent update --bundle ARCHIVE [--verify-only]

Without a subcommand, MintTorrent starts in the foreground. Service commands
require an installed systemd unit; start/stop/restart may require root.
HELP
    exit 0
    ;;
  run)
    [ "$#" -eq 0 ] || shift
    ;;
  *)
    # Preserve qBittorrent-nox command-line compatibility for existing scripts.
    ;;
esac

profile="${MINTTORRENT_PROFILE:-${XDG_CONFIG_HOME:-$HOME/.config}/MintTorrent/qBittorrent}"
LD_LIBRARY_PATH="$script_dir/../lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
QT_PLUGIN_PATH="$script_dir/../plugins"
MINTTORRENT_CONFIG="${MINTTORRENT_CONFIG:-$default_config}"
export LD_LIBRARY_PATH QT_PLUGIN_PATH MINTTORRENT_CONFIG
exec "$script_dir/minttorrent-cli" __launch "$script_dir/qbittorrent-nox" "$profile" "$MINTTORRENT_CONFIG" -- "$@"
