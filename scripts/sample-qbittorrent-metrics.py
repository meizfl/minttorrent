#!/usr/bin/env python3
"""Sample transfer and process metrics from an authenticated qBittorrent API."""

import argparse
import csv
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.parse


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="qBittorrent WebUI base URL")
    parser.add_argument("--cookie", required=True, type=Path, help="curl/Mozilla cookie jar")
    parser.add_argument("--hash", required=True, help="torrent info hash")
    parser.add_argument("--profile", required=True, type=Path, help="qBittorrent profile path")
    parser.add_argument("--output", required=True, type=Path, help="new CSV path (must not exist)")
    parser.add_argument("--seconds", required=True, type=int, help="measurement duration")
    parser.add_argument("--interval", type=float, default=1.0, help="sample interval in seconds")
    return parser.parse_args()


def get_json(cookie_path, url):
    # Use curl just like the smoke test's login/API calls. This honors the
    # Netscape cookie jar exactly and bypasses any proxy configured in the
    # surrounding build environment.
    result = subprocess.run(
        ["curl", "--noproxy", "*", "--fail", "--silent", "--show-error",
         "--cookie", str(cookie_path), url],
        capture_output=True,
        text=True,
        timeout=5,
        check=True,
    )
    return json.loads(result.stdout)


def process_for_profile(profile):
    expected = os.path.realpath(profile)
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            raw = Path("/proc", name, "cmdline").read_bytes().split(b"\0")
            args = [part.decode(errors="replace") for part in raw if part]
            profile_args = [arg.split("=", 1)[1] for arg in args if arg.startswith("--profile=")]
            if any(os.path.realpath(path) == expected for path in profile_args):
                return int(name)
        except (OSError, ValueError):
            continue
    raise RuntimeError(f"could not find qBittorrent process using profile {profile}")


def process_sample(pid):
    raw = Path("/proc", str(pid), "stat").read_text()
    # comm is parenthesized and can contain spaces; fields after its last ')' begin at field 3.
    fields = raw[raw.rfind(")") + 2 :].split()
    cpu_ticks = int(fields[11]) + int(fields[12])  # utime + stime, proc fields 14 and 15
    rss_kib = 0
    for line in Path("/proc", str(pid), "status").read_text().splitlines():
        if line.startswith("VmRSS:"):
            rss_kib = int(line.split()[1])
            break
    return cpu_ticks, rss_kib


def main():
    args = arguments()
    if args.seconds < 1 or args.interval <= 0:
        raise SystemExit("seconds must be positive and interval must be greater than zero")
    cookie_path = args.cookie.resolve(strict=True)
    profile = args.profile.resolve(strict=True)
    output = args.output.expanduser().absolute()
    if output.exists():
        raise SystemExit(f"refusing to overwrite metrics file: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)

    pid = process_for_profile(profile)
    hash_query = urllib.parse.urlencode({"hash": args.hash})
    torrent_url = args.url.rstrip("/") + "/api/v2/torrents/info?" + hash_query
    peers_url = args.url.rstrip("/") + "/api/v2/sync/torrentPeers?" + hash_query + "&rid=0"
    transfer_url = args.url.rstrip("/") + "/api/v2/transfer/info"
    clk_tck = os.sysconf("SC_CLK_TCK")
    start = time.monotonic()
    previous_time = start
    previous_cpu, rss = process_sample(pid)
    rows = 0
    columns = [
        "elapsed_seconds", "downloaded_bytes", "uploaded_bytes", "download_bytes_per_second",
        "upload_bytes_per_second", "seeds", "leechers", "connected_peers",
        "process_cpu_percent_of_one_core", "process_rss_kib",
        "peer_rtt_avg_ms", "peer_rtt_min_ms", "peer_rtt_max_ms",
        "session_download_bytes_per_second", "session_upload_bytes_per_second",
        "session_downloaded_bytes", "session_uploaded_bytes", "dht_nodes",
        "dht_bytes_in", "dht_bytes_out", "dht_messages_in", "dht_messages_out",
        "dht_messages_in_dropped", "connection_status",
    ]

    with output.open("x", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        stream.flush()
        while True:
            now = time.monotonic()
            elapsed = now - start
            torrent_data = get_json(cookie_path, torrent_url)
            if isinstance(torrent_data, list):
                torrent = next(
                    (item for item in torrent_data if str(item.get("hash", "")).lower() == args.hash.lower()),
                    None,
                )
            else:
                torrent = torrent_data
            if not isinstance(torrent, dict):
                raise RuntimeError(f"torrent {args.hash} is missing from the qBittorrent API response")
            peer_data = get_json(cookie_path, peers_url)
            transfer = get_json(cookie_path, transfer_url)
            peers = peer_data.get("peers", {})
            peer_rtts = [int(peer.get("rtt", 0)) for peer in peers.values() if int(peer.get("rtt", 0)) > 0]
            cpu_ticks, rss = process_sample(pid)
            span = max(now - previous_time, 1e-6)
            row = {
                "elapsed_seconds": f"{elapsed:.3f}",
                "downloaded_bytes": int(torrent.get("downloaded", 0)),
                "uploaded_bytes": int(torrent.get("uploaded", 0)),
                "download_bytes_per_second": int(torrent.get("dlspeed", 0)),
                "upload_bytes_per_second": int(torrent.get("upspeed", 0)),
                "seeds": int(torrent.get("num_seeds", 0)),
                "leechers": int(torrent.get("num_leechs", 0)),
                "connected_peers": len(peers),
                "process_cpu_percent_of_one_core": f"{100 * (cpu_ticks - previous_cpu) / clk_tck / span:.2f}",
                "process_rss_kib": rss,
                "peer_rtt_avg_ms": f"{sum(peer_rtts) / len(peer_rtts):.2f}" if peer_rtts else "",
                "peer_rtt_min_ms": min(peer_rtts) if peer_rtts else "",
                "peer_rtt_max_ms": max(peer_rtts) if peer_rtts else "",
                "session_download_bytes_per_second": int(transfer.get("dl_info_speed", 0)),
                "session_upload_bytes_per_second": int(transfer.get("up_info_speed", 0)),
                "session_downloaded_bytes": int(transfer.get("dl_info_data", 0)),
                "session_uploaded_bytes": int(transfer.get("up_info_data", 0)),
                "dht_nodes": int(transfer.get("dht_nodes", 0)),
                "dht_bytes_in": int(transfer.get("minttorrent_dht_bytes_in", 0)),
                "dht_bytes_out": int(transfer.get("minttorrent_dht_bytes_out", 0)),
                "dht_messages_in": int(transfer.get("minttorrent_dht_messages_in", 0)),
                "dht_messages_out": int(transfer.get("minttorrent_dht_messages_out", 0)),
                "dht_messages_in_dropped": int(transfer.get("minttorrent_dht_messages_in_dropped", 0)),
                "connection_status": transfer.get("connection_status", "unknown"),
            }
            writer.writerow(row)
            stream.flush()
            rows += 1
            if elapsed >= args.seconds:
                break
            previous_time = now
            previous_cpu = cpu_ticks
            time.sleep(min(args.interval, max(0.0, args.seconds - elapsed)))

    print(f"PASS: sampled {rows} rows for {args.seconds}s; CSV: {output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"metrics sampling failed: {error}", file=sys.stderr)
        raise SystemExit(1)
