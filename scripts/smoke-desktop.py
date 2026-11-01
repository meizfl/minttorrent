#!/usr/bin/env python3
"""Exercise the desktop runtime and its embedded API with an isolated profile."""
from pathlib import Path
import base64
import hashlib
import http.cookiejar
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

launcher = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='minttorrent-desktop-smoke-') as tmp:
    work = Path(tmp)
    config = work / 'profile/MintTorrent/config'
    config.mkdir(parents=True)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    password = 'desktop-smoke-' + os.urandom(12).hex()
    salt = os.urandom(16)
    secret = base64.b64encode(salt).decode() + ':' + base64.b64encode(hashlib.pbkdf2_hmac('sha512', password.encode(), salt, 100000)).decode()
    (config / ('qBittorrent.ini' if os.environ.get('MINTTORRENT_SMOKE_WINDOWS') == '1' else 'qBittorrent.conf')).write_text(f'''[LegalNotice]
Accepted=true
[Meta]
MigrationVersion=12
[WebUI]
Enabled=true
Address=127.0.0.1
Port={port}
Username=admin
Password_PBKDF2="@ByteArray({secret})"
[MintTorrent]
VPN\\Enabled=false
''')
    env = dict(os.environ, QT_QPA_PLATFORM='offscreen', MINTTORRENT_VPN_AUTOSTART='false')
    env.pop('LD_PRELOAD', None)
    env.pop('LD_LIBRARY_PATH', None)
    env.pop('QT_PLUGIN_PATH', None)
    with (work/'run.log').open('w') as log:
        process = subprocess.Popen([str(launcher), f'--profile={work / "profile"}', '--confirm-legal-notice'], env=env, stdout=log, stderr=log)
        try:
            base = f'http://127.0.0.1:{port}'
            client = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
            def request(path, form=None):
                body = urllib.parse.urlencode(form).encode() if form is not None else None
                req = urllib.request.Request(base + path, data=body, headers={'Referer': base + '/'})
                with client.open(req, timeout=5) as response:
                    return response.read()
            for _ in range(100):
                if process.poll() is not None:
                    raise RuntimeError('Desktop exited before API startup')
                try:
                    request('/')
                    break
                except (OSError, urllib.error.URLError):
                    time.sleep(.1)
            else:
                raise RuntimeError('Desktop API did not start')
            assert request('/api/v2/auth/login', {'username':'admin', 'password':password}) in (b'Ok.', b'')
            assert request('/api/v2/app/version').decode() == (Path(__file__).resolve().parents[1] / 'VERSION').read_text().strip()
            state = json.loads(request('/api/v2/app/minttorrentVpnStatus'))
            assert not state['active'] and not state['enabled']
            assert not state['configured']
            assert json.loads(request('/api/v2/torrents/info')) == []
            request('/api/v2/app/setPreferences', {'json':json.dumps({'current_network_interface':'eth0','current_interface_address':'192.0.2.10','proxy_type':'SOCKS5','proxy_ip':'127.0.0.1','proxy_port':1080})})
            prefs = json.loads(request('/api/v2/app/preferences'))
            assert prefs['proxy_type'] == 'None'
            assert prefs['current_network_interface'] == '' and prefs['current_interface_address'] == ''
            request('/api/v2/app/minttorrentVpnSet', {'enabled':'false'})
            try:
                request('/api/v2/app/minttorrentVpnImport', {'profile':'invalid','ipv4':'true','ipv6':'true','mtu':'1','packet_queue':'1024','tcp_send_buffer':'1048576','tcp_receive_buffer':'1048576'})
                raise AssertionError('Invalid MTU accepted')
            except urllib.error.HTTPError as error:
                assert error.code == 415
            assert not json.loads(request('/api/v2/app/minttorrentVpnStatus'))['configured']
            request('/api/v2/app/shutdown', {})
            process.wait(timeout=15)
            assert process.returncode == 0
            print('PASS: desktop startup, authenticated API, VPN fail-closed state, proxy/interface lockdown, invalid settings rejection and clean shutdown')
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
