#!/usr/bin/env python3
"""Push a manifest with a short-lived GitHub JWT, refreshed for long uploads."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import urllib.request


def refresh_token(server, path):
    url = os.environ['ACTIONS_ID_TOKEN_REQUEST_URL']
    url += ('&' if '?' in url else '?') + urllib.parse.urlencode({'audience': server})
    request = urllib.request.Request(url, headers={
        'Authorization': 'Bearer ' + os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']})
    with urllib.request.urlopen(request, timeout=30) as response:
        token = json.load(response)['value']
    if not isinstance(token, str) or not token or any(c.isspace() for c in token):
        raise ValueError('Invalid OIDC token')
    # Atomic replacement lets the client's FileToken source re-read safely.
    temporary = path.with_suffix('.new')
    temporary.touch(mode=0o600)
    temporary.write_text(token)
    temporary.replace(path)


def publish(binary, server, manifest):
    if urllib.parse.urlsplit(server).scheme != 'https':
        raise ValueError('Niks3 requires HTTPS')
    paths = Path(manifest).read_text().splitlines()
    if not paths:
        return
    with tempfile.TemporaryDirectory(prefix='niks3-', dir=os.environ['RUNNER_TEMP']) as directory:
        token = Path(directory) / 'oidc-token'
        refresh_token(server, token)
        stop = threading.Event()
        errors = []

        def refresh():
            while not stop.wait(120):
                try:
                    refresh_token(server, token)
                except Exception:
                    # Never print HTTP exceptions: they can contain credentials.
                    errors.append(True)
                    return

        thread = threading.Thread(target=refresh, daemon=True)
        thread.start()
        child = {k: v for k, v in os.environ.items()
                 if k not in {'ACTIONS_ID_TOKEN_REQUEST_TOKEN', 'ACTIONS_ID_TOKEN_REQUEST_URL'}}
        # Both client installation and publication logs remain private. In
        # particular, never pass JWTs or per-path diagnostics to public output.
        try:
            with open(Path(directory) / 'push.log', 'w') as log:
                subprocess.run([binary, 'push', '--server-url', server,
                                '--auth-token-path', str(token), '--verify-s3-integrity',
                                *paths], check=True, env=child, stdout=log, stderr=log)
        finally:
            stop.set()
            thread.join(timeout=35)
        if errors:
            raise RuntimeError('OIDC refresh failed')


if __name__ == '__main__':
    try:
        publish(*sys.argv[1:])
    except Exception:
        print('::error::Niks3 publication failed (private diagnostics suppressed).', file=sys.stderr)
        sys.exit(1)
