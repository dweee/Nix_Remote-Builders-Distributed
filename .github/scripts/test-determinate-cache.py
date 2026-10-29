#!/usr/bin/env python3
"""Prove daemon substitution from a signed synthetic authenticated cache."""
import base64
import functools
import http.server
import os
from pathlib import Path
import subprocess
import tempfile
import threading

expression = '''derivation { name = "ci-determinate-cache-test"; system = builtins.currentSystem; builder = "/bin/sh"; args = [ "-c" "echo verified > $out" ]; }'''
seen = []
class Cache(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        expected = 'Basic ' + base64.b64encode(b'ci:synthetic-read-only').decode()
        authorized = self.headers.get('Authorization') == expected
        seen.append((self.path.split('?')[0], authorized))
        if not authorized:
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="test"')
            self.end_headers()
            return
        super().do_GET()
    def log_message(self, *_args):
        pass

def nix(*args, env=None, stdin=None):
    result = subprocess.run(['nix', *args], input=stdin, env=env, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f'nix {args[0]} failed: {result.stderr}')
    return result.stdout.strip()

with tempfile.TemporaryDirectory(prefix='determinate-cache-') as directory:
    root = Path(directory)
    env = os.environ | {'NIX_REMOTE': 'daemon'}
    system = nix('eval', '--impure', '--raw', '--expr', 'builtins.currentSystem', env=env)
    expr = expression.replace('builtins.currentSystem', '"' + system + '"')
    out = nix('build', '--option', 'sandbox', 'false', '--option', 'substitute', 'false',
              '--no-link', '--print-out-paths', '--expr', expr, env=env)
    secret = nix('key', 'generate-secret', '--key-name', 'ci-test-1', env=env)
    key = nix('key', 'convert-secret-to-public', env=env, stdin=secret)
    secret_file = root / 'key'; secret_file.write_text(secret + '\n'); secret_file.chmod(0o600)
    nix('store', 'sign', '--key-file', str(secret_file), out, env=env)
    cache = root / 'cache'; cache.mkdir()
    nix('copy', '--to', cache.as_uri(), out, env=env)
    nix('store', 'delete', out, env=env)
    netrc = root / 'netrc'; netrc.write_text('machine 127.0.0.1 login ci password synthetic-read-only\n'); netrc.chmod(0o600)
    conf = root / 'nix.conf'; conf.write_text('netrc-file = ' + str(netrc) + '\n')
    env['NIX_USER_CONF_FILES'] = str(conf)
    server = http.server.HTTPServer(('127.0.0.1', 0), functools.partial(Cache, directory=cache))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        restored = nix('build', '--option', 'substituters', f'http://127.0.0.1:{server.server_port}',
                       '--option', 'trusted-public-keys', key, '--max-jobs', '0',
                       '--no-link', '--print-out-paths', '--expr', expr, env=env)
        assert restored == out and Path(out).read_text().strip() == 'verified'
        assert any(path.endswith('.narinfo') and ok for path, ok in seen), seen
        assert any('/nar/' in path and ok for path, ok in seen), seen
        print('Daemon substituted a signed output using a synthetic job-local netrc.')
    finally:
        server.shutdown()
        server.server_close()
