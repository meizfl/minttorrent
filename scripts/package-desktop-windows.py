#!/usr/bin/env python3
"""Package a cross-built Qt/MinGW desktop client and its recursive PE imports."""
from pathlib import Path
import hashlib
import os
import re
import shutil
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
build = Path(os.environ.get('MINTTORRENT_DESKTOP_BUILD_ROOT', root / 'build/desktop-windows'))
qt = Path(os.environ.get('MINTTORRENT_QT_WINDOWS', root / 'build/windows-qt/6.8.3/mingw_64'))
dist = Path(os.environ.get('MINTTORRENT_DIST_DIR', root / 'dist'))
version = (root / 'VERSION').read_text().strip()
name = f'MintTorrent-{version}-desktop-windows-x86_64'
stage = dist / name
stage.mkdir(parents=True, exist_ok=True)
binary = build / 'qbittorrent/qbittorrent.exe'
if not binary.is_file():
    raise SystemExit(f'Build desktop first: missing {binary}')
shutil.copy2(binary, stage / 'MintTorrent.exe')
for group in ('platforms', 'styles', 'imageformats', 'iconengines', 'tls'):
    source = qt / 'plugins' / group
    if source.exists():
        shutil.copytree(source, stage / 'plugins' / group, dirs_exist_ok=True)
shutil.rmtree(stage / 'plugins/sqldrivers', ignore_errors=True)
(stage / 'plugins/sqldrivers').mkdir(parents=True)
shutil.copy2(qt / 'plugins/sqldrivers/qsqlite.dll', stage / 'plugins/sqldrivers/qsqlite.dll')
(stage / 'qt.conf').write_text('[Paths]\nPrefix=.\nPlugins=plugins\n', encoding='utf-8')
# Prefer compiler runtimes matching the compiler that produced this executable.
compiler = shutil.which('x86_64-w64-mingw32-g++-posix') or shutil.which('x86_64-w64-mingw32-g++')
runtime_dirs = []
if compiler:
    for runtime in ('libstdc++-6.dll', 'libgcc_s_seh-1.dll', 'libwinpthread-1.dll', 'libssp-0.dll'):
        resolved = Path(subprocess.check_output([compiler, '-print-file-name=' + runtime], text=True).strip())
        if resolved.is_file() and resolved.parent not in runtime_dirs:
            runtime_dirs.append(resolved.parent)
search = runtime_dirs + [Path('/usr/x86_64-w64-mingw32/bin'), build / 'native/bin', qt / 'bin']
index = {}
for directory in search:
    for path in directory.glob('*.dll'):
        index.setdefault(path.name.lower(), path)
# Windows-provided API sets and system DLLs; anything else must be packaged.
system = set('''advapi32 authz avicap32 avrt bcrypt cabinet cfgmgr32 comctl32 comdlg32 crypt32
cryptbase d2d1 d3d9 d3d11 d3d12 dbghelp dhcpcsvc dnsapi dwrite dwmapi dxgi dxguid
fwpuclnt gdi32 glu32 imm32 iphlpapi kernel32 kernelbase mpr msvcrt msimg32
ncrypt netapi32 normaliz ntdll ole32 oleaut32 opengl32 powrprof propsys psapi rasapi32
rpcrt4 secur32 setupapi shcore shell32 shlwapi ucrtbase user32 userenv usp10
uxtheme version winhttp wininet winmm winspool wintrust wldap32 ws2_32 wtsapi32'''.split())
queue = list(stage.rglob('*.dll')) + [stage / 'MintTorrent.exe']
seen = set()
report = []
while queue:
    path = queue.pop(0)
    if path in seen:
        continue
    seen.add(path)
    output = subprocess.check_output(['x86_64-w64-mingw32-objdump', '-p', str(path)], text=True)
    for name_import in re.findall(r'DLL Name:\s*(\S+)', output):
        key = name_import.lower()
        if key in index:
            target = stage / index[key].name
            if not target.exists():
                shutil.copy2(index[key], target)
                queue.append(target)
            report.append(f'{path.relative_to(stage)} -> {target.name} [bundled]')
        elif key.startswith(('api-ms-win-', 'ext-ms-win-')) or key.removesuffix('.dll') in system:
            report.append(f'{path.relative_to(stage)} -> {name_import} [Windows]')
        else:
            raise SystemExit(f'Unresolved non-system DLL: {path.name} -> {name_import}')
(stage / 'PE-DEPENDENCIES.txt').write_text('\n'.join(sorted(report)) + '\n', encoding='utf-8')
licenses = stage / 'licenses'
licenses.mkdir(exist_ok=True)
for source, dest in ((root/'LICENSE', stage/'LICENSE'), (root/'vendor/qbittorrent/COPYING', licenses/'qBittorrent-COPYING'), (root/'vendor/libtorrent/COPYING', licenses/'libtorrent-COPYING'), (root/'components/amneziawg-go/LICENSE', licenses/'amneziawg-go-LICENSE'), (root/'build/windows-sources/openssl-3.0.16/LICENSE.txt', licenses/'OpenSSL-LICENSE.txt'), (root/'licenses/Go-LICENSE', licenses/'Go-LICENSE')):
    shutil.copy2(source, dest)
for module in ('qt6-base', 'qt6-svg', 'qt6-tools'):
    source = Path('/usr/share/licenses') / module
    if source.exists():
        shutil.copytree(source, licenses / module, dirs_exist_ok=True)
shutil.copytree(root / 'licenses/runtime', licenses / 'runtime', dirs_exist_ok=True)
(stage / 'README.txt').write_text('''MintTorrent desktop for Windows x64 (Windows 10/11).
Extract the entire ZIP and run MintTorrent.exe.
Open Tools > Options > AmneziaWG, import a VPN .conf, Save profile and connect.
gVisor Netstack configures IP families, MTU, packet queue and TCP buffers.
No VPN credentials are included. Torrent traffic is blocked without an active VPN.
State is stored in the MintTorrent user profile, separate from stock qBittorrent.
Python search plugins are disabled because the Linux socket sandbox is unavailable.
Cross-compiled on Linux. See BUILD-STATUS.txt for runtime verification limits.
''', encoding='utf-8')
(stage / 'BUILD-STATUS.txt').write_text('Windows x86_64 PE build; recursive DLL import closure verified.\nNative Windows runtime and VPN transfer acceptance remain untested.\n', encoding='utf-8')
manifest = []
for path in sorted(stage.rglob('*')):
    if path.is_file() and path.name != 'SHA256SUMS':
        manifest.append(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(stage).as_posix()}')
(stage / 'SHA256SUMS').write_text('\n'.join(manifest) + '\n')
archive = dist / f'{stage.name}.zip'
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for path in sorted(stage.rglob('*')):
        if path.is_file():
            z.write(path, path.relative_to(dist))
(archive.with_suffix(archive.suffix + '.sha256')).write_text(f'{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n')
print(archive)
