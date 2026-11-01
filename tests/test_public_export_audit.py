"""Offline checks for the public-export credential boundary."""
from pathlib import Path
import base64
import importlib.util
import io
import tarfile
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/audit-public-export.py'

class PublicExportAuditTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('public_export_audit', SCRIPT)
        self.audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.audit)

    def test_placeholder_is_allowed(self):
        self.audit.check('default.conf.example', b'PrivateKey = <YOUR_PRIVATE_KEY>\n')
        self.assertFalse(self.audit.failures)

    def test_private_key_in_plain_file_is_rejected(self):
        payload = b'PrivateKey = ' + base64.b64encode(bytes(range(32))) + b'\n'
        self.audit.check('operator.conf', payload)
        self.assertTrue(self.audit.failures)
        self.assertNotIn(base64.b64encode(bytes(range(32))).decode(), '\n'.join(self.audit.failures))

    def test_zip_member_contents_are_scanned(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / 'release.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                z.writestr('package/active.conf', b'PresharedKey = ' + base64.b64encode(bytes(range(32))))
            self.audit.scan(archive)
        self.assertTrue(self.audit.failures)

    def test_tar_member_contents_are_scanned(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / 'release.tar.gz'
            payload = b'PrivateKey = ' + base64.b64encode(bytes(range(32)))
            with tarfile.open(archive, 'w:gz') as t:
                member = tarfile.TarInfo('package/config.conf')
                member.size = len(payload)
                t.addfile(member, io.BytesIO(payload))
            self.audit.scan(archive)
        self.assertTrue(self.audit.failures)

    def test_absolute_archive_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / 'release.tar.gz'
            with tarfile.open(archive, 'w:gz') as t:
                member = tarfile.TarInfo('package/licenses/external')
                member.type = tarfile.SYMTYPE
                member.linkname = '/usr/share/licenses/external'
                t.addfile(member)
            self.audit.scan(archive)
        self.assertTrue(self.audit.failures)

    def test_fixture_exception_requires_exact_hash(self):
        name = 'vendor/libtorrent/test/ssl/server.pem'
        payload = (self.audit.ROOT / name).read_bytes()
        self.audit.check(name, payload, allow_fixture=True)
        self.assertFalse(self.audit.failures)
        self.audit.check(name, payload + b'\n# changed\n', allow_fixture=True)
        self.assertTrue(self.audit.failures)

if __name__ == '__main__':
    unittest.main()
