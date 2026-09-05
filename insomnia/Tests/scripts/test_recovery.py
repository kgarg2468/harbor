"""Hermetic script copies: every machine-changing command is replaced by a shim."""
import fcntl
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'
SHIM = '''#!/usr/bin/python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['FIXTURE'])
with (root/'calls').open('a') as f: f.write(json.dumps([name]+args)+'\\n')
if name == 'sudo':
    if args == ['-v']: sys.exit(0)
    if '-l' in args: sys.exit(int(os.environ.get('VERIFY_FAIL', '0')))
    args = [a for a in args if a != '-n']
    os.execvp(args[0], args)
if name == 'lockf':
    (root/'lock-entered').touch()
    os.execv('/usr/bin/lockf', ['/usr/bin/lockf']+args)
if name == 'pmset': sys.exit(int(os.environ.get('PMSET_FAIL', '0')))
if name == 'ps':
    if args[1] == os.environ.get('EXITED_PID'): sys.exit(1)
    print(args[1])
if name == 'kill': sys.exit(int(args[-1] == os.environ.get('FAIL_PID')))
if name == 'pgrep': sys.exit(0 if os.environ.get('RUNNING') == '1' else 1)
if name == 'id': print('0' if os.environ.get('ROOT_USER') else ('501' if '-u' in args else os.environ.get('ACCOUNT_NAME', 'alice')))
if name == 'swift':
    if '--show-bin-path' in args: print(root/'bin')
if name == 'install':
    import shutil
    shutil.copyfile(args[-2], args[-1])
if name == 'plutil':
    if os.environ.get('WRITE_FAIL') and '-replace' in args: sys.exit(1)
    os.execv('/usr/bin/plutil', ['/usr/bin/plutil']+args)
'''

class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root/'home & tests'
        self.support = self.home/'support & journal'
        self.support.mkdir(parents=True)
        self.shims = self.root/'shims'
        self.shims.mkdir()
        names = ['sudo', 'pmset', 'kill', 'ps', 'pgrep', 'pkill', 'osascript', 'sleep',
                 'launchctl', 'codesign', 'swift', 'id', 'visudo', 'install', 'plutil', 'lockf']
        for name in names:
            p = self.shims/name
            p.write_text(SHIM)
            p.chmod(0o700)
        self.repo = self.root/'repo'
        (self.repo/'scripts').mkdir(parents=True)
        (self.repo/'Resources').mkdir()
        (self.repo/'Resources/Info.plist').write_text('<?xml version="1.0"?><plist version="1.0"><dict/></plist>')
        (self.root/'bin').mkdir()
        binary = self.root/'bin/Insomnia'
        binary.write_text('#!/bin/bash\nexit 0\n')
        binary.chmod(0o700)
        for source in SCRIPTS.glob('*.sh'):
            code = source.read_text()
            for name in names:
                for prefix in ['/usr/bin/', '/usr/sbin/', '/bin/']:
                    code = code.replace(prefix+name, str(self.shims/name))
            code = code.replace('if kill ', 'if "'+str(self.shims/'kill')+'" ')
            code = code.replace('/etc/sudoers.d/insomnia', str(self.root/'sudoers'))
            code = code.replace('/private/tmp/com.kgarg.insomnia-install.lock', str(self.root/'installer.lock'))
            (self.repo/'scripts'/source.name).write_text(code)
        self.env = dict(os.environ, HOME=str(self.home), INSOMNIA_HOME=str(self.support),
                        FIXTURE=str(self.root), PATH=str(self.shims)+':/usr/bin:/bin', USER='forged')

    def run_script(self, name, *args, **env):
        return subprocess.run(['/bin/bash', str(self.repo/'scripts'/name), *args],
                              env=dict(self.env, **env), capture_output=True, text=True, timeout=15)

    def state(self, **values):
        value = dict(sleepDisabledByUs=True, lowPowerSetByUs=True, frozenPids=[42], dockerFrozen=True)
        value.update(values)
        (self.support/'state.json').write_text(json.dumps(value))
        (self.support/'session.json').write_text('{"endsAt":"2000-01-01T00:00:00Z"}')

    def journal(self):
        return json.loads((self.support/'state.json').read_text())

    def calls(self):
        p = self.root/'calls'
        return [json.loads(s) for s in p.read_text().splitlines()] if p.exists() else []

