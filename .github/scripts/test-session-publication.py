"""Exercise actual dispatch arguments without starting or contacting a builder."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NU = shutil.which('nu')


@unittest.skipUnless(NU, 'Nushell required')
class SessionPublication(unittest.TestCase):
    def test_session_override_default_compatibility_and_invalid_mode(self):
        for system, user, selected in [('', '', None), ('built', '', 'built'),
                                      ('all', 'built', 'built'), ('all', '', 'all'),
                                      ('invalid', '', 'rejected')]:
            with self.subTest(system=system, user=user), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                config = root/'config/nix-remote'
                config.mkdir(parents=True)
                system_config = root/'system.toml'
                system_config.write_text('repo = "fixture/builders"\nwait_for_log = true\n' +
                                         (f'push_paths = "{system}"\n' if system else ''))
                (config/'config.toml').write_text(f'push_paths = "{user}"\n' if user else '')
                commands = root/'bin'
                commands.mkdir()
                # Fail dispatch deliberately. Reaping and completion signaling
                # are stubbed so neither GitHub nor SSH is contacted on failure.
                (commands/'gh').write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPTURE"\nexit 1\n')
                for name in ['bash', 'ssh']:
                    (commands/name).write_text('#!/bin/sh\nexit 0\n')
                for command in commands.iterdir():
                    command.chmod(0o755)
                capture = root/'dispatch'
                env = {'PATH': str(commands)+os.pathsep+os.environ['PATH'], 'HOME': temporary,
                       'XDG_CONFIG_HOME': str(root/'config'), 'XDG_STATE_HOME': str(root/'state'),
                       'NIX_REMOTE_SYSTEM_CONFIG': str(system_config), 'CAPTURE': str(capture)}
                script = ('source '+json.dumps(str(ROOT/'src/nix-remote.nu'))+'; '
                          'let s = resolve-settings null null null null; '
                          'start-session "gha" $s {x86: 0, arm: 0, darwin: 1} "private-target" '
                          '{startup: 1200, idle: 900, linger: 0} 0')
                result = subprocess.run([NU, '--no-config-file', '-c', script], env=env,
                                        capture_output=True, text=True, timeout=15)
                self.assertNotEqual(result.returncode, 0)
                if selected == 'rejected':
                    self.assertFalse(capture.exists())
                    self.assertIn("push_paths must be 'built' or 'all'", result.stderr)
                    continue
                arguments = capture.read_text().splitlines()
                self.assertEqual(arguments[:3], ['workflow', 'run', 'nix-builder.yml'])
                self.assertIn('target=', arguments)
                self.assertNotIn('private-target', arguments)
                modes = [arg for arg in arguments if arg.startswith('push_paths=')]
                self.assertEqual(modes, [] if selected is None else ['push_paths='+selected])


if __name__ == '__main__':
    unittest.main()
