import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('publisher', Path(__file__).with_name('push-niks3.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublisherTest(unittest.TestCase):
    @patch.dict(os.environ, {'ACTIONS_ID_TOKEN_REQUEST_URL': 'https://issuer/token?x=1',
                            'ACTIONS_ID_TOKEN_REQUEST_TOKEN': 'request-secret'})
    def test_audience_and_private_atomic_refresh(self):
        with tempfile.TemporaryDirectory() as directory:
            token = Path(directory) / 'token'
            for value in ['first.jwt.value', 'second.jwt.value']:
                with patch.object(publisher.urllib.request, 'urlopen',
                                  return_value=io.BytesIO(json.dumps({'value': value}).encode())) as fetch:
                    publisher.refresh_token('https://cache.example', token)
                request = fetch.call_args.args[0]
                self.assertIn('audience=https%3A%2F%2Fcache.example', request.full_url)
                self.assertEqual(request.get_header('Authorization'), 'Bearer request-secret')
                self.assertEqual(token.read_text(), value)
                self.assertEqual(token.stat().st_mode & 0o777, 0o600)

    def test_push_flags_cleanup_and_no_request_credential_in_child(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
                'RUNNER_TEMP': directory, 'ACTIONS_ID_TOKEN_REQUEST_TOKEN': 'request-secret'}):
            manifest = Path(directory) / 'paths'
            manifest.write_text('/nix/store/example-output\n')
            with patch.object(publisher, 'refresh_token') as refresh, \
                    patch.object(publisher.subprocess, 'run') as run:
                publisher.publish('/bin/niks3', 'https://cache.example', manifest)
            args = run.call_args.args[0]
            self.assertIn('--verify-s3-integrity', args)
            self.assertIn('/nix/store/example-output', args)
            self.assertNotIn('ACTIONS_ID_TOKEN_REQUEST_TOKEN', run.call_args.kwargs['env'])
            self.assertFalse(refresh.call_args.args[1].parent.exists())

    def test_failure_propagates(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'RUNNER_TEMP': directory}):
            manifest = Path(directory) / 'paths'
            manifest.write_text('/nix/store/example-output\n')
            with patch.object(publisher, 'refresh_token'), \
                    patch.object(publisher.subprocess, 'run', side_effect=RuntimeError('private')):
                with self.assertRaises(RuntimeError):
                    publisher.publish('/bin/niks3', 'https://cache.example', manifest)
            self.assertEqual(list(Path(directory).iterdir()), [manifest])


if __name__ == '__main__':
    unittest.main()
