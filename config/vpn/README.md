# VPN configuration

`config.toml` is the runtime configuration. Its `[vpn].config` path selects the
first-run profile source and `[vpn].autostart` controls activation at service
startup. Relative paths resolve from the TOML directory. The selected profile
is copied into qBittorrent's active profile directory only if no profile has
already been imported; WebUI/API imports then become the active saved profile.
The AmneziaWG settings tab and `minttorrent vpn status` show that active path,
handshake state, and data-path health. Imported profiles are stored with
owner-only permissions. Setting autostart to false leaves VPN activation under
the Settings tab/CLI, while BitTorrent networking still fails closed.

`minttorrent vpn check` checks file permissions and parses the profile shape,
keys, endpoints, addresses, and supported AmneziaWG fields. It does not apply
the profile, validate every AmneziaWG obfuscation payload, establish a
handshake, or claim end-to-end protocol compatibility.
