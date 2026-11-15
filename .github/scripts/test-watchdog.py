"""Run the workflow's real watchdog against owned, synthetic processes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT/'.github/workflows/nix-builder.yml').read_text()
WATCHDOG = textwrap.dedent(SOURCE.split('      - name: "Watchdog: Connection & Idle Lifecycle"', 1)[1]
                          .split('        run: |\n', 1)[1].split('\n      - name:', 1)[0])
for name, value in [('startup', 30), ('idle', 20), ('linger', 0)]:
    WATCHDOG = WATCHDOG.replace('${{ inputs.timeout_'+name+' }}', str(value))


@unittest.skipUnless(shutil.which('pgrep'), 'pgrep required')
class Watchdog(unittest.TestCase):
    def exercise(self, mode, stdio='nix-daemon --stdio'):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            commands = root/'bin'; commands.mkdir()
            # Separate argv[0] fixtures let the real pgrep engine distinguish
            # the daemon, a stdio connection, and a similarly named command.
            processes = [subprocess.Popen([name, '-c', 'import time; time.sleep(30)'], executable=sys.executable)
                         for name in ['/nix/store/fixture/bin/nix-daemon',
                                      '/nix/store/fixture/bin/not-nix-daemon --stdio']]
            if mode != 'daemon-only':
                processes.append(subprocess.Popen([stdio, '-c', 'import time; time.sleep(30)'],
                                                   executable=sys.executable))
            try:
                env = {**os.environ, 'PATH':str(commands)+os.pathsep+os.environ['PATH'],
                       'FIXTURE':str(root), 'MODE':mode,
                       'REAL_PGREP':shutil.which('pgrep'),
                       'PIDS':json.dumps([p.pid for p in processes]),
                       'STDIO_PID':str(processes[-1].pid)}
                (commands/'ss').write_text('#!/bin/sh\nexit 0\n')
                (commands/'pgrep').write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys
result=subprocess.run([os.environ['REAL_PGREP'],*sys.argv[1:]],capture_output=True,text=True)
allowed=set(json.loads(os.environ['PIDS']))
matches=[p for p in result.stdout.splitlines() if p.isdigit() and int(p) in allowed]
if matches:print('\\n'.join(matches))
sys.exit(0 if matches else 1)
''')
                (commands/'sleep').write_text('''#!/usr/bin/env python3
import os,signal,sys
from pathlib import Path
root=Path(os.environ['FIXTURE']);counter=root/'ticks'
n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
if n>8:sys.exit(99)
if os.environ['MODE']=='disconnect' and n==2:os.kill(int(os.environ['STDIO_PID']),signal.SIGTERM)
if os.environ['MODE']=='connected' and n==4:(root/'done').touch()
''')
                for path in commands.iterdir():path.chmod(0o755)
                # Keep completion signaling inside this disposable fixture.
                script = WATCHDOG.replace('"/tmp/nix-builder-done"', json.dumps(str(root/'done')))
                result = subprocess.run(['bash','-e','-o','pipefail','-c',script], env=env,
                                        capture_output=True,text=True,timeout=8)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                return result.stdout
            finally:
                for process in processes:
                    if process.poll() is None:process.terminate()
                    process.wait(timeout=5)

    def test_permanent_daemon_does_not_satisfy_startup(self):
        output = self.exercise('daemon-only')
        self.assertIn('exceeded during startup connection',output)
        self.assertNotIn('First client connected!',output)

    def test_stdio_connection_keeps_session_alive_until_completion_signal(self):
        for stdio in ['nix-daemon --stdio', '/nix/store/fixture/bin/nix-daemon --stdio']:
            with self.subTest(stdio=stdio):
                output = self.exercise('connected',stdio)
                self.assertIn('First client connected!',output)
                self.assertIn('Completion signal received.',output)
                self.assertNotIn('Timeout of',output)

    def test_idle_timer_advances_after_stdio_disconnect_with_daemon_still_running(self):
        output = self.exercise('disconnect')
        self.assertIn('First client connected!',output)
        self.assertIn('exceeded during idle reconnection',output)


if __name__ == '__main__':unittest.main()
