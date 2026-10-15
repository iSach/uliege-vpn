"""Execute the actual shell helper with simulated root/process tools.

All paths and signal commands are redirected into a temporary fixture. These
checks require no sudo, never run gof5, and never signal a real process.
"""
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class HelperSecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.root = self.folder / 'privileged'
        self.root.mkdir(mode=0o755)
        (self.root / '.gof5').mkdir(mode=0o700)
        (self.root / '.gof5/config.yaml').write_text('driver: wireguard\n')
        self.state = self.folder / 'active'
        self.state.write_text('0')
        self.owner = self.folder / 'owner'
        self.owner.write_text('0')
        self.command = self.folder / 'comm'
        self.command.write_text(str(self.root / 'gof5'))
        self.stamp = 'Wed Oct 14 12:00:00 2026'
        self.signals = self.folder / 'signals'
        self.record = self.folder / 'record.json'

        def script(name, body):
            path = self.folder / name
            path.write_text(f'#!{sys.executable}\n' + body)
            path.chmod(0o755)
            return str(path)

        self.id = script('id', 'print(0)\n')
        self.stat = script('stat', '''import os, stat, sys
s=os.lstat(sys.argv[-1]); print('0', format(stat.S_IMODE(s.st_mode),'o'), s.st_nlink)
''')
        self.ps = script('ps', f'''import sys
from pathlib import Path
option=sys.argv[-1]
if option=='lstart=': print({self.stamp!r}); raise SystemExit(0)
if Path({str(self.state)!r}).read_text()!='1': raise SystemExit(1)
print(Path({str(self.owner)!r}).read_text() if option=='uid=' else Path({str(self.command)!r}).read_text())
''')
        self.kill = script('kill', f'''import sys
from pathlib import Path
p=Path({str(self.signals)!r}); p.write_text((p.read_text() if p.exists() else '')+' '.join(sys.argv[1:])+'\\n')
state=Path({str(self.state)!r})
if sys.argv[1]=='-0': raise SystemExit(0 if state.read_text()=='1' else 1)
state.write_text('0')
''')
        self.binary = script('fake-gof5', f'''import json,os,sys
from pathlib import Path
if '--version' in sys.argv: print('gof5 0.1.5-uliege.1 test'); raise SystemExit(0)
Path({str(self.record)!r}).write_text(json.dumps(dict(args=sys.argv[1:],stdin=sys.stdin.read(),env=dict(os.environ))))
''')
        (self.root / 'gof5').write_bytes(Path(self.binary).read_bytes())
        (self.root / 'gof5').chmod(0o755)
        source = (ROOT / 'Helper/helper.sh').read_text()
        source = source.replace('ROOT=/Library/PrivilegedHelperTools/be.uliege.vpn', f'ROOT={str(self.root)!r}')
        source = source.replace('/Library /Library/PrivilegedHelperTools "$ROOT"', '"$ROOT"')
        for real, fake in [('/usr/bin/id', self.id), ('/usr/bin/stat', self.stat), ('/bin/ps', self.ps), ('/bin/kill', self.kill)]:
            source = source.replace(real, fake)
        self.helper = self.root / 'helper'
        self.helper.write_text(source)
        self.helper.chmod(0o755)

    def run_helper(self, command, token='synthetic-token-123'):
        return subprocess.run(['/bin/bash', '-p', str(self.helper), command],
                              input=token+'\n', text=True, capture_output=True, timeout=8,
                              env={**os.environ, 'SUDO_UID': 'injected', 'HTTPS_PROXY': 'https://invalid.test'})

    def active(self):
        self.state.write_text('1')
        (self.root / 'gof5.pid').write_text('424242\n')
        (self.root / 'gof5.started').write_text(self.stamp+'\n')

    def test_running_status_never_reads_arguments(self):
        self.active()
        result = self.run_helper('status')
        self.assertEqual(result.stdout.strip(), 'RUNNING', result.stderr)
        self.assertNotIn('-o command=', self.helper.read_text())

    def test_invalid_tokens_never_launch(self):
        for token in ['short', 'x'*4097, 'contains a space', 'abcdefghij\r']:
            result = self.run_helper('start', token)
            self.assertEqual(result.returncode, 65, result.stderr)
        self.assertFalse(self.record.exists())

    def test_session_stays_out_of_arguments_and_environment(self):
        result = self.run_helper('start')
        self.assertEqual(result.returncode, 0, result.stderr)
        deadline = time.monotonic()+3
        while not self.record.exists() and time.monotonic()<deadline:
            time.sleep(.02)
        record = json.loads(self.record.read_text())
        self.assertEqual(record['stdin'], 'synthetic-token-123\n')
        self.assertEqual(record['args'], ['--server','vpn-2fa.uliege.be','--config-dir',str(self.root / '.gof5'),'--session-stdin'])
        self.assertNotIn('SUDO_UID', record['env'])
        self.assertNotIn('HTTPS_PROXY', record['env'])
        self.assertNotIn('synthetic-token-123', str(record['args']) + str(record['env']))

    def test_existing_session_is_not_replaced(self):
        self.active()
        result = self.run_helper('start')
        self.assertEqual(result.stdout.strip(), 'RUNNING', result.stderr)
        self.assertFalse(self.record.exists())
        self.assertNotIn('-INT', self.signals.read_text())

    def test_simultaneous_operation_is_refused(self):
        (self.root / 'operation.lock').mkdir()
        self.assertEqual(self.run_helper('start').returncode, 75)
        self.assertFalse(self.record.exists())

    def test_symlink_config_is_refused_without_touching_target(self):
        target = self.folder / 'target'
        target.write_text('preserve')
        config = self.root / '.gof5/config.yaml'
        config.unlink()
        config.symlink_to(target)
        self.assertEqual(self.run_helper('start').returncode, 78)
        self.assertEqual(target.read_text(), 'preserve')

    def test_writable_directory_is_refused(self):
        self.root.chmod(0o777)
        self.assertEqual(self.run_helper('start').returncode, 78)

    def test_hard_link_state_is_refused(self):
        file = self.root / 'gof5.log'
        file.write_text('preserve')
        os.link(file, self.folder / 'link')
        self.assertEqual(self.run_helper('start').returncode, 78)
        self.assertEqual(file.read_text(), 'preserve')

    def test_pid_one_and_reused_pid_are_never_signalled(self):
        self.active()
        (self.root / 'gof5.pid').write_text('1\n')
        self.assertEqual(self.run_helper('stop').returncode, 0)
        self.assertFalse(self.signals.exists())
        self.active()
        (self.root / 'gof5.started').write_text('a different launch\n')
        self.assertEqual(self.run_helper('stop').returncode, 0)
        self.assertFalse(self.signals.exists())

    def test_wrong_owner_and_executable_are_never_signalled(self):
        for owner, executable in [('501', str(self.root / 'gof5')), ('0','/other/gof5')]:
            self.active()
            self.owner.write_text(owner)
            self.command.write_text(executable)
            self.assertEqual(self.run_helper('stop').returncode, 0)
            self.assertFalse(self.signals.exists())

    def test_explicit_stop_signals_only_owned_process_and_removes_cookie(self):
        self.active()
        cookie = self.root / '.gof5/cookies.yaml'
        cookie.write_text('synthetic')
        self.assertEqual(self.run_helper('stop').returncode, 0)
        self.assertIn('-INT 424242', self.signals.read_text())
        self.assertNotIn('-TERM', self.signals.read_text())
        self.assertFalse(cookie.exists())

    def test_inherited_bash_env_is_not_loaded(self):
        marker = self.folder / 'unexpected-shell-startup'
        startup = self.folder / 'bashenv'
        startup.write_text(f'touch {str(marker)!r}\n')
        result = subprocess.run([str(self.helper), 'status'], input='', capture_output=True,
                                text=True, env={**os.environ, 'BASH_ENV': str(startup)}, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())

    def test_installer_refuses_running_or_unknown_state_without_replacing_files(self):
        rules = self.folder / 'sudoers.d'
        rules.mkdir()
        source = (ROOT / 'Helper/install-root.sh').read_text()
        source = source.replace('ROOT=/Library/PrivilegedHelperTools/be.uliege.vpn', f'ROOT={str(self.root)!r}')
        source = source.replace('/etc/sudoers.d', str(rules))
        source = source.replace('for directory in /Library /private /private/etc;', f'for directory in {str(self.folder)!r};')
        source = source.replace('/Library/PrivilegedHelperTools', str(self.folder))
        source = source.replace('$(id -u)', f'$({self.id} -u)')
        source = source.replace('/usr/bin/id', self.id).replace('/usr/bin/stat', self.stat)
        installer = self.folder / 'install-test.sh'
        installer.write_text(source)
        expected_config = (self.root / '.gof5/config.yaml').read_bytes()
        for status in ['RUNNING', 'UNKNOWN', 'STOPPED extra-output']:
            self.helper.write_text("#!/bin/bash\nprintf '%s\\n' " + repr(status) + '\n')
            original = self.helper.read_bytes()
            result = subprocess.run(['/bin/bash', '-p', str(installer), str(ROOT / 'Helper/helper.sh'),
                                     str(self.root / 'gof5'), 'testuser'], capture_output=True, text=True, timeout=8)
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertEqual(self.helper.read_bytes(), original)
            self.assertEqual((self.root / '.gof5/config.yaml').read_bytes(), expected_config)
            self.assertFalse((self.root / 'operation.lock').exists())
            self.assertFalse(list(self.root.glob('.install.*')))


if __name__ == '__main__':
    unittest.main()