class RecoveryTests(Fixture):
    def test_broken_log_does_not_block_restore(self):
        self.state()
        (self.support/'Logs/insomnia.log').mkdir(parents=True)
        result = self.run_script('backstop.sh', '--force')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.journal()['sleepDisabledByUs'])
        self.assertEqual(self.journal()['frozenPids'], [])

    def test_failed_restore_invalidates_session_and_retains_entries(self):
        self.state()
        result = self.run_script('backstop.sh', '--force', PMSET_FAIL='1', FAIL_PID='42')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.support/'session.json').exists())
        self.assertTrue(self.journal()['sleepDisabledByUs'])
        self.assertEqual(self.journal()['frozenPids'], [42])
        self.assertTrue(self.journal()['dockerFrozen'])

    def test_invalid_pid_array_never_signals_any_entry(self):
        for pids in [[0, 42], [-42], ['42'], [1.5], [2147483648], {'pid':42}, 0, '42']:
            with self.subTest(pids=pids):
                self.state(frozenPids=pids)
                result = self.run_script('backstop.sh', '--force')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.journal()['frozenPids'], pids)
        self.assertFalse(any(c[0] == 'kill' for c in self.calls()))

    def test_journal_failure_is_failure_and_preserves_original(self):
        self.state()
        before = (self.support/'state.json').read_bytes()
        result = self.run_script('backstop.sh', '--force', WRITE_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.support/'state.json').read_bytes(), before)
        self.assertFalse((self.support/'session.json').exists())

    def test_shared_flock_guards_decision_and_preserves_new_session(self):
        self.state()
        lock = self.support/'recovery.lock'
        with lock.open('w') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            process = subprocess.Popen(['/bin/bash', str(self.repo/'scripts/backstop.sh')],
                                       env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.addCleanup(lambda: process.kill() if process.poll() is None else None)
            deadline = time.monotonic()+5
            while not (self.root/'lock-entered').exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root/'lock-entered').exists())
            self.assertFalse(any(c[0] == 'pmset' for c in self.calls()))
            (self.support/'session.json').write_text('{"endsAt":"2099-01-01T00:00:00Z"}')
            fcntl.flock(held, fcntl.LOCK_UN)
            _, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertTrue((self.support/'session.json').exists())
        self.assertTrue(lock.exists())
        self.assertFalse(any(c[0] == 'pmset' for c in self.calls()))

    def test_partial_pid_restore_keeps_only_failed_entries(self):
        self.state(frozenPids=[42, 43])
        result = self.run_script('backstop.sh', '--force', FAIL_PID='43')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.journal()['frozenPids'], [43])

    def test_exited_pid_does_not_block_recovery(self):
        self.state()
        result = self.run_script('backstop.sh', '--force', FAIL_PID='42', EXITED_PID='42')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.journal()['frozenPids'], [])

    def test_production_system_executables_exist(self):
        for source in SCRIPTS.glob('*.sh'):
            for path in re.findall(r'/(?:usr/)?s?bin/[A-Za-z0-9_-]+', source.read_text()):
                self.assertTrue(os.access(path, os.X_OK), f'{source.name}: {path}')

    def test_audio_is_retained_and_blocks_teardown(self):
        self.state(savedMuted=False, savedOutputVolume=0.6)
        result = self.run_script('backstop.sh', '--force')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.journal()['savedMuted'], False)
        self.assertEqual(self.journal()['savedOutputVolume'], 0.6)

if __name__ == '__main__': unittest.main()
