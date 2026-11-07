#!/usr/bin/env python3
"""Exercise reader isolation and daemon refresh with synthetic credentials."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('configure_niks3', HERE / 'configure-niks3.py')
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class Reader(unittest.TestCase):
    def test_read_only_oidc_configuration_and_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = {'RUNNER_TEMP': temporary, 'GITHUB_ENV': str(root / 'env')}
            with patch.dict(os.environ, env, clear=True), patch.object(reader, 'oidc_reader', return_value=(
                    'machine niks3.monke.fail login oidc password synthetic-reader', 2000000000)), patch.object(reader.subprocess, 'Popen'):
                reader.configure(oidc=True)
                auth = reader.auth_directory()
                self.assertEqual(auth.stat().st_mode & 0o777, 0o700)
                self.assertEqual((auth / 'netrc').stat().st_mode & 0o777, 0o600)
                self.assertIn('https://niks3.monke.fail/oidc', (auth / 'nix.conf').read_text())
                self.assertNotIn('synthetic-reader', (root / 'env').read_text())
                self.assertFalse((auth / 'write-token').exists())
                reader.cleanup()
                self.assertFalse(auth.exists())

    def test_static_credentials_cannot_enter_github_reader(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
                'RUNNER_TEMP': temporary, 'NIKS3_WRITE_TOKEN': 'synthetic-writer'}, clear=True):
            with self.assertRaises(ValueError):
                reader.configure(oidc=True)

    def test_daemon_combines_refreshed_reader_and_managed_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            static = root / 'static'; managed = root / 'managed'; dynamic = root / 'oidc'; dest = root / 'private/combined'
            static.write_text('machine other.example password static-fixture\n')
            managed.write_text('machine install.example password managed-fixture\n')
            dynamic.write_text('machine niks3.monke.fail login oidc password first-fixture\n')
            command = ['perl', str(HERE / 'refresh-private-netrc.pl'), str(static), str(managed), str(dest), str(dynamic)]
            subprocess.run(command, check=True, capture_output=True)
            self.assertIn('first-fixture', dest.read_text())
            replacement = root / 'oidc.next'; replacement.write_text('machine niks3.monke.fail login oidc password replacement-fixture\n')
            replacement.replace(dynamic)
            subprocess.run(command, check=True, capture_output=True)
            content = dest.read_text()
            self.assertNotIn('first-fixture', content)
            for value in ('replacement-fixture', 'static-fixture', 'managed-fixture'):
                self.assertIn(value, content)
            self.assertEqual(dest.stat().st_mode & 0o777, 0o600)
            # Cleanup or an expired OIDC helper removes its source. The next
            # daemon refresh must discard the old JWT, retaining other origins.
            dynamic.unlink()
            subprocess.run(command, check=True, capture_output=True)
            self.assertNotIn('niks3.monke.fail', dest.read_text())
            self.assertIn('managed-fixture', dest.read_text())

    def test_existing_three_argument_refresh_remains_supported(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'static'; managed = root / 'managed'; dest = root / 'private/combined'
            source.write_text('machine fixture.example password old-caller-fixture\n')
            managed.write_text('machine managed.example password managed-fixture\n')
            subprocess.run(['perl', str(HERE / 'refresh-private-netrc.pl'), str(source), str(managed), str(dest)], check=True, capture_output=True)
            self.assertIn('old-caller-fixture', dest.read_text())
            self.assertIn('managed-fixture', dest.read_text())


if __name__ == '__main__':
    unittest.main()
